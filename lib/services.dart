import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

// Global logger that writes to file
class Log {
  static File? _logFile;
  static RandomAccessFile? _raf;

  static Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _logFile = File('${dir.path}/launchtube.log');
    // Truncate on startup
    _raf = await _logFile!.open(mode: FileMode.write);
    final header = '=== LaunchTube started at ${DateTime.now()} ===\n';
    await _raf!.writeString(header);
    await _raf!.flush();
  }

  static void write(String message) {
    final line = '${DateTime.now().toIso8601String()} $message\n';
    print(line.trimRight()); // Also print to stdout
    _raf?.writeStringSync(line);
    _raf?.flushSync();
  }
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

// Profile management for multi-user support
class ProfileManager {
  static String get _legacyProfilesPath => '$_appSupportDir/profiles.json';
  static String get _profilesDir => '$_appSupportDir/profiles';

  /// Load all user profiles by scanning profile directories
  static Future<List<UserProfile>> loadProfiles() async {
    await initAppSupportDir();

    // Migrate from old profiles.json format if it exists
    await _migrateLegacyProfiles();

    final profilesDir = Directory(_profilesDir);
    if (!await profilesDir.exists()) {
      return [];
    }

    final profiles = <UserProfile>[];
    await for (final entity in profilesDir.list()) {
      if (entity is Directory) {
        final profileFile = File('${entity.path}/profile.json');
        if (await profileFile.exists()) {
          try {
            final contents = await profileFile.readAsString();
            final json = jsonDecode(contents) as Map<String, dynamic>;
            profiles.add(UserProfile.fromJson(json));
          } catch (e) {
            debugPrint('Failed to load profile from ${entity.path}: $e');
          }
        }
      }
    }

    // Sort by order field for user-defined ordering
    profiles.sort((a, b) => a.order.compareTo(b.order));
    return profiles;
  }

  /// Migrate from old profiles.json to per-profile storage
  static Future<void> _migrateLegacyProfiles() async {
    final legacyFile = File(_legacyProfilesPath);
    if (!await legacyFile.exists()) return;

    try {
      final contents = await legacyFile.readAsString();
      final decoded = jsonDecode(contents) as List<dynamic>;
      for (final item in decoded) {
        final profile = UserProfile.fromJson(item as Map<String, dynamic>);
        await saveProfile(profile);
      }
      await legacyFile.delete();
      Log.write('Migrated ${decoded.length} profiles from legacy format');
    } catch (e) {
      debugPrint('Failed to migrate legacy profiles: $e');
    }
  }

  /// Save a single profile to its profile.json
  static Future<void> saveProfile(UserProfile profile) async {
    await initAppSupportDir();
    final profileDir = Directory(getProfileDirectory(profile));
    if (!await profileDir.exists()) {
      await profileDir.create(recursive: true);
    }
    final profileFile = File('${profileDir.path}/profile.json');
    await profileFile.writeAsString(jsonEncode(profile.toJson()));
  }

  /// Save multiple profiles (e.g., after reordering)
  static Future<void> saveProfiles(List<UserProfile> profiles) async {
    for (final profile in profiles) {
      await saveProfile(profile);
    }
  }

  /// Create a new profile and its directory structure
  static Future<UserProfile> createProfile(String displayName, int colorValue, {String? photoPath, int? order}) async {
    await initAppSupportDir();

    // Generate unique ID from display name
    var id = UserProfile.sanitizeId(displayName);
    if (id.isEmpty) id = 'user';

    // Ensure uniqueness by checking existing directories and count profiles for order
    final profilesDir = Directory(_profilesDir);
    final existingIds = <String>{};
    var profileCount = 0;
    if (await profilesDir.exists()) {
      await for (final entity in profilesDir.list()) {
        if (entity is Directory) {
          existingIds.add(entity.path.split('/').last);
          profileCount++;
        }
      }
    }

    var uniqueId = id;
    var counter = 1;
    while (existingIds.contains(uniqueId)) {
      uniqueId = '${id}_$counter';
      counter++;
    }

    final profile = UserProfile(
      id: uniqueId,
      displayName: displayName,
      colorValue: colorValue,
      photoPath: photoPath,
      order: order ?? profileCount, // New profiles go to the end
    );

    // Save profile.json
    await saveProfile(profile);

    return profile;
  }

  /// Delete a profile directory
  static Future<void> deleteProfile(String id) async {
    await initAppSupportDir();
    final profileDir = Directory('$_profilesDir/$id');
    if (await profileDir.exists()) {
      await profileDir.delete(recursive: true);
    }
  }

  /// Get the profile directory path
  static String getProfileDirectory(UserProfile profile) {
    return '$_profilesDir/${profile.id}';
  }

  /// Get the browser profile path for Chrome's --user-data-dir
  static String getBrowserProfilePath(UserProfile profile) {
    return '${getProfileDirectory(profile)}/chrome';
  }

  /// Get the apps.json path for a profile
  static String getAppsPath(UserProfile profile) {
    return '${getProfileDirectory(profile)}/apps.json';
  }

  /// Check if there's an existing apps.json that needs migration
  static Future<bool> hasLegacyApps() async {
    await initAppSupportDir();
    final oldAppsFile = File('$_appSupportDir/apps.json');
    return await oldAppsFile.exists();
  }

  /// Migrate existing apps.json to a profile
  static Future<void> migrateLegacyApps(UserProfile profile) async {
    await initAppSupportDir();
    final oldAppsFile = File('$_appSupportDir/apps.json');
    if (await oldAppsFile.exists()) {
      final newAppsPath = getAppsPath(profile);
      await oldAppsFile.copy(newAppsPath);
      // Remove old file after successful migration
      await oldAppsFile.delete();
      Log.write('Migrated apps.json to profile: ${profile.id}');
    }
  }
}

// Data directory for runtime assets
String? _cachedAssetDir;
String? _appSupportDir;

Future<String> initAppSupportDir() async {
  _appSupportDir ??= (await getApplicationSupportDirectory()).path;
  return _appSupportDir!;
}

String getAssetDirectory() {
  if (_cachedAssetDir != null) return _cachedAssetDir!;

  // First, try <app-support-dir>/assets (e.g. ~/.local/share/launchtube/assets)
  // But we can't await here, so check synchronously using the cached value or HOME fallback
  final home = Platform.environment['HOME'];
  final userDir = _appSupportDir != null
      ? '$_appSupportDir/assets'
      : '$home/.local/share/launchtube/assets';
  if (Directory(userDir).existsSync()) {
    print('Using asset directory: $userDir');
    _cachedAssetDir = userDir;
    return userDir;
  }

  // Fallback: look for hot-assets/ directory in parent directories of the binary
  // This enables running from source
  final exePath = Platform.resolvedExecutable;
  var dir = Directory(exePath).parent;
  for (var i = 0; i < 10; i++) {
    final hotAssetsDir = Directory('${dir.path}/hot-assets');
    if (hotAssetsDir.existsSync()) {
      print('Using asset directory: ${hotAssetsDir.path}');
      _cachedAssetDir = hotAssetsDir.path;
      return hotAssetsDir.path;
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
