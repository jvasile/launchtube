import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services.dart';

// External player (mpv) with IPC for position tracking
class ExternalPlayer {
  static ExternalPlayer? _instance;
  Process? _process;
  Socket? _ipcSocket;
  String _ipcPath = '/tmp/launchtube-mpv.sock';
  String _ipcPipeName = 'launchtube-mpv';  // Windows named pipe name
  String _mpvPath = 'mpv'; // configurable mpv executable

  double _position = 0;
  double _duration = 0;
  bool _paused = false;
  Map<String, dynamic>? _onComplete;

  // Playlist support
  List<PlaylistItem> _playlist = [];
  int _playlistPosition = 0;
  int _lastReportedPosition = -1;

  static ExternalPlayer getInstance() {
    _instance ??= ExternalPlayer();
    return _instance!;
  }

  void setMpvPath(String path) {
    _mpvPath = path;
  }

  bool get isPlaying => _process != null;
  double get position => _position;
  double get duration => _duration;
  bool get paused => _paused;

  Future<void> play({
    required String url,
    String? title,
    double startPosition = 0,
    Map<String, dynamic>? onComplete,
  }) async {
    // Stop any existing playback
    await stop();

    _onComplete = onComplete;
    _position = startPosition;
    _duration = 0;
    _paused = false;

    // Build mpv arguments with platform-appropriate IPC
    final ipcArg = await _getIpcArg();

    // Remove old socket file if exists (Linux only)
    if (!Platform.isWindows && !await _isWSL()) {
      final socketFile = File(_ipcPath);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
    }

    final args = <String>[
      '--fullscreen',
      ipcArg,
    ];

    if (startPosition > 0) {
      args.add('--start=${startPosition.toStringAsFixed(1)}');
    }

    if (title != null) {
      args.add('--title=$title');
    }

    args.add(url);

    // Launch mpv
    final cmdLine = [_mpvPath, ...args].map((a) => a.contains(' ') ? '"$a"' : a).join(' ');
    print('ExternalPlayer: $cmdLine');
    _process = await Process.start(_mpvPath, args);
    print('ExternalPlayer: Started with PID ${_process!.pid}');

    // Log stdout/stderr
    _process!.stdout.transform(utf8.decoder).listen((data) {
      print('mpv stdout: $data');
    });
    _process!.stderr.transform(utf8.decoder).listen((data) {
      print('mpv stderr: $data');
    });

    // Wait for mpv to exit in background
    _process!.exitCode.then((_) async {
      print('ExternalPlayer: mpv exited, position=$_position');

      // Get final position before cleanup
      await _queryPosition();

      // Execute onComplete callback
      if (_onComplete != null) {
        await _executeCallback();
      }

      _process = null;
      _ipcSocket?.close();
      _ipcSocket = null;
    });

    // Start position polling
    _startPositionPolling();
  }

  Future<void> playPlaylist({
    required List<PlaylistItem> items,
    double startPosition = 0,
  }) async {
    if (items.isEmpty) return;

    // Stop any existing playback
    await stop();

    _playlist = items;
    _playlistPosition = 0;
    _lastReportedPosition = -1;
    _onComplete = items.first.onComplete;
    _position = startPosition;
    _duration = 0;
    _paused = false;

    // Build mpv arguments with platform-appropriate IPC
    final ipcArg = await _getIpcArg();

    // Remove old socket file if exists (Linux only)
    if (!Platform.isWindows && !await _isWSL()) {
      final socketFile = File(_ipcPath);
      if (await socketFile.exists()) {
        await socketFile.delete();
      }
    }

    final args = <String>[
      '--fullscreen',
      ipcArg,
    ];

    if (startPosition > 0) {
      args.add('--start=${startPosition.toStringAsFixed(1)}');
    }

    // Add all URLs
    for (final item in items) {
      args.add(item.url);
    }

    // Launch mpv
    final cmdLine = [_mpvPath, ...args].map((a) => a.contains(' ') ? '"$a"' : a).join(' ');
    print('ExternalPlayer: $cmdLine');
    _process = await Process.start(_mpvPath, args);
    print('ExternalPlayer: Started with PID ${_process!.pid}');

    // Log stdout/stderr
    _process!.stdout.transform(utf8.decoder).listen((data) {
      print('mpv stdout: $data');
    });
    _process!.stderr.transform(utf8.decoder).listen((data) {
      print('mpv stderr: $data');
    });

    // Wait for mpv to exit in background
    _process!.exitCode.then((_) async {
      print('ExternalPlayer: mpv exited, position=$_position, playlistPos=$_playlistPosition');

      // Get final position before cleanup
      await _queryPosition();

      // Execute onComplete callback for final item
      if (_playlistPosition < _playlist.length) {
        _onComplete = _playlist[_playlistPosition].onComplete;
        if (_onComplete != null) {
          await _executeCallback();
        }
      }

      _process = null;
      _playlist = [];
      _playlistPosition = 0;
      _ipcSocket?.close();
      _ipcSocket = null;
    });

    // Start position polling
    _startPositionPolling();
  }

