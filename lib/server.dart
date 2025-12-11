import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'services.dart';
import 'player.dart';

// Build-time constants - these need to be passed in or imported
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
const String buildDate = String.fromEnvironment('BUILD_DATE', defaultValue: 'unknown');
const String gitCommit = String.fromEnvironment('GIT_COMMIT', defaultValue: 'unknown');

// HTTP server for serving userscripts to browser extensions
class LaunchTubeServer {
  HttpServer? _server;
  int? _port;
  List<AppConfig> Function()? _getApps;
  Future<void> Function()? _closeBrowser;

  int? get port => _port;

  void setAppsProvider(List<AppConfig> Function() getApps) {
    _getApps = getApps;
  }

  void setCloseBrowserCallback(Future<void> Function() closeBrowser) {
    _closeBrowser = closeBrowser;
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

    if (request.uri.path.startsWith('/api/1/service/')) {
      final serviceId = request.uri.path.split('/').last;
      await _serveServiceScript(request, serviceId);
    } else if (request.uri.path == '/api/1/ping') {
      // Health check endpoint for port discovery
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","app":"launchtube"}')
        ..close();
    } else if (request.uri.path == '/api/1/version') {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'app': 'launchtube',
          'version': appVersion,
          'commit': gitCommit,
          'build': buildDate,
        }))
        ..close();
    } else if (request.uri.path == '/launchtube-loader.user.js') {
      // Serve userscript for Tampermonkey installation
      await _serveUserscript(request);
    } else if (request.uri.path == '/install') {
      // Serve install page that auto-closes
      await _serveInstallPage(request);
    } else if (request.uri.path == '/api/1/shutdown') {
      // Stop player and close browser before shutting down
      await ExternalPlayer.getInstance().stop();
      if (_closeBrowser != null) {
        await _closeBrowser!();
      }
      // Trigger application shutdown
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok","message":"shutting down"}')
        ..close();
      // Exit the application after responding
      Future.delayed(const Duration(milliseconds: 100), () => exit(0));
    } else if (request.uri.path == '/api/1/status') {
      // Status endpoint with server info
      final status = jsonEncode({
        'status': 'ok',
        'app': 'launchtube',
        'port': _port,
        'endpoints': [
          '/api/1/ping',
          '/api/1/version',
          '/api/1/status',
          '/api/1/shutdown',
          '/api/1/match?url={pageUrl}&version={serviceVersion}',
          '/api/1/service/{serviceId}',
          '/api/1/kv/{serviceId}',
          '/api/1/kv/{serviceId}/{key}',
          '/api/1/player/play',
          '/api/1/player/playlist',
          '/api/1/player/status',
          '/api/1/player/stop',
          '/api/1/browser/close',
          '/install',
          '/launchtube-loader.user.js',
        ],
      });
      request.response
        ..headers.contentType = ContentType.json
        ..write(status)
        ..close();
    } else if (request.uri.path == '/api/1/match') {
      await _handleMatchRequest(request);
    } else if (request.uri.path.startsWith('/api/1/player/')) {
      await _handlePlayerRequest(request);
    } else if (request.uri.path.startsWith('/api/1/kv/')) {
      await _handleKvRequest(request);
    } else {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not found')
        ..close();
    }
  }

  Future<void> _serveServiceScript(HttpRequest request, String serviceId, {String? version}) async {
    final dataDir = getAssetDirectory();
    final cache = FileCache.getInstance();

    // Try to find versioned script if version specified
    String scriptPath = '$dataDir/services/$serviceId.js';
    if (version != null) {
      final versionedPath = await _findBestVersionedScript(dataDir, serviceId, version);
      if (versionedPath != null) {
        scriptPath = versionedPath;
      } else {
        // Version requested but no versioned script available - return 204
        // to tell client to use its base implementation
        request.response
          ..statusCode = HttpStatus.noContent
          ..close();
        return;
      }
    }

    final script = await cache.getString(scriptPath);
    if (script == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('// Script not found for service: $serviceId')
        ..close();
      return;
    }

    // Prepend LaunchTube version so service scripts can check compatibility
    final versionedScript = 'window.LAUNCH_TUBE_VERSION = "$appVersion";\n$script';

    final mtime = cache.getMtime(scriptPath);
    request.response
      ..headers.contentType = ContentType('application', 'javascript', charset: 'utf-8')
      ..headers.add('Cache-Control', 'max-age=31536000')
      ..headers.add('ETag', '"${mtime?.millisecondsSinceEpoch ?? 0}"')
      ..write(versionedScript)
      ..close();
  }

  /// Find the best versioned script file for a service.
  /// Returns the path to the best matching versioned script, or null if none found.
  /// Picks the highest version <= requested version.
  /// If requested version is older than all available, returns oldest available.
  Future<String?> _findBestVersionedScript(String dataDir, String serviceId, String requestedVersion) async {
    final servicesDir = Directory('$dataDir/services');
    if (!await servicesDir.exists()) return null;

    // Pattern: {serviceId}-{version}.js where version is like 10.8 or 10.8.1
    final pattern = RegExp('^${RegExp.escape(serviceId)}-(\\d+(?:\\.\\d+)*)\\.js\$');
    final availableVersions = <String, String>{}; // version string -> filepath

    await for (final entity in servicesDir.list()) {
      if (entity is! File) continue;
      final filename = entity.uri.pathSegments.last;
      final match = pattern.firstMatch(filename);
      if (match != null) {
        availableVersions[match.group(1)!] = entity.path;
      }
    }

    if (availableVersions.isEmpty) return null;

    final requestedParsed = _parseVersion(requestedVersion);
    String? bestMatch;
    List<int>? bestVersion;
    String? oldestMatch;
    List<int>? oldestVersion;

    for (final entry in availableVersions.entries) {
      final v = _parseVersion(entry.key);

      // Track oldest version as fallback
      if (oldestVersion == null || _compareVersions(v, oldestVersion) < 0) {
        oldestVersion = v;
        oldestMatch = entry.value;
      }

      // Find highest version <= requested
      if (_compareVersions(v, requestedParsed) <= 0) {
        if (bestVersion == null || _compareVersions(v, bestVersion) > 0) {
          bestVersion = v;
          bestMatch = entry.value;
        }
      }
    }

    // If no version <= requested, fall back to oldest available
    return bestMatch ?? oldestMatch;
  }

  /// Parse a version string like "10.8.1" into a list of integers [10, 8, 1]
  List<int> _parseVersion(String version) {
    return version.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  /// Compare two version lists. Returns negative if a < b, positive if a > b, 0 if equal.
  int _compareVersions(List<int> a, List<int> b) {
    final maxLen = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < maxLen; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av - bv;
    }
    return 0;
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
    final serviceVersion = request.uri.queryParameters['version'];
    await _serveServiceScript(request, serviceId, version: serviceVersion);
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
    // Parse path: /api/1/kv/{serviceId} or /api/1/kv/{serviceId}/{key}
    final pathParts = request.uri.path.split('/').where((p) => p.isNotEmpty).toList();
    // pathParts: ['api', '1', 'kv', serviceId, ?key]

    if (pathParts.length < 4) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write('{"error":"Invalid path"}')
        ..close();
      return;
    }

    final serviceId = pathParts[3];
    final key = pathParts.length > 4 ? pathParts[4] : null;
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

    if (path == '/api/1/player/play' && request.method == 'POST') {
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
    } else if (path == '/api/1/player/playlist' && request.method == 'POST') {
      print('Player API: Received playlist request');
      try {
        final body = await utf8.decoder.bind(request).join();
        print('Player API: Body: $body');
        final data = jsonDecode(body) as Map<String, dynamic>;

        final itemsData = data['items'] as List<dynamic>?;
        if (itemsData == null || itemsData.isEmpty) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write('{"error":"items array is required"}')
            ..close();
          return;
        }

        final items = itemsData.map((item) {
          final itemMap = item as Map<String, dynamic>;
          return PlaylistItem(
            url: itemMap['url'] as String,
            itemId: itemMap['itemId'] as String?,
            onComplete: itemMap['onComplete'] as Map<String, dynamic>?,
          );
        }).toList();

        final startPosition = (data['startPosition'] as num?)?.toDouble() ?? 0;

        await player.playPlaylist(
          items: items,
          startPosition: startPosition,
        );

        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status":"playing","count":${items.length}}')
          ..close();
      } catch (e) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write('{"error":"Invalid request: $e"}')
          ..close();
      }
    } else if (path == '/api/1/player/status' && request.method == 'GET') {
      final status = player.getStatus();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(status))
        ..close();
    } else if (path == '/api/1/player/stop' && request.method == 'POST') {
      await player.stop();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"status":"ok"}')
        ..close();
    } else if (path == '/api/1/browser/close' && request.method == 'POST') {
      Log.write('API: /api/1/browser/close called');
      if (_closeBrowser != null) {
        Log.write('API: Calling _closeBrowser callback');
        await _closeBrowser!();
        Log.write('API: _closeBrowser callback completed');
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"status":"ok"}')
          ..close();
      } else {
        Log.write('API: _closeBrowser callback is null');
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..headers.contentType = ContentType.json
          ..write('{"status":"error","message":"No browser to close"}')
          ..close();
      }
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
