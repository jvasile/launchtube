import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_svg/flutter_svg.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LaunchTubeApp());
}

enum AppType { website, native }

class AppConfig {
  String name;
  String? url;
  bool kioskMode;
  String? commandLine;
  AppType type;
  String? imagePath;
  int colorValue;
  bool showName;

  AppConfig({
    required this.name,
    this.url,
    this.kioskMode = true,
    this.commandLine,
    required this.type,
    this.imagePath,
    required this.colorValue,
    this.showName = true,
  });

  Color get color => Color(colorValue);

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'kioskMode': kioskMode,
        'commandLine': commandLine,
        'type': type.index,
        'imagePath': imagePath,
        'colorValue': colorValue,
        'showName': showName,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        name: json['name'],
        url: json['url'],
        kioskMode: json['kioskMode'] ?? true,
        commandLine: json['commandLine'],
        type: AppType.values[json['type']],
        imagePath: json['imagePath'],
        colorValue: json['colorValue'],
        showName: json['showName'] ?? true,
      );

  AppConfig copy() => AppConfig(
        name: name,
        url: url,
        kioskMode: kioskMode,
        commandLine: commandLine,
        type: type,
        imagePath: imagePath,
        colorValue: colorValue,
        showName: showName,
      );
}

final List<AppConfig> defaultApps = [];

// Service library for pre-configured streaming services
class ServiceTemplate {
  final String name;
  final String url;
  final int colorValue;
  final String? logoPath;
  final bool isBundled; // true = bundled asset, false = user file

  const ServiceTemplate({
    required this.name,
    required this.url,
    required this.colorValue,
    this.logoPath,
    this.isBundled = true,
  });

  factory ServiceTemplate.fromJson(Map<String, dynamic> json, String? logoPath, bool isBundled) {
    return ServiceTemplate(
      name: json['name'] as String,
      url: json['url'] as String,
      colorValue: _parseColor(json['color'] as String),
      logoPath: logoPath,
      isBundled: isBundled,
    );
  }

  static int _parseColor(String hex) {
    final hexColor = hex.replaceFirst('#', '');
    return int.parse('FF$hexColor', radix: 16);
  }

  AppConfig toAppConfig() => AppConfig(
    name: name,
    url: url,
    type: AppType.website,
    kioskMode: true,
    colorValue: colorValue,
    imagePath: logoPath,
    showName: logoPath == null,
  );
}