  void _startPositionPolling() {
    Future.doWhile(() async {
      if (_process == null) return false;

      await Future.delayed(const Duration(seconds: 1));
      if (_process == null) return false;

      await _queryPosition();
      return _process != null;
    });
  }

  Future<void> _queryPosition() async {
    if (Platform.isWindows || await _isWSL()) {
      await _queryPositionNamedPipe();
    } else {
      await _queryPositionUnixSocket();
    }
  }

  Future<void> _queryPositionUnixSocket() async {
    try {
      // Query all properties in one connection using mpv's JSON IPC
      _ipcSocket?.close();
      _ipcSocket = await Socket.connect(
        InternetAddress(_ipcPath, type: InternetAddressType.unix),
        0,
      ).timeout(const Duration(milliseconds: 500));

      // Send all queries
      final commands = [
        jsonEncode({'command': ['get_property', 'time-pos'], 'request_id': 1}),
        jsonEncode({'command': ['get_property', 'duration'], 'request_id': 2}),
        jsonEncode({'command': ['get_property', 'pause'], 'request_id': 3}),
        jsonEncode({'command': ['get_property', 'playlist-pos'], 'request_id': 4}),
      ].join('\n') + '\n';

      _ipcSocket!.write(commands);
      await _ipcSocket!.flush();

      // Read responses
      final buffer = StringBuffer();
      await for (final chunk in _ipcSocket!.timeout(const Duration(milliseconds: 500))) {
        buffer.write(utf8.decode(chunk));
        final content = buffer.toString();
        if (content.split('\n').where((l) => l.trim().isNotEmpty).length >= 4) {
          break;
        }
      }

      _parseIpcResponses(buffer.toString());

      _ipcSocket?.close();
      _ipcSocket = null;
    } catch (e) {
      // IPC not ready or mpv closed
      debugPrint('ExternalPlayer: Unix socket IPC query failed: $e');
      _ipcSocket?.close();
      _ipcSocket = null;
    }
  }

  Future<void> _queryPositionNamedPipe() async {
    try {
      // Use PowerShell to communicate with Windows named pipe
      final psScript = '''
\$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "$_ipcPipeName", [System.IO.Pipes.PipeDirection]::InOut)
\$pipe.Connect(500)
\$writer = New-Object System.IO.StreamWriter(\$pipe)
\$reader = New-Object System.IO.StreamReader(\$pipe)
\$cmds = @(
  @{command = @("get_property", "time-pos"); request_id = 1},
  @{command = @("get_property", "duration"); request_id = 2},
  @{command = @("get_property", "pause"); request_id = 3},
  @{command = @("get_property", "playlist-pos"); request_id = 4}
)
foreach (\$cmd in \$cmds) {
  \$writer.WriteLine((\$cmd | ConvertTo-Json -Compress))
}
\$writer.Flush()
\$responses = @()
for (\$i = 0; \$i -lt 4; \$i++) {
  \$responses += \$reader.ReadLine()
}
\$pipe.Close()
\$responses -join "`n"
''';

      final result = await Process.run('powershell.exe', ['-Command', psScript])
          .timeout(const Duration(seconds: 2));

      if (result.exitCode == 0) {
        _parseIpcResponses(result.stdout.toString());
      }
    } catch (e) {
      debugPrint('ExternalPlayer: Named pipe IPC query failed: $e');
    }
  }

  void _parseIpcResponses(String responseText) {
    int? newPlaylistPos;

    for (final line in responseText.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final data = jsonDecode(line);
        final requestId = data['request_id'];
        final value = data['data'];
        if (value != null) {
          switch (requestId) {
            case 1:
              _position = (value as num).toDouble();
              break;
            case 2:
              _duration = (value as num).toDouble();
              break;
            case 3:
              _paused = value as bool;
              break;
            case 4:
              newPlaylistPos = (value as num).toInt();
              break;
          }
        }
      } catch (_) {
        // Skip malformed responses
      }
    }

