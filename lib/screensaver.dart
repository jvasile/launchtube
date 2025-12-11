import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'player.dart';

// Manages xscreensaver inhibition based on video playback state
// Checks both mpv (external player) and browser (via CDP) for active video
class ScreensaverInhibitor {
  static ScreensaverInhibitor? _instance;

  Timer? _timer;
  int? _debugPort;
  String? _browserName;
  bool? _isNativeLinux;
  int _checkIntervalSeconds = 60; // Default, will be updated from xscreensaver config

  static ScreensaverInhibitor getInstance() {
    _instance ??= ScreensaverInhibitor();
    return _instance!;
  }

  // Set the browser info for video detection
  void setBrowser(String? browserName, int? port) {
    _browserName = browserName;
    _debugPort = port;
    // Check immediately when browser is set
    if (browserName != null && port != null) {
      _checkAndUpdate();
    }
  }

  // Start the periodic check (call this when app starts)
  Future<void> start() async {
    if (_timer != null) return;

    // Deactivate xscreensaver on startup in case it's currently running
    await _inhibit();

    // Read xscreensaver timeout and set check interval to half of it
    await _readXscreensaverTimeout();

    _timer = Timer.periodic(Duration(seconds: _checkIntervalSeconds), (_) {
      _checkAndUpdate();
    });

    // Also check immediately
    _checkAndUpdate();
  }

  // Stop the periodic check (call this when app exits)
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // Read timeout from ~/.xscreensaver and set interval to half of it
  Future<void> _readXscreensaverTimeout() async {
    try {
      final home = Platform.environment['HOME'];
      if (home == null) return;

      final configFile = File('$home/.xscreensaver');
      if (!await configFile.exists()) return;

      final content = await configFile.readAsString();
      // Look for line like "timeout: 0:05:00" (hours:minutes:seconds)
      final match = RegExp(r'timeout:\s*(\d+):(\d+):(\d+)').firstMatch(content);
      if (match != null) {
        final hours = int.parse(match.group(1)!);
        final minutes = int.parse(match.group(2)!);
        final seconds = int.parse(match.group(3)!);
        final totalSeconds = hours * 3600 + minutes * 60 + seconds;

        // Set check interval to half the timeout, minimum 30 seconds
        _checkIntervalSeconds = (totalSeconds ~/ 2).clamp(30, 300);
        debugPrint('ScreensaverInhibitor: xscreensaver timeout is $totalSeconds seconds, checking every $_checkIntervalSeconds seconds');
      }
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Failed to read xscreensaver config: $e');
    }
  }

  Future<void> _checkAndUpdate() async {
    // Only run on native Linux (not WSL, not Windows)
    if (!await _isOnNativeLinux()) return;

    final isPlaying = await _isVideoPlaying();

    if (isPlaying) {
      await _inhibit();
    }
  }

  Future<bool> _isOnNativeLinux() async {
    if (_isNativeLinux != null) return _isNativeLinux!;

    if (Platform.isWindows) {
      _isNativeLinux = false;
      return false;
    }

    // Check for WSL
    try {
      final versionFile = File('/proc/version');
      if (await versionFile.exists()) {
        final content = await versionFile.readAsString();
        if (content.toLowerCase().contains('microsoft')) {
          _isNativeLinux = false;
          return false;
        }
      }
    } catch (_) {}

    _isNativeLinux = true;
    return true;
  }

  Future<bool> _isVideoPlaying() async {
    // Check mpv first
    final player = ExternalPlayer.getInstance();
    if (player.isPlaying && !player.paused) {
      return true;
    }

    // Check browser via remote debugging
    if (_debugPort != null && _browserName != null) {
      try {
        final playing = await _checkBrowserVideoPlaying();
        if (playing) return true;
      } catch (_) {
        // Browser check failed, ignore
      }
    }

    return false;
  }

  Future<bool> _checkBrowserVideoPlaying() async {
    if (_debugPort == null) {
      debugPrint('ScreensaverInhibitor: No debug port set');
      return false;
    }

    debugPrint('ScreensaverInhibitor: Checking browser "$_browserName" on port $_debugPort');

    if (_browserName == 'Firefox') {
      final result = await _checkFirefoxVideoPlaying();
      debugPrint('ScreensaverInhibitor: Firefox fullscreen video playing: $result');
      return result;
    } else {
      final result = await _checkChromeVideoPlaying();
      debugPrint('ScreensaverInhibitor: Chrome fullscreen video playing: $result');
      return result;
    }
  }