// Service library loader
class ServiceLibraryLoader {
  static Future<List<ServiceTemplate>> loadServices() async {
    final services = <String, ServiceTemplate>{};

    // 1. Load bundled services from assets
    final bundledServices = await _loadBundledServices();
    for (final service in bundledServices) {
      services[service.name.toLowerCase()] = service;
    }

    // 2. Load user services (override bundled)
    final userServices = await _loadUserServices();
    for (final service in userServices) {
      services[service.name.toLowerCase()] = service;
    }

    // Sort by name
    final result = services.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  static Future<List<ServiceTemplate>> _loadBundledServices() async {
    final services = <ServiceTemplate>[];
    final dataDir = getAssetDirectory();
    final servicesDir = '$dataDir/services';

    try {
      // Load manifest to get list of services
      final manifestFile = File('$servicesDir/manifest.json');
      if (!await manifestFile.exists()) {
        debugPrint('No service manifest found at $servicesDir/manifest.json');
        return services;
      }

      final manifestJson = await manifestFile.readAsString();
      final manifest = List<String>.from(jsonDecode(manifestJson));

      for (final serviceId in manifest) {
        try {
          final configFile = File('$servicesDir/$serviceId.json');
          if (!await configFile.exists()) continue;

          final jsonStr = await configFile.readAsString();
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;

          // Check for logo file (try common extensions)
          String? logoPath;
          for (final ext in ['png', 'jpg', 'jpeg', 'svg']) {
            final logoFile = File('$servicesDir/$serviceId.$ext');
            if (await logoFile.exists()) {
              logoPath = logoFile.path;
              break;
            }
          }

          services.add(ServiceTemplate.fromJson(json, logoPath, false));
        } catch (e) {
          // Skip invalid service files
          debugPrint('Failed to load service $serviceId: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to load service manifest: $e');
    }

    return services;
  }

  static Future<List<ServiceTemplate>> _loadUserServices() async {
    final services = <ServiceTemplate>[];

    try {
      final appDir = await getApplicationDocumentsDirectory();
      final servicesDir = Directory('${appDir.path}/services');

      if (!await servicesDir.exists()) {
        return services;
      }

      final jsonFiles = await servicesDir
          .list()
          .where((f) => f.path.endsWith('.json'))
          .toList();

      for (final file in jsonFiles) {
        try {
          final jsonStr = await File(file.path).readAsString();
          final json = jsonDecode(jsonStr) as Map<String, dynamic>;

          // Check for logo file with same base name
          final baseName = file.path.replaceAll('.json', '');
          String? logoPath;
          for (final ext in ['png', 'jpg', 'jpeg']) {
            final logoFile = File('$baseName.$ext');
            if (await logoFile.exists()) {
              logoPath = logoFile.path;
              break;
            }
          }

          services.add(ServiceTemplate.fromJson(json, logoPath, false));
        } catch (e) {
          debugPrint('Failed to load user service ${file.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to load user services: $e');
    }

    return services;
  }
}

// Per-service key/value storage for userscripts
class ServiceDataStore {
  static ServiceDataStore? _instance;
  Map<String, Map<String, dynamic>> _data = {};
  String? _filePath;
  bool _dirty = false;

  static Future<ServiceDataStore> getInstance() async {
    if (_instance == null) {
      _instance = ServiceDataStore();
      await _instance!._load();
    }
    return _instance!;
  }

  Future<void> _load() async {
    final appDir = await getApplicationSupportDirectory();
    _filePath = '${appDir.path}/service_data.json';
    final file = File(_filePath!);
    if (await file.exists()) {
      try {
        final contents = await file.readAsString();
        final decoded = jsonDecode(contents) as Map<String, dynamic>;
        _data = decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
      } catch (e) {
        debugPrint('Failed to load service data: $e');
        _data = {};
      }
    }
  }

  Future<void> _save() async {
    if (_filePath == null || !_dirty) return;
    try {
      final file = File(_filePath!);
      await file.writeAsString(jsonEncode(_data));
      _dirty = false;
    } catch (e) {
      debugPrint('Failed to save service data: $e');
    }
  }

  Map<String, dynamic> getAll(String serviceId) {
    return Map<String, dynamic>.from(_data[serviceId] ?? {});
  }

  dynamic get(String serviceId, String key) {
    return _data[serviceId]?[key];
  }

  Future<void> set(String serviceId, String key, dynamic value) async {
    _data[serviceId] ??= {};
    _data[serviceId]![key] = value;
    _dirty = true;
    await _save();
  }

  Future<void> delete(String serviceId, String key) async {
    if (_data[serviceId] != null) {
      _data[serviceId]!.remove(key);
      if (_data[serviceId]!.isEmpty) {
        _data.remove(serviceId);
      }
      _dirty = true;
      await _save();
    }
  }

  Future<void> deleteAll(String serviceId) async {
    if (_data.containsKey(serviceId)) {
      _data.remove(serviceId);
      _dirty = true;
      await _save();
    }
  }
}

// Data directory for runtime assets
String? _cachedAssetDir;

String getAssetDirectory() {
  if (_cachedAssetDir != null) return _cachedAssetDir!;

  // First, try ~/.local/share/launchtube/assets
  final home = Platform.environment['HOME'];
  final userDir = '$home/.local/share/launchtube/assets';
  if (Directory(userDir).existsSync()) {
    print('Using asset directory: $userDir');
    _cachedAssetDir = userDir;
    return userDir;
  }

  // Fallback: look for data/ directory in parent directories of the binary
  // This enables running from source
  final exePath = Platform.resolvedExecutable;
  var dir = Directory(exePath).parent;
  for (var i = 0; i < 5; i++) {
    final dataDir = Directory('${dir.path}/data');
    if (dataDir.existsSync()) {
      print('Using asset directory: ${dataDir.path}');
      _cachedAssetDir = dataDir.path;
      return dataDir.path;
    }
    dir = dir.parent;
  }

  // Default to user dir even if it doesn't exist
  print('Asset directory not found, defaulting to: $userDir');
  _cachedAssetDir = userDir;
  return userDir;
}

// File cache with mtime-based hot-reload
class _CachedFile {
  final Uint8List bytes;
  final DateTime mtime;
  _CachedFile(this.bytes, this.mtime);
}

class FileCache {
  static FileCache? _instance;
  final Map<String, _CachedFile> _cache = {};

  static FileCache getInstance() {
    _instance ??= FileCache();
    return _instance!;
  }

  Future<Uint8List?> getBytes(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      _cache.remove(path);
      return null;
    }

    final stat = await file.stat();
    final mtime = stat.modified;

    final cached = _cache[path];
    if (cached != null && cached.mtime == mtime) {
      return cached.bytes;
    }

    // File changed or not cached - reload
    final bytes = await file.readAsBytes();
    _cache[path] = _CachedFile(bytes, mtime);
    return bytes;
  }

  Future<String?> getString(String path) async {
    final bytes = await getBytes(path);
    if (bytes == null) return null;
    return utf8.decode(bytes);
  }

  DateTime? getMtime(String path) {
    return _cache[path]?.mtime;
  }
}

// External player (mpv) with IPC for position tracking
class ExternalPlayer {
  static ExternalPlayer? _instance;
  Process? _process;
  Socket? _ipcSocket;
  String _ipcPath = '/tmp/launchtube-mpv.sock';

  double _position = 0;
  double _duration = 0;
  bool _paused = false;
  Map<String, dynamic>? _onComplete;

  static ExternalPlayer getInstance() {
    _instance ??= ExternalPlayer();
    return _instance!;
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

    // Remove old socket file if exists
    final socketFile = File(_ipcPath);
    if (await socketFile.exists()) {
      await socketFile.delete();
    }

    // Build mpv arguments
    final args = <String>[
      '--fullscreen',
      '--input-ipc-server=$_ipcPath',
    ];

    if (startPosition > 0) {
      args.add('--start=${startPosition.toStringAsFixed(1)}');
    }

    if (title != null) {
      args.add('--title=$title');
    }

    args.add(url);

    // Launch mpv
    print('ExternalPlayer: Running mpv ${args.join(' ')}');
    _process = await Process.start('mpv', args);
    print('ExternalPlayer: Started mpv with PID ${_process!.pid}');

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
      ].join('\n') + '\n';

      _ipcSocket!.write(commands);
      await _ipcSocket!.flush();

      // Read responses
      final buffer = StringBuffer();
      await for (final chunk in _ipcSocket!.timeout(const Duration(milliseconds: 500))) {
        buffer.write(utf8.decode(chunk));
        final content = buffer.toString();
        if (content.split('\n').where((l) => l.trim().isNotEmpty).length >= 3) {
          break;
        }
      }

      // Parse responses
      for (final line in buffer.toString().split('\n')) {
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
            }
          }
        } catch (_) {
          // Skip malformed responses
        }
      }

      _ipcSocket?.close();
      _ipcSocket = null;
    } catch (e) {
      // IPC not ready or mpv closed
      debugPrint('ExternalPlayer: IPC query failed: $e');
      _ipcSocket?.close();
      _ipcSocket = null;
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
    if (_process != null) {
      try {
        // Try graceful quit via IPC
        final socket = await Socket.connect(
          InternetAddress(_ipcPath, type: InternetAddressType.unix),
          0,
        ).timeout(const Duration(milliseconds: 500));

        final quitCmd = jsonEncode({'command': ['quit']}) + '\n';
        socket.write(quitCmd);
        await socket.flush();
        socket.close();
      } catch (_) {
        // IPC failed, kill process
        _process?.kill();
      }
      _process = null;
    }
    _ipcSocket?.close();
    _ipcSocket = null;
  }