    // Handle playlist position change - report progress for previous item
    if (newPlaylistPos != null && newPlaylistPos != _lastReportedPosition && _playlist.isNotEmpty) {
      if (_lastReportedPosition >= 0 && _lastReportedPosition < _playlist.length) {
        // Report completion of previous item (at end of video)
        final prevItem = _playlist[_lastReportedPosition];
        if (prevItem.onComplete != null) {
          _onComplete = prevItem.onComplete;
          _position = _duration; // Report at end
          _executeCallback();
        }
      }
      _playlistPosition = newPlaylistPos;
      _lastReportedPosition = newPlaylistPos;
      _position = 0; // Reset position for new item
    }
  }

  Future<void> _executeCallback() async {
    if (_onComplete == null) return;

    try {
      final callbackUrl = _onComplete!['url'] as String?;
      final method = (_onComplete!['method'] as String?) ?? 'POST';
      final headers = Map<String, String>.from(_onComplete!['headers'] ?? {});
      final bodyTemplate = _onComplete!['bodyTemplate'];

      if (callbackUrl == null) return;

      // Process body template - replace ${position} and ${positionTicks}
      String? body;
      if (bodyTemplate != null) {
        final positionTicks = (_position * 10000000).round();
        var bodyStr = jsonEncode(bodyTemplate);
        bodyStr = bodyStr.replaceAll(r'${position}', _position.toStringAsFixed(1));
        bodyStr = bodyStr.replaceAll(r'${positionTicks}', positionTicks.toString());
        body = bodyStr;
      }

      debugPrint('ExternalPlayer: Executing callback to $callbackUrl');
      debugPrint('ExternalPlayer: Body: $body');

      final client = HttpClient();
      final request = await client.openUrl(method, Uri.parse(callbackUrl));

      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }

      final response = await request.close();
      debugPrint('ExternalPlayer: Callback response: ${response.statusCode}');
      client.close();
    } catch (e) {
      debugPrint('ExternalPlayer: Callback failed: $e');
    }
  }

  Future<void> stop() async {
    Log.write('ExternalPlayer: stop() called, _process=${_process?.pid}');
    if (_process != null) {
      final pid = _process!.pid;
      Log.write('ExternalPlayer: Stopping mpv PID $pid');

      if (Platform.isWindows || await _isWSL()) {
        // Windows or WSL - try graceful quit via named pipe first
        Log.write('ExternalPlayer: Sending quit via named pipe');
        try {
          final psScript = '''
\$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "$_ipcPipeName", [System.IO.Pipes.PipeDirection]::InOut)
\$pipe.Connect(500)
\$writer = New-Object System.IO.StreamWriter(\$pipe)
\$cmd = @{command = @("quit")} | ConvertTo-Json -Compress
\$writer.WriteLine(\$cmd)
\$writer.Flush()
\$pipe.Close()
''';
          await Process.run('powershell.exe', ['-Command', psScript])
              .timeout(const Duration(seconds: 2));
          Log.write('ExternalPlayer: Quit command sent');
        } catch (e) {
          // Fall back to taskkill
          Log.write('ExternalPlayer: Named pipe failed, using taskkill: $e');
          try {
            final result = await Process.run('taskkill.exe', ['/F', '/IM', 'mpv.exe']);
            Log.write('ExternalPlayer: taskkill result: ${result.exitCode}');
          } catch (e2) {
            Log.write('ExternalPlayer: taskkill failed: $e2');
          }
        }
      } else {
        // Native Linux - use SIGTERM
        _process!.kill(ProcessSignal.sigterm);
      }
      _process = null;
    }
    _ipcSocket?.close();
    _ipcSocket = null;
  }

  static bool? _isWSLCached;
  Future<bool> _isWSL() async {
    if (_isWSLCached != null) return _isWSLCached!;
    try {
      final versionFile = File('/proc/version');
      if (await versionFile.exists()) {
        final content = await versionFile.readAsString();
        _isWSLCached = content.toLowerCase().contains('microsoft');
        return _isWSLCached!;
      }
    } catch (_) {}
    _isWSLCached = false;
    return false;
  }

  Future<String> _getIpcArg() async {
    if (Platform.isWindows || await _isWSL()) {
      // Windows named pipe format
      return '--input-ipc-server=\\\\.\\pipe\\$_ipcPipeName';
    } else {
      // Unix socket
      return '--input-ipc-server=$_ipcPath';
    }
  }

  Map<String, dynamic> getStatus() {
    if (_process == null) {
      return {'playing': false};
    }
    final status = {
      'playing': true,
      'paused': _paused,
      'position': _position,
      'duration': _duration,
    };
    if (_playlist.isNotEmpty) {
      status['playlistPosition'] = _playlistPosition;
      status['playlistCount'] = _playlist.length;
    }
    return status;
  }
}
