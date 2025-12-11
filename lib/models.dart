import 'dart:io';
import 'package:flutter/material.dart';

enum AppType { website, native }

class AppConfig {
  String name;
  String? url;
  String? commandLine;
  AppType type;
  String? imagePath;
  int colorValue;
  bool showName;

  AppConfig({
    required this.name,
    this.url,
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
        'commandLine': commandLine,
        'type': type.index,
        'imagePath': imagePath,
        'colorValue': colorValue,
        'showName': showName,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        name: json['name'],
        url: json['url'],
        commandLine: json['commandLine'],
        type: AppType.values[json['type']],
        imagePath: json['imagePath'],
        colorValue: json['colorValue'],
        showName: json['showName'] ?? true,
      );

  AppConfig copy() => AppConfig(
        name: name,
        url: url,
        commandLine: commandLine,
        type: type,
        imagePath: imagePath,
        colorValue: colorValue,
        showName: showName,
      );
}

final List<AppConfig> defaultApps = [];

// Browser detection and selection
class BrowserInfo {
  final String name;
  final String executable;
  final String fullscreenFlag;

  const BrowserInfo({
    required this.name,
    required this.executable,
    required this.fullscreenFlag,
  });

  static const List<BrowserInfo> _knownBrowsers = [
    BrowserInfo(name: 'Firefox', executable: 'firefox', fullscreenFlag: '--kiosk'),
    BrowserInfo(name: 'Firefox', executable: 'firefox.exe', fullscreenFlag: '--kiosk'),
    BrowserInfo(name: 'Chrome', executable: 'google-chrome', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chrome', executable: 'google-chrome-stable', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chrome', executable: 'chrome', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chrome', executable: 'chrome.exe', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chromium', executable: 'chromium', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chromium', executable: 'chromium-browser', fullscreenFlag: '--start-fullscreen'),
    BrowserInfo(name: 'Chromium', executable: 'chromium.exe', fullscreenFlag: '--start-fullscreen'),
  ];

  static Future<List<BrowserInfo>> detectBrowsers() async {
    final found = <BrowserInfo>[];
    for (final browser in _knownBrowsers) {
      if (await isExecutableAvailable(browser.executable)) {
        found.add(browser);
      }
    }
    return found;
  }
}

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
    colorValue: colorValue,
    imagePath: logoPath,
    showName: logoPath == null,
  );
}

class PlaylistItem {
  final String url;
  final String? itemId;
  final Map<String, dynamic>? onComplete;

  PlaylistItem({required this.url, this.itemId, this.onComplete});
}

// Available colors for app tiles
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

// Shared utility to check if an executable is on the PATH
Future<bool> isExecutableAvailable(String executable) async {
  try {
    final result = await Process.run(
      Platform.isWindows ? 'where' : 'which',
      [executable],
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

// Detect available mpv executables
Future<List<String>> detectMpvExecutables() async {
  final candidates = ['mpv', 'mpv.exe'];
  final found = <String>[];
  for (final exe in candidates) {
    if (await isExecutableAvailable(exe)) {
      found.add(exe);
    }
  }
  return found;
}