  Map<String, dynamic> getStatus() {
    if (_process == null) {
      return {'playing': false};
    }
    return {
      'playing': true,
      'paused': _paused,
      'position': _position,
      'duration': _duration,
    };
  }
}

// HTTP server for serving userscripts to browser extensions
class LaunchTubeServer {
  HttpServer? _server;
  int? _port;
  List<AppConfig> Function()? _getApps;

  int? get port => _port;

  void setAppsProvider(List<AppConfig> Function() getApps) {
    _getApps = getApps;
  }

  Future<void> start() async {
    for (final port in [8765, 8766, 8767, 8768, 8769]) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        _port = port;
        _server!.listen(_handleRequest);
        debugPrint('Launch Tube server running on port $port');
        return;
      } catch (_) {
        // Port in use, try next
      }
    }
    debugPrint('Failed to start Launch Tube server - all ports in use');
  }

  void _handleRequest(HttpRequest request) async {
    // Add CORS headers for browser access
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', '*');
    request.response.headers.add('Cache-Control', 'no-cache, must-revalidate');

    // Handle CORS preflight
    if (request.method == 'OPTIONS') {
      request.response
        ..statusCode = HttpStatus.ok
        ..close();
      return;
    }

    if (request.uri.path.startsWith('/api/service/')) {
      final serviceId = request.uri.path.split('/').last;
      await _serveServiceScript(request, serviceId);
    } else if (request.uri.path == '/api/ping') {
      // Health check endpoint for port discovery
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","app":"launchtube"}')
        ..close();
    } else if (request.uri.path == '/launchtube-loader.user.js') {
      // Serve userscript for Tampermonkey installation
      await _serveUserscript(request);
    } else if (request.uri.path == '/install') {
      // Serve install page that auto-closes
      await _serveInstallPage(request);
    } else if (request.uri.path == '/api/shutdown') {
      // Trigger application shutdown
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","message":"shutting down"}')
        ..close();
      // Exit the application after responding
      Future.delayed(const Duration(milliseconds: 100), () => exit(0));
    } else if (request.uri.path == '/api/status') {
      // Status endpoint with server info
      final status = jsonEncode({
        'status': 'ok',
        'app': 'launchtube',
        'port': _port,
        'endpoints': [
          '/api/ping',
          '/api/status',
          '/api/shutdown',
          '/api/match?url={pageUrl}',
          '/api/service/{serviceId}',
          '/api/kv/{serviceId}',
          '/api/kv/{serviceId}/{key}',
          '/api/player/play',
          '/api/player/status',
          '/api/player/stop',
          '/install',
          '/launchtube-loader.user.js',
        ],
      });
      request.response
        ..headers.contentType = ContentType.json
        ..write(status)
        ..close();
    } else if (request.uri.path == '/api/match') {
      await _handleMatchRequest(request);
    } else if (request.uri.path.startsWith('/api/player/')) {
      await _handlePlayerRequest(request);
    } else if (request.uri.path.startsWith('/api/kv/')) {
      await _handleKvRequest(request);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found')
        ..close();
    }
  }

  Future<void> _serveServiceScript(HttpRequest request, String serviceId) async {
    final dataDir = getAssetDirectory();
    final scriptPath = '$dataDir/services/$serviceId.js';
    final cache = FileCache.getInstance();

    final script = await cache.getString(scriptPath);
    if (script == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('// Script not found for service: $serviceId')
        ..close();
      return;
    }

    final mtime = cache.getMtime(scriptPath);
    request.response
      ..headers.contentType = ContentType('application', 'javascript', charset: 'utf-8')
      ..headers.add('Cache-Control', 'max-age=31536000')
      ..headers.add('ETag', '"${mtime?.millisecondsSinceEpoch ?? 0}"')
      ..write(script)
      ..close();
  }

  Future<void> _handleMatchRequest(HttpRequest request) async {
    final pageUrl = request.uri.queryParameters['url'];
    if (pageUrl == null || pageUrl.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('// Missing url parameter')
        ..close();
      return;
    }

    // Get configured apps
    final apps = _getApps?.call() ?? [];

    // Parse the page URL
    Uri pageUri;
    try {
      pageUri = Uri.parse(pageUrl);
    } catch (_) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('// Invalid url')
        ..close();
      return;
    }

    // Find matching app by checking if app URL is a prefix of page URL
    String? matchedServiceName;
    for (final app in apps) {
      if (app.url == null) continue;

      // Check if app URL is a prefix of the page URL
      if (pageUrl.toLowerCase().startsWith(app.url!.toLowerCase())) {
        matchedServiceName = app.name;
        break;
      }
    }

    if (matchedServiceName == null) {
      // No match - return 204 No Content (not an error, just no script)
      request.response
        ..statusCode = HttpStatus.noContent
        ..close();
      return;
    }

    // Derive service ID from name: "Jellyfin" -> "jellyfin"
    final serviceId = matchedServiceName.toLowerCase().replaceAll(' ', '-');
    await _serveServiceScript(request, serviceId);
  }

  Future<void> _serveUserscript(HttpRequest request) async {
    final dataDir = getAssetDirectory();
    final scriptPath = '$dataDir/launchtube-loader.user.js';
    final cache = FileCache.getInstance();

    final script = await cache.getString(scriptPath);
    if (script == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('// Userscript not found')
        ..close();
      return;
    }

    final mtime = cache.getMtime(scriptPath);
    request.response
      ..headers.contentType = ContentType('application', 'javascript', charset: 'utf-8')
      ..headers.add('Cache-Control', 'max-age=31536000')
      ..headers.add('ETag', '"${mtime?.millisecondsSinceEpoch ?? 0}"')
      ..write(script)
      ..close();
  }

  Future<void> _serveInstallPage(HttpRequest request) async {
    final html = '''
<!DOCTYPE html>
<html>
<head>
  <title>Launch Tube - Install Userscript</title>
  <style>
    body {
      background: #1A1A2E;
      color: white;
      font-family: system-ui, sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      height: 100vh;
      margin: 0;
    }
    .container {
      text-align: center;
    }
    a {
      color: #4FC3F7;
      font-size: 1.2em;
    }
  </style>
</head>
<body>
  <div class="container">
    <h2>Installing Launch Tube Userscript...</h2>
    <p>If the install dialog doesn't appear, <a href="/launchtube-loader.user.js">click here</a>.</p>
    <p id="status">This window will close automatically.</p>
  </div>
  <script>
    // Redirect to userscript URL to trigger Tampermonkey
    location.href = '/launchtube-loader.user.js';
    // Try to close window after a delay (gives time for install dialog)
    setTimeout(function() {
      window.close();
    }, 2000);
  </script>
</body>
</html>
''';
    request.response
      ..headers.contentType = ContentType.html
      ..write(html)
      ..close();
  }

  /// Opens the default browser to install the userscript
  Future<void> openUserscriptInstall() async {
    if (_port == null) return;
    final url = 'http://127.0.0.1:$_port/install';
    if (Platform.isLinux) {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      await Process.start('start', [url], mode: ProcessStartMode.detached, runInShell: true);
    }
  }

  Future<void> _handleKvRequest(HttpRequest request) async {
    // Parse path: /api/kv/{serviceId} or /api/kv/{serviceId}/{key}
    final pathParts = request.uri.path.split('/').where((p) => p.isNotEmpty).toList();
    // pathParts: ['api', 'kv', serviceId, ?key]

    if (pathParts.length < 3) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write('{"error":"Invalid path"}')
        ..close();
      return;
    }

    final serviceId = pathParts[2];
    final key = pathParts.length > 3 ? pathParts[3] : null;
    final store = await ServiceDataStore.getInstance();

    switch (request.method) {
      case 'GET':
        if (key != null) {
          // GET /api/kv/{serviceId}/{key}
          final value = store.get(serviceId, key);
          if (value != null) {
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode(value))
              ..close();
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..headers.contentType = ContentType.json
              ..write('{"error":"Key not found"}')
              ..close();
          }
        } else {
          // GET /api/kv/{serviceId}
          final data = store.getAll(serviceId);
          request.response
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(data))
            ..close();
        }
        break;

      case 'PUT':
        if (key == null) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write('{"error":"Key required for PUT"}')
            ..close();
          return;
        }
        try {
          final body = await utf8.decoder.bind(request).join();
          final value = jsonDecode(body);
          await store.set(serviceId, key, value);
          request.response
            ..headers.contentType = ContentType.json
            ..write('{"status":"ok"}')
            ..close();
        } catch (e) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write('{"error":"Invalid JSON body"}')
            ..close();
        }
        break;

      case 'DELETE':
        if (key != null) {
          // DELETE /api/kv/{serviceId}/{key}
          await store.delete(serviceId, key);
        } else {
          // DELETE /api/kv/{serviceId}
          await store.deleteAll(serviceId);
        }
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status":"ok"}')
          ..close();
        break;

      default:
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..headers.contentType = ContentType.json
          ..write('{"error":"Method not allowed"}')
          ..close();
    }
  }

  Future<void> _handlePlayerRequest(HttpRequest request) async {
    final path = request.uri.path;
    final player = ExternalPlayer.getInstance();

    if (path == '/api/player/play' && request.method == 'POST') {
      print('Player API: Received play request');
      try {
        final body = await utf8.decoder.bind(request).join();
        print('Player API: Body: $body');
        final data = jsonDecode(body) as Map<String, dynamic>;

        final url = data['url'] as String?;
        if (url == null || url.isEmpty) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write('{"error":"url is required"}')
            ..close();
          return;
        }

        final title = data['title'] as String?;
        final startPosition = (data['startPosition'] as num?)?.toDouble() ?? 0;
        final onComplete = data['onComplete'] as Map<String, dynamic>?;

        await player.play(
          url: url,
          title: title,
          startPosition: startPosition,
          onComplete: onComplete,
        );

        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status":"playing","position":${startPosition.toStringAsFixed(1)}}')
          ..close();
      } catch (e) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write('{"error":"Invalid request: $e"}')
          ..close();
      }
    } else if (path == '/api/player/status' && request.method == 'GET') {
      final status = player.getStatus();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(status))
        ..close();
    } else if (path == '/api/player/stop' && request.method == 'POST') {
      await player.stop();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok"}')
        ..close();
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.json
        ..write('{"error":"Unknown player endpoint"}')
        ..close();
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = null;
  }
}