  // Chrome DevTools Protocol
  Future<bool> _checkChromeVideoPlaying() async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://localhost:$_debugPort/json/list'),
      ).timeout(const Duration(seconds: 2));
      final response = await request.close();

      if (response.statusCode != 200) {
        client.close();
        return false;
      }

      final body = await response.transform(utf8.decoder).join();
      final targets = jsonDecode(body) as List<dynamic>;
      client.close();

      // Find a page target to query
      for (final target in targets) {
        if (target['type'] == 'page') {
          final wsUrl = target['webSocketDebuggerUrl'] as String?;
          if (wsUrl != null) {
            final playing = await _checkChromePageForVideo(wsUrl);
            if (playing) return true;
          }
        }
      }
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Chrome CDP check failed: $e');
    }

    return false;
  }

  // Firefox WebDriver BiDi protocol
  Future<bool> _checkFirefoxVideoPlaying() async {
    WebSocket? ws;
    try {
      // Connect to WebDriver BiDi WebSocket on /session path
      ws = await WebSocket.connect('ws://127.0.0.1:$_debugPort/session')
          .timeout(const Duration(seconds: 2));

      final completer = Completer<bool>();
      String? contextId;
      bool? videoPlayingResult;

      ws.listen((data) {
        try {
          final response = jsonDecode(data as String);
          debugPrint('ScreensaverInhibitor: Firefox BiDi response: $response');

          // Handle session.new response
          if (response['id'] == 1 && response['result'] != null) {
            debugPrint('ScreensaverInhibitor: Session created, getting tree');
            // Session created, now get the browsing contexts
            final getTreeCommand = jsonEncode({
              'id': 2,
              'method': 'browsingContext.getTree',
              'params': {},
            });
            ws?.add(getTreeCommand);
          }
          // Handle browsingContext.getTree response
          else if (response['id'] == 2 && response['result'] != null) {
            final contexts = response['result']['contexts'] as List<dynamic>?;
            if (contexts != null && contexts.isNotEmpty) {
              // Get the first top-level context
              contextId = contexts[0]['context'] as String?;
              debugPrint('ScreensaverInhibitor: Got context: $contextId');

              if (contextId != null) {
                // Now evaluate script to check for playing fullscreen videos
                final evalCommand = jsonEncode({
                  'id': 3,
                  'method': 'script.evaluate',
                  'params': {
                    'expression': '''
                      (function() {
                        // Only inhibit if there's a playing video AND we're in fullscreen
                        if (!document.fullscreenElement) {
                          return false;
                        }
                        const videos = document.querySelectorAll('video');
                        for (const v of videos) {
                          if (!v.paused && !v.ended && v.readyState > 2) {
                            return true;
                          }
                        }
                        return false;
                      })()
                    ''',
                    'target': {'context': contextId},
                    'awaitPromise': false,
                  },
                });
                ws?.add(evalCommand);
              } else {
                if (!completer.isCompleted) completer.complete(false);
              }
            } else {
              if (!completer.isCompleted) completer.complete(false);
            }
          }
          // Handle script.evaluate response
          else if (response['id'] == 3 && response['result'] != null) {
            final result = response['result']['result'];
            final value = result?['value'];
            debugPrint('ScreensaverInhibitor: Script result: $value');

            // Store the result, then end the session
            videoPlayingResult = value == true;

            // End the session before completing
            final endSessionCommand = jsonEncode({
              'id': 4,
              'method': 'session.end',
              'params': {},
            });
            ws?.add(endSessionCommand);
          }
          // Handle session.end response - now we can complete
          else if (response['id'] == 4) {
            debugPrint('ScreensaverInhibitor: Session ended');
            if (!completer.isCompleted) {
              completer.complete(videoPlayingResult ?? false);
            }
          }
          // Handle errors
          else if (response['error'] != null) {
            debugPrint('ScreensaverInhibitor: BiDi error: ${response['error']}');
            if (!completer.isCompleted) completer.complete(false);
          }
        } catch (e) {
          debugPrint('ScreensaverInhibitor: Firefox BiDi parse error: $e');
        }
      }, onError: (e) {
        debugPrint('ScreensaverInhibitor: Firefox BiDi socket error: $e');
        if (!completer.isCompleted) completer.complete(false);
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(false);
      });

      // Start by creating a session
      final newSessionCommand = jsonEncode({
        'id': 1,
        'method': 'session.new',
        'params': {'capabilities': {}},
      });
      ws.add(newSessionCommand);

      // Timeout
      Future.delayed(const Duration(seconds: 3), () {
        if (!completer.isCompleted) completer.complete(false);
      });

      final result = await completer.future;
      await ws.close();
      return result;
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Firefox BiDi check failed: $e');
      await ws?.close();
      return false;
    }
  }

  Future<bool> _checkChromePageForVideo(String wsUrl) async {
    try {
      final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 2));

      // Query for playing fullscreen video
      final messageId = DateTime.now().millisecondsSinceEpoch;
      final command = jsonEncode({
        'id': messageId,
        'method': 'Runtime.evaluate',
        'params': {
          'expression': '''
            (function() {
              // Only inhibit if there's a playing video AND we're in fullscreen
              if (!document.fullscreenElement) {
                return false;
              }
              const videos = document.querySelectorAll('video');
              for (const v of videos) {
                if (!v.paused && !v.ended && v.readyState > 2) {
                  return true;
                }
              }
              return false;
            })()
          ''',
          'returnByValue': true,
        },
      });

      ws.add(command);

      // Wait for response
      final completer = Completer<bool>();
      Timer? timeout;

      timeout = Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      ws.listen((data) {
        try {
          final response = jsonDecode(data as String);
          if (response['id'] == messageId) {
            timeout?.cancel();
            final result = response['result']?['result']?['value'];
            if (!completer.isCompleted) {
              completer.complete(result == true);
            }
          }
        } catch (_) {}
      }, onError: (_) {
        timeout?.cancel();
        if (!completer.isCompleted) {
          completer.complete(false);
        }
      });

      final result = await completer.future;
      await ws.close();
      return result;
    } catch (e) {
      debugPrint('ScreensaverInhibitor: WebSocket check failed: $e');
      return false;
    }
  }

  Future<void> _inhibit() async {
    try {
      await Process.run('xscreensaver-command', ['-deactivate']);
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Failed to inhibit: $e');
    }
  }
}
