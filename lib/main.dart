import 'dart:io';
import 'package:flutter/widgets.dart';

import 'screensaver.dart';
import 'services.dart';
import 'widgets.dart';

// Build-time constants injected via --dart-define
const String appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
const String buildDate = String.fromEnvironment('BUILD_DATE', defaultValue: 'unknown');
const String gitCommit = String.fromEnvironment('GIT_COMMIT', defaultValue: 'unknown');

void main(List<String> args) async {
  // Handle --version flag before Flutter initialization
  if (args.contains('--version') || args.contains('-v')) {
    print('Launch Tube $appVersion');
    print('Build: $buildDate');
    print('Commit: $gitCommit');
    exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();
  // Initialize app support dir and logging
  await initAppSupportDir();
  await Log.init();
  Log.write('Asset directory: ${getAssetDirectory()}');

  // Start screensaver inhibitor (checks mpv and browser for video playback)
  ScreensaverInhibitor.getInstance().start();

  runApp(const LaunchTubeApp());
}