// Available colors for selection
final List<Color> availableColors = [
  const Color(0xFF000000), // Black
  const Color(0xFFFFFFFF), // White
  const Color(0xFFE50914), // Netflix Red
  const Color(0xFF00A4DC), // Jellyfin Blue
  const Color(0xFFFFD000), // Pluto Yellow
  const Color(0xFFE91E63), // Pink
  const Color(0xFF4CAF50), // Green
  const Color(0xFF9C27B0), // Purple
  const Color(0xFFFF5722), // Deep Orange
  const Color(0xFF2196F3), // Blue
  const Color(0xFF00BCD4), // Cyan
  const Color(0xFF795548), // Brown
  const Color(0xFF607D8B), // Blue Grey
  const Color(0xFFFF9800), // Orange
];

class LaunchTubeApp extends StatelessWidget {
  const LaunchTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Launch Tube',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1A1A2E),
      ),
      home: const LauncherHome(),
    );
  }
}

class LauncherHome extends StatefulWidget {
  const LauncherHome({super.key});

  @override
  State<LauncherHome> createState() => _LauncherHomeState();
}

class _LauncherHomeState extends State<LauncherHome> {
  List<AppConfig> apps = [];
  int _selectedIndex = 0;
  bool _moveMode = false;
  int? _moveFromIndex;
  final FocusNode _focusNode = FocusNode();
  final LaunchTubeServer _server = LaunchTubeServer();

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _loadApps();
    _server.setAppsProvider(() => apps);
    _server.start();
  }

  @override
  void dispose() {
    _server.stop();
    _focusNode.dispose();
    super.dispose();
  }

  Future<String> get _configPath async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/apps.json';
  }

  Future<void> _loadApps() async {
    try {
      final path = await _configPath;
      final file = File(path);
      if (await file.exists()) {
        final contents = await file.readAsString();
        final List<dynamic> jsonList = json.decode(contents);
        setState(() {
          apps = jsonList.map((j) => AppConfig.fromJson(j)).toList();
        });
      } else {
        setState(() {
          apps = defaultApps;
        });
        await _saveApps();
      }
    } catch (e) {
      setState(() {
        apps = defaultApps;
      });
    }
  }

  Future<void> _saveApps() async {
    try {
      final path = await _configPath;
      final file = File(path);
      await file.writeAsString(json.encode(apps.map((a) => a.toJson()).toList()));
    } catch (e) {
      // Ignore save errors
    }
  }

  void _enterFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _launchApp(AppConfig app) async {
    try {
      if (app.type == AppType.website) {
        final firefoxArgs = <String>[];
        if (app.kioskMode) {
          firefoxArgs.add('--kiosk');
        }
        firefoxArgs.add(app.url!);

        if (Platform.isLinux) {
          await Process.start('firefox', firefoxArgs, mode: ProcessStartMode.detached);
        } else if (Platform.isWindows) {
          await Process.start('firefox.exe', firefoxArgs, mode: ProcessStartMode.detached);
        }
      } else {
        final parts = app.commandLine!.split(' ').where((s) => s.isNotEmpty).toList();
        final command = parts.first;
        final args = parts.skip(1).toList();
        await Process.start(command, args, mode: ProcessStartMode.detached);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to launch ${app.name}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      setState(() {
        final totalItems = apps.length + 1; // +1 for add button
        const int columns = 4;

        // Handle escape to cancel move mode
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          if (_moveMode) {
            _moveMode = false;
            _selectedIndex = _moveFromIndex!;
            _moveFromIndex = null;
          }
          return;
        }

        // In move mode, limit navigation to app tiles only (not add button)
        final maxIndex = _moveMode ? apps.length - 1 : totalItems - 1;

        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (_moveMode) {
            _selectedIndex = (_selectedIndex + 1).clamp(0, maxIndex);
          } else {
            _selectedIndex = (_selectedIndex + 1) % totalItems;
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          if (_moveMode) {
            _selectedIndex = (_selectedIndex - 1).clamp(0, maxIndex);
          } else {
            _selectedIndex = (_selectedIndex - 1 + totalItems) % totalItems;
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          if (_moveMode) {
            _selectedIndex = (_selectedIndex + columns).clamp(0, maxIndex);
          } else {
            _selectedIndex = (_selectedIndex + columns) % totalItems;
          }
        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          if (_moveMode) {
            _selectedIndex = (_selectedIndex - columns).clamp(0, maxIndex);
          } else {
            _selectedIndex = (_selectedIndex - columns + totalItems) % totalItems;
          }
        } else if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.select) {
          if (_moveMode) {
            // Confirm move
            if (_moveFromIndex != _selectedIndex) {
              final item = apps.removeAt(_moveFromIndex!);
              apps.insert(_selectedIndex, item);
              _saveApps();
            }
            _moveMode = false;
            _moveFromIndex = null;
          } else {
            if (_selectedIndex < apps.length) {
              _launchApp(apps[_selectedIndex]);
            } else {
              _showAddDialog();
            }
          }
        } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
          if (!_moveMode && _selectedIndex < apps.length) {
            _showEditDialog(_selectedIndex);
          }
        } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
          // Toggle move mode for current app
          if (_selectedIndex < apps.length) {
            if (_moveMode) {
              // Cancel move mode
              _moveMode = false;
              _selectedIndex = _moveFromIndex!;
              _moveFromIndex = null;
            } else {
              // Enter move mode
              _moveMode = true;
              _moveFromIndex = _selectedIndex;
            }
          }
        }
      });
    }
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (context) => ServicePickerDialog(
        onCustom: () {
          Navigator.of(context).pop();
          final random = Random();
          final randomColor = availableColors[random.nextInt(availableColors.length)];
          final newApp = AppConfig(
            name: '',
            type: AppType.website,
            colorValue: randomColor.value,
          );
          _showConfigDialog(newApp, isNew: true);
        },
        onSelectService: (ServiceTemplate service) {
          Navigator.of(context).pop();
          setState(() {
            apps.add(service.toAppConfig());
          });
          _saveApps();
        },
      ),
    );
  }

  void _showEditDialog(int index) {
    _showConfigDialog(apps[index].copy(), isNew: false, index: index);
  }

  void _showConfigDialog(AppConfig app, {required bool isNew, int? index}) {
    showDialog(
      context: context,
      builder: (context) => AppConfigDialog(
        app: app,
        isNew: isNew,
        onSave: (savedApp) {
          setState(() {
            if (isNew) {
              apps.add(savedApp);
            } else {
              apps[index!] = savedApp;
            }
          });
          _saveApps();
        },
        onDelete: isNew
            ? null
            : () {
                setState(() {
                  apps.removeAt(index!);
                  if (_selectedIndex >= apps.length) {
                    _selectedIndex = apps.length;
                  }
                });
                _saveApps();
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Stack(
                alignment: Alignment.center,
                children: [
                  Center(child: Image.asset('assets/images/launch-tube-logo/logo_wide.png', height: 100)),
                  Positioned(
                    left: 20,
                    child: PopupMenuButton<String>(
                      icon: const Icon(Icons.menu, color: Colors.white54),
                      tooltip: 'Menu',
                      color: const Color(0xFF2A2A4E),
                      onSelected: (value) {
                        switch (value) {
                          case 'install_userscript':
                            _server.openUserscriptInstall();
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'install_userscript',
                          child: Row(
                            children: [
                              Icon(Icons.extension, color: Colors.white70),
                              SizedBox(width: 12),
                              Text('Install Browser Userscript'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              LayoutBuilder(
                builder: (context, constraints) {
                  final screenWidth = MediaQuery.of(context).size.width;
                  final screenHeight = MediaQuery.of(context).size.height;
                  final horizontalPadding = screenWidth * 0.05;
                  final verticalPadding = screenHeight * 0.05;

                  return Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: verticalPadding,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const crossAxisCount = 4;
                        final spacing = screenWidth * 0.015;
                        final itemWidth = (constraints.maxWidth - (spacing * (crossAxisCount - 1))) / crossAxisCount;
                        final itemHeight = itemWidth / 3.75;

                        return Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            ...List.generate(apps.length, (index) {
                              return DragTarget<int>(
                                onWillAcceptWithDetails: (details) => details.data != index,
                                onAcceptWithDetails: (details) {
                                  setState(() {
                                    final fromIndex = details.data;
                                    final item = apps.removeAt(fromIndex);
                                    apps.insert(index, item);
                                    _selectedIndex = index;
                                  });
                                  _saveApps();
                                },
                                builder: (context, candidateData, rejectedData) {
                                  return LongPressDraggable<int>(
                                    data: index,
                                    feedback: Material(
                                      color: Colors.transparent,
                                      child: SizedBox(
                                        width: itemWidth,
                                        height: itemHeight,
                                        child: Opacity(
                                          opacity: 0.8,
                                          child: AppTile(
                                            app: apps[index],
                                            isSelected: true,
                                            onTap: () {},
                                            onHover: (_) {},
                                            onEdit: () {},
                                          ),
                                        ),
                                      ),
                                    ),
                                    childWhenDragging: SizedBox(
                                      width: itemWidth,
                                      height: itemHeight,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(color: Colors.white24, width: 2),
                                        ),
                                      ),
                                    ),
                                    child: SizedBox(
                                      width: itemWidth,
                                      height: itemHeight,
                                      child: AppTile(
                                        app: apps[index],
                                        isSelected: _selectedIndex == index,
                                        isDropTarget: candidateData.isNotEmpty || (_moveMode && _selectedIndex == index && _moveFromIndex != index),
                                        isMoving: _moveMode && _moveFromIndex == index,
                                        onTap: () {
                                          if (_moveMode) {
                                            // In move mode, tap confirms move to this position
                                            if (_moveFromIndex != index) {
                                              setState(() {
                                                final item = apps.removeAt(_moveFromIndex!);
                                                apps.insert(index, item);
                                                _selectedIndex = index;
                                                _moveMode = false;
                                                _moveFromIndex = null;
                                              });
                                              _saveApps();
                                            }
                                          } else {
                                            setState(() => _selectedIndex = index);
                                            _launchApp(apps[index]);
                                          }
                                        },
                                        onHover: (hovering) {
                                          if (hovering) {
                                            setState(() => _selectedIndex = index);
                                          }
                                        },
                                        onEdit: () => _showEditDialog(index),
                                      ),
                                    ),
                                  );
                                },
                              );
                            }),
                            SizedBox(
                              width: itemWidth,
                              height: itemHeight,
                              child: AddTile(
                                isSelected: _selectedIndex == apps.length,
                                onTap: _showAddDialog,
                                onHover: (hovering) {
                                  if (hovering) {
                                    setState(() => _selectedIndex = apps.length);
                                  }
                                },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class AppTile extends StatefulWidget {
  final AppConfig app;
  final bool isSelected;
  final bool isDropTarget;
  final bool isMoving;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final VoidCallback onEdit;

  const AppTile({
    super.key,
    required this.app,
    required this.isSelected,
    this.isDropTarget = false,
    this.isMoving = false,
    required this.onTap,
    required this.onHover,
    required this.onEdit,
  });

  @override
  State<AppTile> createState() => _AppTileState();
}

class _AppTileState extends State<AppTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final hasImage = widget.app.imagePath != null && widget.app.imagePath!.isNotEmpty;

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovering = true);
        widget.onHover(true);
      },
      onExit: (_) {
        setState(() => _isHovering = false);
        widget.onHover(false);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          transform: Matrix4.identity()..scale(widget.isSelected ? 1.1 : 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            color: widget.isMoving ? widget.app.color.withOpacity(0.5) : widget.app.color,
            borderRadius: BorderRadius.circular(20),
            border: widget.isMoving
                ? Border.all(color: Colors.orangeAccent, width: 4)
                : widget.isDropTarget
                    ? Border.all(color: Colors.greenAccent, width: 4)
                    : widget.isSelected
                        ? Border.all(color: Colors.white, width: 4)
                        : null,
            boxShadow: widget.isMoving
                ? [
                    BoxShadow(
                      color: Colors.orangeAccent.withOpacity(0.6),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ]
                : widget.isDropTarget
                    ? [
                        BoxShadow(
                          color: Colors.greenAccent.withOpacity(0.6),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ]
                    : widget.isSelected
                        ? [
                            BoxShadow(
                              color: widget.app.color.withOpacity(0.6),
                              blurRadius: 30,
                              spreadRadius: 5,
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 5),
                            ),
                          ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.isSelected ? 16 : 20),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final padding = constraints.maxHeight * 0.10;
                return Padding(
                  padding: EdgeInsets.all(padding),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasImage)
                        Image.file(
                          File(widget.app.imagePath!),
                          fit: BoxFit.contain,
                        ),
                  if (widget.app.showName)
                    Center(
                      child: Text(
                        widget.app.name,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                      if (_isHovering || widget.isSelected)
                        Positioned(
                          top: -4,
                          right: -4,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.settings, color: Colors.white),
                              onPressed: widget.onEdit,
                              tooltip: 'Edit',
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class AddTile extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  const AddTile({
    super.key,
    required this.isSelected,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          transform: Matrix4.identity()..scale(isSelected ? 1.1 : 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(isSelected ? 0.3 : 0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(isSelected ? 1.0 : 0.3),
              width: isSelected ? 4 : 2,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.white.withOpacity(0.3),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ]
                : null,
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add,
                size: 64,
                color: Colors.white,
              ),
              SizedBox(height: 16),
              Text(
                'Add App',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppConfigDialog extends StatefulWidget {
  final AppConfig app;
  final bool isNew;
  final Function(AppConfig) onSave;
  final VoidCallback? onDelete;

  const AppConfigDialog({
    super.key,
    required this.app,
    required this.isNew,
    required this.onSave,
    this.onDelete,
  });

  @override
  State<AppConfigDialog> createState() => _AppConfigDialogState();
}

class _AppConfigDialogState extends State<AppConfigDialog> {
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _commandLineController;
  late TextEditingController _imagePathController;
  late AppType _type;
  late bool _kioskMode;
  late bool _showName;
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.app.name);
    _urlController = TextEditingController(text: widget.app.url ?? '');
    _commandLineController = TextEditingController(text: widget.app.commandLine ?? '');
    _imagePathController = TextEditingController(text: widget.app.imagePath ?? '');
    _type = widget.app.type;
    _kioskMode = widget.app.kioskMode;
    _showName = widget.app.showName;
    _selectedColor = Color(widget.app.colorValue);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _commandLineController.dispose();
    _imagePathController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    String? initialDir;
    if (_imagePathController.text.isNotEmpty) {
      initialDir = File(_imagePathController.text).parent.path;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      initialDirectory: initialDir,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        _imagePathController.text = result.files.first.path ?? '';
        if (_imagePathController.text.isNotEmpty) {
          _showName = false;
        }
      });
    }
  }

  void _showColorPicker() {
    Color pickerColor = _selectedColor;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A4E),
        title: const Text('Pick a Color', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: pickerColor,
            onColorChanged: (color) => pickerColor = color,
            enableAlpha: false,
            displayThumbColor: true,
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _selectedColor = pickerColor);
              Navigator.of(context).pop();
            },
            child: const Text('Select'),
          ),
        ],
      ),
    );
  }

  void _save() {
    if (_nameController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required'), backgroundColor: Colors.red),
      );
      return;
    }

    if (_type == AppType.website && _urlController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL is required for websites'), backgroundColor: Colors.red),
      );
      return;
    }

    if (_type == AppType.native && _commandLineController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Command line is required for native apps'), backgroundColor: Colors.red),
      );
      return;
    }

    widget.app.name = _nameController.text;
    widget.app.url = _type == AppType.website ? _urlController.text : null;
    widget.app.kioskMode = _kioskMode;
    widget.app.commandLine = _type == AppType.native ? _commandLineController.text : null;
    widget.app.type = _type;
    widget.app.imagePath = _imagePathController.text.isEmpty ? null : _imagePathController.text;
    widget.app.colorValue = _selectedColor.value;
    widget.app.showName = _showName;

    widget.onSave(widget.app);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2A2A4E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.isNew ? 'Add App' : 'Edit App',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Type', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              SegmentedButton<AppType>(
                segments: const [
                  ButtonSegment(value: AppType.website, label: Text('Website')),
                  ButtonSegment(value: AppType.native, label: Text('Native App')),
                ],
                selected: {_type},
                onSelectionChanged: (set) {
                  setState(() => _type = set.first);
                },
              ),
              const SizedBox(height: 16),
              if (_type == AppType.website) ...[
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'URL',
                    hintText: 'https://example.com',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  title: const Text('Kiosk Mode', style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                    'Opens in fullscreen without browser UI',
                    style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                  ),
                  value: _kioskMode,
                  onChanged: (value) => setState(() => _kioskMode = value ?? true),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
              if (_type == AppType.native)
                TextField(
                  controller: _commandLineController,
                  decoration: const InputDecoration(
                    labelText: 'Command Line',
                    hintText: 'e.g., vlc --fullscreen /path/to/file',
                    border: OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _imagePathController,
                      decoration: const InputDecoration(
                        labelText: 'Image Path (optional)',
                        hintText: 'Select an image file',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Browse'),
                  ),
                  if (_imagePathController.text.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => setState(() => _imagePathController.clear()),
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear image',
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Leave empty to use color background',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.5),
                ),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                title: const Text('Show Name on Card', style: TextStyle(color: Colors.white)),
                value: _showName,
                onChanged: (value) => setState(() => _showName = value ?? true),
                contentPadding: EdgeInsets.zero,
              ),
              const SizedBox(height: 16),
              const Text('Background Color', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...List.generate(availableColors.length, (index) {
                    final color = availableColors[index];
                    final isSelected = _selectedColor.value == color.value;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedColor = color),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(8),
                          border: isSelected
                              ? Border.all(color: Colors.white, width: 3)
                              : Border.all(color: Colors.white24, width: 1),
                        ),
                        child: isSelected
                            ? Icon(Icons.check,
                                color: color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
                            : null,
                      ),
                    );
                  }),
                  // Custom color picker button
                  GestureDetector(
                    onTap: () => _showColorPicker(),
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Colors.red, Colors.orange, Colors.yellow, Colors.green, Colors.blue, Colors.purple],
                        ),
                        borderRadius: BorderRadius.circular(8),
                        border: !availableColors.any((c) => c.value == _selectedColor.value)
                            ? Border.all(color: Colors.white, width: 3)
                            : Border.all(color: Colors.white24, width: 1),
                      ),
                      child: const Icon(Icons.colorize, color: Colors.white),
                    ),
                  ),
                ],
              ),
              if (!availableColors.any((c) => c.value == _selectedColor.value))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: _selectedColor,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.white54),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Custom: #${_selectedColor.value.toRadixString(16).substring(2).toUpperCase()}',
                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.onDelete != null)
                    TextButton(
                      onPressed: () {
                        widget.onDelete!();
                        Navigator.of(context).pop();
                      },
                      child: const Text('Delete', style: TextStyle(color: Colors.red)),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ServicePickerDialog extends StatefulWidget {
  final VoidCallback onCustom;
  final Function(ServiceTemplate) onSelectService;

  const ServicePickerDialog({
    super.key,
    required this.onCustom,
    required this.onSelectService,
  });

  @override
  State<ServicePickerDialog> createState() => _ServicePickerDialogState();
}

class _ServicePickerDialogState extends State<ServicePickerDialog> {
  int _selectedIndex = 0;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  static const int _columns = 4;
  static const double _spacing = 16;
  static const double _aspectRatio = 3.75;
  Offset? _lastMousePosition;
  List<ServiceTemplate>? _services;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadServices();
  }

  Future<void> _loadServices() async {
    final services = await ServiceLibraryLoader.loadServices();
    if (mounted) {
      setState(() {
        _services = services;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }

      // Calculate item height from grid width and aspect ratio
      final viewportWidth = MediaQuery.of(context).size.width * 0.8 - 48; // dialog width minus padding
      final itemWidth = (viewportWidth - (_spacing * (_columns - 1))) / _columns;
      final itemHeight = itemWidth / _aspectRatio;

      final row = _selectedIndex ~/ _columns;
      final rowTop = row * (itemHeight + _spacing);
      final rowBottom = rowTop + itemHeight;

      final viewportTop = _scrollController.offset;
      final viewportBottom = viewportTop + _scrollController.position.viewportDimension;

      if (rowTop < viewportTop) {
        _scrollController.animateTo(
          rowTop,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else if (rowBottom > viewportBottom) {
        final target = rowBottom - _scrollController.position.viewportDimension;
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleMouseMove(Offset position, int index) {
    // Only update selection if mouse actually moved
    if (_lastMousePosition != position) {
      _lastMousePosition = position;
      setState(() => _selectedIndex = index);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent && _services != null) {
      final totalItems = _services!.length + 1; // +1 for custom
      final lastIndex = totalItems - 1;

      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_selectedIndex < lastIndex) {
          setState(() => _selectedIndex = _selectedIndex + 1);
          _scrollToSelected();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (_selectedIndex > 0) {
          setState(() => _selectedIndex = _selectedIndex - 1);
          _scrollToSelected();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (_selectedIndex + _columns <= lastIndex) {
          setState(() => _selectedIndex = _selectedIndex + _columns);
          _scrollToSelected();
        } else if (_selectedIndex < lastIndex) {
          // Move to last item if we can't go a full row down
          setState(() => _selectedIndex = lastIndex);
          _scrollToSelected();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_selectedIndex - _columns >= 0) {
          setState(() => _selectedIndex = _selectedIndex - _columns);
          _scrollToSelected();
        } else if (_selectedIndex > 0) {
          // Move to first item if we can't go a full row up
          setState(() => _selectedIndex = 0);
          _scrollToSelected();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        _selectItem(_selectedIndex);
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.of(context).pop();
      }
    }
  }

  void _selectItem(int index) {
    if (index == 0) {
      widget.onCustom();
    } else if (_services != null) {
      widget.onSelectService(_services![index - 1]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.8,
          height: MediaQuery.of(context).size.height * 0.8,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Add Service',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _columns,
                          childAspectRatio: _aspectRatio,
                          crossAxisSpacing: _spacing,
                          mainAxisSpacing: _spacing,
                        ),
                        itemCount: (_services?.length ?? 0) + 1,
                        itemBuilder: (context, index) {
                          final isSelected = _selectedIndex == index;

                          if (index == 0) {
                            // Custom service card
                            return _ServiceCard(
                              name: 'Custom',
                              color: Colors.white.withOpacity(0.1),
                              isSelected: isSelected,
                              isCustom: true,
                              onTap: () => _selectItem(0),
                              onHoverEvent: (event) => _handleMouseMove(event.position, 0),
                            );
                          }

                          final service = _services![index - 1];
                          return _ServiceCard(
                            name: service.name,
                            color: Color(service.colorValue),
                            isSelected: isSelected,
                            logoPath: service.logoPath,
                            isBundledLogo: service.isBundled,
                            onTap: () => _selectItem(index),
                            onHoverEvent: (event) => _handleMouseMove(event.position, index),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final String name;
  final Color color;
  final bool isSelected;
  final bool isCustom;
  final String? logoPath;
  final bool isBundledLogo;
  final VoidCallback onTap;
  final void Function(PointerHoverEvent) onHoverEvent;

  const _ServiceCard({
    required this.name,
    required this.color,
    required this.isSelected,
    this.isCustom = false,
    this.logoPath,
    this.isBundledLogo = true,
    required this.onTap,
    required this.onHoverEvent,
  });

  Widget? _buildLogo() {
    if (logoPath == null) return null;
    if (isBundledLogo) {
      return Image.asset(logoPath!, fit: BoxFit.contain);
    } else {
      return Image.file(File(logoPath!), fit: BoxFit.contain);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: onHoverEvent,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
          transform: Matrix4.identity()..scale(isSelected ? 1.05 : 1.0),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: isCustom
                ? Border.all(
                    color: isSelected ? Colors.white : Colors.white38,
                    width: isSelected ? 3 : 2,
                    style: BorderStyle.solid,
                  )
                : isSelected
                    ? Border.all(color: Colors.white, width: 3)
                    : null,
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: color.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Center(
              child: isCustom
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add, color: Colors.white, size: 32),
                        SizedBox(height: 4),
                        Text(
                          'Custom',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    )
                  : logoPath != null
                      ? _buildLogo()!
                      : Text(
                          name,
                          style: TextStyle(
                            color: color.computeLuminance() > 0.5
                                ? Colors.black
                                : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                          textAlign: TextAlign.center,
                        ),
            ),
          ),
        ),
      ),
    );
  }
}
