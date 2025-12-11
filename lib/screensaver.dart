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
  bool _inhibited = false;
  int? _cdpPort;
  bool? _isNativeLinux;

  static ScreensaverInhibitor getInstance() {
    _instance ??= ScreensaverInhibitor();
    return _instance!;
  }

  // Set the CDP port for browser video detection
  void setCdpPort(int? port) {
    _cdpPort = port;
  }

  // Start the periodic check (call this when app starts)
  void start() {
    if (_timer != null) return;

    // Check every 60 seconds
    _timer = Timer.periodic(const Duration(seconds: 60), (_) {
      _checkAndUpdate();
    });

    // Also check immediately
    _checkAndUpdate();
  }

  // Stop the periodic check (call this when app exits)
  void stop() {
    _timer?.cancel();
    _timer = null;
    _restore();
  }

  Future<void> _checkAndUpdate() async {
    // Only run on native Linux (not WSL, not Windows)
    if (!await _isOnNativeLinux()) return;

    final isPlaying = await _isVideoPlaying();

    if (isPlaying && !_inhibited) {
      await _inhibit();
    } else if (!isPlaying && _inhibited) {
      await _restore();
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

    // Check browser via CDP
    if (_cdpPort != null) {
      try {
        final playing = await _checkBrowserVideoPlaying();
        if (playing) return true;
      } catch (_) {
        // CDP check failed, ignore
      }
    }

    return false;
  }

  Future<bool> _checkBrowserVideoPlaying() async {
    if (_cdpPort == null) return false;

    try {
      // Get list of targets from CDP
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://localhost:$_cdpPort/json/list'),
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
            final playing = await _checkPageForVideo(wsUrl);
            if (playing) return true;
          }
        }
      }
    } catch (e) {
      debugPrint('ScreensaverInhibitor: CDP check failed: $e');
    }

    return false;
  }

  Future<bool> _checkPageForVideo(String wsUrl) async {
    try {
      final ws = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 2));

      // Query for video elements that are playing
      // Using Runtime.evaluate to check document.querySelector('video')
      final messageId = DateTime.now().millisecondsSinceEpoch;
      final command = jsonEncode({
        'id': messageId,
        'method': 'Runtime.evaluate',
        'params': {
          'expression': '''
            (function() {
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
      _inhibited = true;
      debugPrint('ScreensaverInhibitor: Inhibited xscreensaver');
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Failed to inhibit: $e');
    }
  }

  Future<void> _restore() async {
    if (!_inhibited) return;

    try {
      await Process.run('xscreensaver-command', ['-activate']);
      _inhibited = false;
      debugPrint('ScreensaverInhibitor: Restored xscreensaver');
    } catch (e) {
      debugPrint('ScreensaverInhibitor: Failed to restore: $e');
    }
  }
}
