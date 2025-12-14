import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'models.dart';
import 'services.dart';
import 'player.dart';
import 'server.dart';
import 'screensaver.dart';

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

class _LauncherHomeState extends State<LauncherHome> with WidgetsBindingObserver {
  List<AppConfig> apps = [];
  int _selectedIndex = 0;
  bool _moveMode = false;
  int? _moveFromIndex;
  bool _menuSelected = false;
  final GlobalKey<PopupMenuButtonState<String>> _menuKey = GlobalKey<PopupMenuButtonState<String>>();
  final FocusNode _focusNode = FocusNode();
  final LaunchTubeServer _server = LaunchTubeServer();

  // User profiles
  List<UserProfile> _profiles = [];
  UserProfile? _currentProfile;
  bool _showingUserSelection = false;
  int _userSelectedIndex = 0;
  bool _userMoveMode = false;
  int? _userMoveFromIndex;
  List<String> _availablePhotos = [];

  // Browser selection
  List<BrowserInfo> _availableBrowsers = [];
  String? _selectedBrowser; // executable name

  // Mpv selection
  List<String> _availableMpv = [];
  String? _selectedMpv; // executable path or name
  String _mpvOptions = ''; // additional mpv command-line options

  // Track launched browser process for closing
  Process? _browserProcess;
  BrowserInfo? _launchedBrowser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enterFullscreen();
    _scanProfilePhotos();
    _initializeProfiles();
    _detectBrowsers();
    _detectMpv();
    _server.setAppsProvider(() => apps);
    _server.setCloseBrowserCallback(_closeBrowser);
    _server.start();
  }

  Future<void> _scanProfilePhotos() async {
    final photosDir = Directory('${getAssetDirectory()}/images/profile-photos');
    if (!await photosDir.exists()) return;

    final photos = <String>[];
    await for (final entity in photosDir.list()) {
      if (entity is File) {
        final name = entity.path.split('/').last.toLowerCase();
        // Only include image files that aren't empty
        if ((name.endsWith('.png') || name.endsWith('.jpg') || name.endsWith('.jpeg'))) {
          final stat = await entity.stat();
          if (stat.size > 0) {
            photos.add(entity.path.split('/').last);
          }
        }
      }
    }

    photos.sort();
    setState(() {
      _availablePhotos = photos;
    });
  }

  Future<void> _initializeProfiles() async {
    // Load profiles
    final profiles = await ProfileManager.loadProfiles();

    if (profiles.isEmpty) {
      // First run - show user creation dialog
      setState(() {
        _profiles = [];
        _currentProfile = null;
        _showingUserSelection = true;
      });
      // Show the add user dialog for first-time setup
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showFirstRunUserDialog();
      });
    } else if (profiles.length == 1) {
      // Single user - skip selection, go straight to apps
      setState(() {
        _profiles = profiles;
        _currentProfile = profiles.first;
        _showingUserSelection = false;
      });
      await _loadApps();
    } else {
      // Multiple users - show selection screen
      setState(() {
        _profiles = profiles;
        _currentProfile = null;
        _showingUserSelection = true;
      });
    }
  }

  void _selectProfile(UserProfile profile) {
    setState(() {
      _currentProfile = profile;
      _showingUserSelection = false;
      _selectedIndex = 0;
    });
    _loadApps();
  }

  void _showUserSelection() {
    setState(() {
      _showingUserSelection = true;
      _userSelectedIndex = _profiles.indexWhere((p) => p.id == _currentProfile?.id);
      if (_userSelectedIndex < 0) _userSelectedIndex = 0;
    });
  }

  void _handleUserSelectionKeyEvent(KeyEvent event) {
    setState(() {
      final totalItems = _profiles.length + 1; // +1 for "Add User" tile
      const int columns = 4;

      // Handle escape - cancel move mode or go back to app grid
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_userMoveMode) {
          _userMoveMode = false;
          _userSelectedIndex = _userMoveFromIndex!;
          _userMoveFromIndex = null;
        } else if (_currentProfile != null) {
          _showingUserSelection = false;
        }
        return;
      }

      // In move mode, limit navigation to profile tiles only (not add button)
      final maxIndex = _userMoveMode ? _profiles.length - 1 : totalItems - 1;

      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_userMoveMode) {
          _userSelectedIndex = (_userSelectedIndex + 1).clamp(0, maxIndex);
        } else {
          _userSelectedIndex = (_userSelectedIndex + 1) % totalItems;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (_userMoveMode) {
          _userSelectedIndex = (_userSelectedIndex - 1).clamp(0, maxIndex);
        } else {
          _userSelectedIndex = (_userSelectedIndex - 1 + totalItems) % totalItems;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (_userMoveMode) {
          _userSelectedIndex = (_userSelectedIndex + columns).clamp(0, maxIndex);
        } else {
          _userSelectedIndex = (_userSelectedIndex + columns) % totalItems;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_userMoveMode) {
          _userSelectedIndex = (_userSelectedIndex - columns).clamp(0, maxIndex);
        } else {
          _userSelectedIndex = (_userSelectedIndex - columns + totalItems) % totalItems;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.select) {
        if (_userMoveMode) {
          // Confirm move
          if (_userMoveFromIndex != _userSelectedIndex) {
            final item = _profiles.removeAt(_userMoveFromIndex!);
            _profiles.insert(_userSelectedIndex, item);
            _updateProfileOrders();
          }
          _userMoveMode = false;
          _userMoveFromIndex = null;
        } else if (_userSelectedIndex < _profiles.length) {
          _selectProfile(_profiles[_userSelectedIndex]);
        } else {
          _showAddUserDialog();
        }
      } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
        // Edit user (like 'C' for configure on app tiles)
        if (!_userMoveMode && _userSelectedIndex < _profiles.length) {
          _showEditUserDialog(_userSelectedIndex);
        }
      } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
        // Toggle move mode for current profile
        if (_userSelectedIndex < _profiles.length) {
          if (_userMoveMode) {
            // Cancel move mode
            _userMoveMode = false;
            _userSelectedIndex = _userMoveFromIndex!;
            _userMoveFromIndex = null;
          } else {
            // Enter move mode
            _userMoveMode = true;
            _userMoveFromIndex = _userSelectedIndex;
          }
        }
      } else if (event.character == '?') {
        _showUserHelpDialog();
      } else if (event.character == '+') {
        if (!_userMoveMode) {
          _showAddUserDialog();
        }
      }
    });
  }

  void _updateProfileOrders() {
    // Update order field for each profile based on list position
    for (int i = 0; i < _profiles.length; i++) {
      _profiles[i] = _profiles[i].copyWith(order: i);
    }
    ProfileManager.saveProfiles(_profiles);
  }

  void _showUserHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
               event.logicalKey == LogicalKeyboardKey.enter ||
               event.character == '?')) {
            Navigator.of(context).pop();
          }
        },
        child: AlertDialog(
          backgroundColor: const Color(0xFF2A2A4E),
          title: const Text('Keyboard Shortcuts', style: TextStyle(color: Colors.white)),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HelpRow(shortcut: 'Arrow Keys', description: 'Navigate'),
              _HelpRow(shortcut: 'Enter', description: 'Select user'),
              _HelpRow(shortcut: '+', description: 'Add user'),
              _HelpRow(shortcut: 'C', description: 'Configure user'),
              _HelpRow(shortcut: 'M', description: 'Move user'),
              _HelpRow(shortcut: 'Escape', description: 'Cancel / Back'),
              _HelpRow(shortcut: '?', description: 'Show this help'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddUserDialog() {
    showDialog(
      context: context,
      builder: (context) => _UserDialog(
        isNewUser: true,
        availablePhotos: _availablePhotos,
        onSave: (name, colorValue, photoPath) async {
          final profile = await ProfileManager.createProfile(name, colorValue, photoPath: photoPath);
          setState(() {
            _profiles.add(profile);
            _userSelectedIndex = _profiles.length - 1;
          });
        },
      ),
    );
  }

  void _showFirstRunUserDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => _UserDialog(
        isNewUser: true,
        availablePhotos: _availablePhotos,
        onSave: (name, colorValue, photoPath) async {
          await _createFirstProfile(name, colorValue, photoPath: photoPath);
        },
      ),
    );
  }

  Future<void> _createFirstProfile(String name, int colorValue, {String? photoPath}) async {
    final profile = await ProfileManager.createProfile(name, colorValue, photoPath: photoPath);

    // Migrate legacy apps.json if it exists
    await ProfileManager.migrateLegacyApps(profile);

    setState(() {
      _profiles = [profile];
      _currentProfile = profile;
      _showingUserSelection = false;
    });
    await _loadApps();
  }

  void _showEditUserDialog(int index) {
    final profile = _profiles[index];
    showDialog(
      context: context,
      builder: (context) => _UserDialog(
        isNewUser: false,
        initialName: profile.displayName,
        initialColorValue: profile.colorValue,
        initialPhotoPath: profile.photoPath,
        availablePhotos: _availablePhotos,
        canDelete: _profiles.length > 1,
        onSave: (name, colorValue, photoPath) async {
          // Update profile
          final updatedProfile = profile.copyWith(
            displayName: name,
            colorValue: colorValue,
            photoPath: photoPath,
            clearPhoto: photoPath == null,
          );

          // Save to disk
          await ProfileManager.saveProfile(updatedProfile);

          setState(() {
            _profiles[index] = updatedProfile;
            // Update current profile if it's the one being edited
            if (_currentProfile?.id == profile.id) {
              _currentProfile = updatedProfile;
            }
          });
        },
        onDelete: () async {
          await ProfileManager.deleteProfile(profile.id);
          setState(() {
            _profiles.removeAt(index);
            if (_userSelectedIndex >= _profiles.length) {
              _userSelectedIndex = _profiles.length; // Points to "Add User"
            }
            // If we deleted the current profile, clear it
            if (_currentProfile?.id == profile.id) {
              _currentProfile = null;
            }
          });
        },
      ),
    );
  }

  Widget _buildUserSelectionScreen() {
    // During first run, show minimal UI while dialog is open
    if (_profiles.isEmpty) {
      return Column(
        children: [
          const SizedBox(height: 40),
          Center(
            child: Image.file(
              File('${getAssetDirectory()}/images/launch-tube-logo/logo_wide.png'),
              height: 100,
            ),
          ),
          const Spacer(),
          const Spacer(),
        ],
      );
    }

    return Column(
      children: [
        const SizedBox(height: 40),
        Center(
          child: Image.file(
            File('${getAssetDirectory()}/images/launch-tube-logo/logo_wide.png'),
            height: 100,
          ),
        ),
        const SizedBox(height: 40),
        const Text(
          'Who\'s watching?',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const Spacer(),
        LayoutBuilder(
          builder: (context, constraints) {
            final screenWidth = MediaQuery.of(context).size.width;
            final horizontalPadding = screenWidth * 0.15;
            const crossAxisCount = 4;
            final spacing = screenWidth * 0.02;

            return Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final itemWidth =
                      (constraints.maxWidth - (spacing * (crossAxisCount - 1))) /
                          crossAxisCount;
                  final itemHeight = itemWidth * 1.2; // Taller tiles for profiles

                  return Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      // User profile tiles with drag-and-drop
                      ...List.generate(_profiles.length, (index) {
                        final profile = _profiles[index];
                        final isSelected = _userSelectedIndex == index;
                        return DragTarget<int>(
                          onWillAcceptWithDetails: (details) => details.data != index,
                          onAcceptWithDetails: (details) {
                            setState(() {
                              final fromIndex = details.data;
                              final item = _profiles.removeAt(fromIndex);
                              _profiles.insert(index, item);
                              _userSelectedIndex = index;
                            });
                            _updateProfileOrders();
                          },
                          builder: (context, candidateData, rejectedData) {
                            return Draggable<int>(
                              data: index,
                              feedback: Material(
                                color: Colors.transparent,
                                child: SizedBox(
                                  width: itemWidth,
                                  height: itemHeight,
                                  child: Opacity(
                                    opacity: 0.8,
                                    child: _UserTile(
                                      profile: profile,
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
                                child: _UserTile(
                                  profile: profile,
                                  isSelected: false,
                                  isMoving: true,
                                  onTap: () {},
                                  onHover: (_) {},
                                  onEdit: () {},
                                ),
                              ),
                              child: SizedBox(
                                width: itemWidth,
                                height: itemHeight,
                                child: _UserTile(
                                  profile: profile,
                                  isSelected: isSelected,
                                  isDropTarget: candidateData.isNotEmpty || (_userMoveMode && _userSelectedIndex == index && _userMoveFromIndex != index),
                                  isMoving: _userMoveMode && _userMoveFromIndex == index,
                                  onTap: () {
                                    if (_userMoveMode) {
                                      // In move mode, tap confirms move to this position
                                      if (_userMoveFromIndex != index) {
                                        setState(() {
                                          final item = _profiles.removeAt(_userMoveFromIndex!);
                                          _profiles.insert(index, item);
                                          _userSelectedIndex = index;
                                          _userMoveMode = false;
                                          _userMoveFromIndex = null;
                                        });
                                        _updateProfileOrders();
                                      }
                                    } else {
                                      _selectProfile(profile);
                                    }
                                  },
                                  onHover: (hovering) {
                                    if (hovering) {
                                      setState(() => _userSelectedIndex = index);
                                    }
                                  },
                                  onEdit: () => _showEditUserDialog(index),
                                ),
                              ),
                            );
                          },
                        );
                      }),
                      // Add User tile
                      SizedBox(
                        width: itemWidth,
                        height: itemHeight,
                        child: _AddUserTile(
                          isSelected: _userSelectedIndex == _profiles.length,
                          onTap: _showAddUserDialog,
                          onHover: (hovering) {
                            if (hovering) {
                              setState(() => _userSelectedIndex = _profiles.length);
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
        const SizedBox(height: 40),
      ],
    );
  }

  Future<void> _detectBrowsers() async {
    final browsers = await BrowserInfo.detectBrowsers();
    final savedBrowser = await _loadSelectedBrowser();
    setState(() {
      _availableBrowsers = browsers;
      // Use saved browser if still available, otherwise first detected
      if (savedBrowser != null && browsers.any((b) => b.executable == savedBrowser)) {
        _selectedBrowser = savedBrowser;
      } else if (browsers.isNotEmpty) {
        _selectedBrowser = browsers.first.executable;
      }
    });
  }

  Future<String> get _settingsPath async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/settings.json';
  }

  Future<Map<String, dynamic>> _loadSettings() async {
    try {
      final path = await _settingsPath;
      final file = File(path);
      if (await file.exists()) {
        final contents = await file.readAsString();
        return json.decode(contents) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  Future<void> _saveSettings() async {
    try {
      final path = await _settingsPath;
      final settings = {
        'browser': _selectedBrowser,
        'mpvPath': _selectedMpv,
        'mpvOptions': _mpvOptions,
      };
      await File(path).writeAsString(json.encode(settings));
    } catch (_) {}
  }

  Future<String?> _loadSelectedBrowser() async {
    final settings = await _loadSettings();
    return settings['browser'] as String?;
  }

  Future<void> _saveSelectedBrowser() async {
    await _saveSettings();
  }

  Future<void> _detectMpv() async {
    final mpvList = await detectMpvExecutables();
    final savedMpv = await _loadSelectedMpv();
    final savedMpvOptions = await _loadMpvOptions();
    setState(() {
      _availableMpv = mpvList;
      // Use saved mpv if set, otherwise first detected
      if (savedMpv != null && savedMpv.isNotEmpty) {
        _selectedMpv = savedMpv;
      } else if (mpvList.isNotEmpty) {
        _selectedMpv = mpvList.first;
      }
      _mpvOptions = savedMpvOptions;
    });
    // Update the ExternalPlayer with the selected mpv and options
    if (_selectedMpv != null) {
      ExternalPlayer.getInstance().setMpvPath(_selectedMpv!);
    }
    ExternalPlayer.getInstance().setMpvOptions(_mpvOptions);
  }

  Future<String?> _loadSelectedMpv() async {
    final settings = await _loadSettings();
    return settings['mpvPath'] as String?;
  }

  Future<String> _loadMpvOptions() async {
    final settings = await _loadSettings();
    return (settings['mpvOptions'] as String?) ?? '';
  }

  Future<void> _saveSelectedMpv() async {
    await _saveSettings();
    // Update the ExternalPlayer with the new mpv path
    if (_selectedMpv != null) {
      ExternalPlayer.getInstance().setMpvPath(_selectedMpv!);
    }
  }

  Future<void> _saveMpvOptions() async {
    await _saveSettings();
    // Update the ExternalPlayer with the new mpv options
    ExternalPlayer.getInstance().setMpvOptions(_mpvOptions);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _server.stop();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App received focus - close any launched browser
      _closeBrowser();
    }
  }

  Future<String> get _configPath async {
    if (_currentProfile != null) {
      return ProfileManager.getAppsPath(_currentProfile!);
    }
    // Fallback for migration/initial state
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

  Future<bool> _isBrowserRunning(String executable) async {
    // For Windows executables on WSL, check Windows processes
    if (executable.endsWith('.exe')) {
      try {
        final exeName = executable.split('/').last;
        final result = await Process.run('tasklist.exe', ['/FI', 'IMAGENAME eq $exeName', '/NH']);
        return result.stdout.toString().toLowerCase().contains(exeName.toLowerCase());
      } catch (_) {
        return false;
      }
    } else {
      // Native Linux: use pgrep
      try {
        final result = await Process.run('pgrep', ['-x', executable]);
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
  }

  void _showBrowserWarning(List<String> running, String using) {
    if (!mounted) return;
    // Show a brief centered overlay that doesn't block
    final overlay = OverlayEntry(
      builder: (context) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 96, vertical: 64),
            decoration: BoxDecoration(
              color: Colors.orange.withAlpha(230),
              borderRadius: BorderRadius.circular(32),
            ),
            child: Text(
              '${running.join(", ")} already running. Using $using.',
              style: const TextStyle(color: Colors.white, fontSize: 64),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(overlay);
    Future.delayed(const Duration(milliseconds: 1500), () => overlay.remove());
  }

  void _showBrowserError(List<String> running) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Browser In Use'),
        content: Text('Please close ${running.join(" or ")} before launching.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _launchApp(AppConfig app) async {
    // Stop any running player and close any existing browser first
    await ExternalPlayer.getInstance().stop();
    await _closeBrowser();

    try {
      if (app.type == AppType.website) {
        // Find the BrowserInfo for the selected browser
        final selectedBrowser = _availableBrowsers.where(
          (b) => b.executable == _selectedBrowser
        ).firstOrNull;

        if (selectedBrowser == null) {
          _showBrowserError(['No browser configured']);
          return;
        }

        // For Firefox, check if an external instance is running (Firefox can't share profiles)
        // For Chrome/Chromium with profiles, skip the check - multiple instances can coexist
        if (selectedBrowser.name == 'Firefox') {
          if (await _isBrowserRunning(selectedBrowser.executable)) {
            _showBrowserError([selectedBrowser.name]);
            return;
          }
        }

        // Build args - always fullscreen
        final args = <String>[];
        args.add(selectedBrowser.fullscreenFlag);

        // Add user-data-dir for Chrome/Chromium profile isolation
        if (_currentProfile != null && selectedBrowser.name != 'Firefox') {
          final profilePath = ProfileManager.getBrowserProfilePath(_currentProfile!);
          args.add('--user-data-dir=$profilePath');
        }

        // Add LaunchTube extension for script injection (Chrome/Chromium only)
        if (selectedBrowser.name != 'Firefox') {
          final extensionPath = '${getAssetDirectory()}/extensions/launchtube';
          args.add('--load-extension=$extensionPath');
        }

        // Add remote debugging port for server-side extension detection
        const debugPort = 9222;
        args.add('--remote-debugging-port=$debugPort');

        // For Chrome/Chromium with our extension, go directly to target URL
        // For Firefox (no extension), use setup page
        if (selectedBrowser.name == 'Firefox') {
          final setupUrl = 'http://localhost:${_server.port}/setup?target=${Uri.encodeComponent(app.url!)}';
          args.add(setupUrl);
        } else {
          args.add(app.url!);
        }

        Log.write('Launching browser: ${selectedBrowser.executable} ${args.join(' ')}');
        _launchedBrowser = selectedBrowser;
        _browserProcess = await Process.start(selectedBrowser.executable, args);
        Log.write('Browser started with PID: ${_browserProcess!.pid}');

        // Tell screensaver inhibitor about the browser
        ScreensaverInhibitor.getInstance().setBrowser(selectedBrowser.name, debugPort);

        // Clear reference if process exits on its own
        _browserProcess!.exitCode.then((_) {
          Log.write('Browser process exited');
          _browserProcess = null;
          _launchedBrowser = null;
          ScreensaverInhibitor.getInstance().setBrowser(null, null);
        });
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

  Future<void> _closeBrowser() async {
    if (_browserProcess == null) {
      Log.write('No browser process to close');
      return;
    }

    final pid = _browserProcess!.pid;
    Log.write('Closing browser process PID: $pid');

    if (_launchedBrowser?.executable.endsWith('.exe') ?? false) {
      try {
        final result = await Process.run('taskkill.exe', ['/F', '/PID', pid.toString()]);
        Log.write('taskkill result: ${result.exitCode}');
      } catch (e) {
        Log.write('taskkill failed: $e');
      }
    } else {
      try {
        _browserProcess!.kill(ProcessSignal.sigterm);
      } catch (e) {
        Log.write('SIGTERM failed: $e');
      }
    }

    _browserProcess = null;
    _launchedBrowser = null;
    ScreensaverInhibitor.getInstance().setBrowser(null, null);
  }

  Future<void> _restartApp() async {
    await ExternalPlayer.getInstance().stop();
    await _closeBrowser();
    await Process.start(Platform.resolvedExecutable, [], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _quitApp() async {
    await ExternalPlayer.getInstance().stop();
    await _closeBrowser();
    exit(0);
  }

  void _openAdminBrowser(BrowserInfo browser) async {
    // Check if browser is already running
    if (_browserProcess != null) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Browser Running'),
          content: const Text('Please close the browser before opening admin mode.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // Check if this specific browser is already running
    if (await _isBrowserRunning(browser.executable)) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Browser Running'),
          content: Text('${browser.executable} is already running. Please close it first.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final selectedBrowser = browser;

    try {
      // Open in non-kiosk mode for admin access
      final args = <String>[];
      // Use --start-maximized for Chrome/Chromium admin mode, nothing for Firefox (no equivalent)
      if (selectedBrowser.name != 'Firefox') {
        args.add('--start-maximized');
        // Add user-data-dir for Chrome/Chromium profile isolation
        if (_currentProfile != null) {
          final profilePath = ProfileManager.getBrowserProfilePath(_currentProfile!);
          args.add('--user-data-dir=$profilePath');
        }
        // Add LaunchTube extension for script injection
        final extensionPath = '${getAssetDirectory()}/extensions/launchtube';
        args.add('--load-extension=$extensionPath');
      }
      args.add('--remote-debugging-port=9222');

      final setupUrl = 'http://localhost:${_server.port}/setup?target=';
      args.add(setupUrl);

      Log.write('Opening admin browser: ${selectedBrowser.executable} ${args.join(' ')}');
      _launchedBrowser = selectedBrowser;
      _browserProcess = await Process.start(selectedBrowser.executable, args);
      Log.write('Admin browser started with PID: ${_browserProcess!.pid}');

      // Tell screensaver inhibitor about the browser
      ScreensaverInhibitor.getInstance().setBrowser(selectedBrowser.name, 9222);

      _browserProcess!.exitCode.then((_) {
        Log.write('Admin browser process exited');
        _browserProcess = null;
        _launchedBrowser = null;
        ScreensaverInhibitor.getInstance().setBrowser(null, null);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to open admin browser: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // Ctrl+Shift+R to restart app
      if (HardwareKeyboard.instance.isControlPressed &&
          HardwareKeyboard.instance.isShiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyR) {
        _restartApp();
        return;
      }

      // Ctrl+Shift+Q to quit app
      if (HardwareKeyboard.instance.isControlPressed &&
          HardwareKeyboard.instance.isShiftPressed &&
          event.logicalKey == LogicalKeyboardKey.keyQ) {
        _quitApp();
        return;
      }

      // Handle user selection screen
      if (_showingUserSelection) {
        _handleUserSelectionKeyEvent(event);
        return;
      }

      // '=' key opens hamburger menu from anywhere
      if (event.character == '=') {
        _menuKey.currentState?.showButtonMenu();
        return;
      }

      // Handle menu selected state
      if (_menuSelected) {
        if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.escape) {
          setState(() {
            _menuSelected = false;
          });
          return;
        } else if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.select) {
          _menuKey.currentState?.showButtonMenu();
          return;
        }
        return; // Ignore other keys when menu is selected
      }

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

        // U key to switch user
        if (event.logicalKey == LogicalKeyboardKey.keyU && !_moveMode) {
          _showUserSelection();
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
          } else if (_selectedIndex == 0) {
            // At top-left, go to hamburger menu
            _menuSelected = true;
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
          } else if (_selectedIndex < columns) {
            // In top row, go to hamburger menu
            _menuSelected = true;
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
        } else if (event.logicalKey == LogicalKeyboardKey.delete) {
          // Delete selected app with confirmation
          if (!_moveMode && _selectedIndex < apps.length) {
            _showDeleteConfirmation(_selectedIndex);
          }
        } else if (event.character == '?') {
          _showHelpDialog();
        } else if (event.character == '+') {
          if (!_moveMode) {
            _showAddDialog();
          }
        }
      });
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.escape ||
               event.logicalKey == LogicalKeyboardKey.enter ||
               event.character == '?')) {
            Navigator.of(context).pop();
          }
        },
        child: AlertDialog(
          backgroundColor: const Color(0xFF2A2A4E),
          title: const Text('Keyboard Shortcuts', style: TextStyle(color: Colors.white)),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HelpRow(shortcut: 'Arrow Keys', description: 'Navigate'),
              _HelpRow(shortcut: 'Enter', description: 'Launch app'),
              _HelpRow(shortcut: '+', description: 'Add app'),
              _HelpRow(shortcut: 'C', description: 'Configure app'),
              _HelpRow(shortcut: 'M', description: 'Move app'),
              _HelpRow(shortcut: 'Delete', description: 'Delete app'),
              _HelpRow(shortcut: 'U', description: 'Switch user'),
              _HelpRow(shortcut: '=', description: 'Open menu'),
              _HelpRow(shortcut: 'Escape', description: 'Cancel'),
              _HelpRow(shortcut: 'Ctrl+Shift+R', description: 'Restart app'),
              _HelpRow(shortcut: 'Ctrl+Shift+Q', description: 'Quit app'),
              _HelpRow(shortcut: '?', description: 'Show this help'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(int index) {
    final app = apps[index];
    void doDelete() {
      Navigator.of(context).pop();
      setState(() {
        apps.removeAt(index);
        if (_selectedIndex >= apps.length) {
          _selectedIndex = apps.length > 0 ? apps.length - 1 : 0;
        }
      });
      _saveApps();
    }

    showDialog(
      context: context,
      builder: (context) => KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
               event.logicalKey == LogicalKeyboardKey.delete)) {
            doDelete();
          }
        },
        child: AlertDialog(
          backgroundColor: const Color(0xFF2A2A4E),
          title: const Text('Delete App', style: TextStyle(color: Colors.white)),
          content: Text(
            'Delete "${app.name}"?',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              onPressed: doDelete,
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddDialog() {
    showDialog(
      context: context,
      builder: (context) => ServicePickerDialog(
        installedApps: apps,
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

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('About Launch Tube', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Launch Tube',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'A media launcher for streaming services.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Text(
              'Version: $appVersion',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              'Build: $buildDate',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              'Commit: $gitCommit',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 16),
            const Text(
              'By James Vasile',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) => SettingsDialog(
        availableBrowsers: _availableBrowsers,
        selectedBrowser: _selectedBrowser,
        availableMpv: _availableMpv,
        selectedMpv: _selectedMpv,
        mpvOptions: _mpvOptions,
        onBrowserChanged: (value) {
          setState(() {
            _selectedBrowser = value;
          });
          _saveSelectedBrowser();
        },
        onMpvChanged: (value) {
          setState(() {
            _selectedMpv = value;
          });
          _saveSelectedMpv();
        },
        onMpvOptionsChanged: (value) {
          setState(() {
            _mpvOptions = value;
          });
          _saveMpvOptions();
        },
      ),
    );
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
          child: _showingUserSelection
              ? _buildUserSelectionScreen()
              : Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Stack(
                alignment: Alignment.center,
                children: [
                  Center(child: Image.file(File('${getAssetDirectory()}/images/launch-tube-logo/logo_wide.png'), height: 100)),
                  Positioned(
                    left: 20,
                    child: PopupMenuButton<String>(
                      key: _menuKey,
                      icon: Icon(Icons.menu, color: _menuSelected ? Colors.white : Colors.white54),
                      tooltip: 'Menu (=)',
                      color: const Color(0xFF2A2A4E),
                      initialValue: 'settings',
                      onCanceled: () {
                        setState(() {
                          _menuSelected = false;
                        });
                      },
                      onSelected: (value) {
                        setState(() {
                          _menuSelected = false;
                        });
                        if (value.startsWith('admin_browser:')) {
                          final index = int.parse(value.substring('admin_browser:'.length));
                          if (index < _availableBrowsers.length) {
                            _openAdminBrowser(_availableBrowsers[index]);
                          }
                          return;
                        }
                        switch (value) {
                          case 'settings':
                            _showSettingsDialog();
                            break;
                          case 'switch_user':
                            _showUserSelection();
                            break;
                          case 'about':
                            _showAboutDialog();
                            break;
                          case 'exit':
                            exit(0);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 'settings',
                          child: Row(
                            children: [
                              Icon(Icons.settings, color: Colors.white70),
                              SizedBox(width: 12),
                              Text('Settings'),
                            ],
                          ),
                        ),
                        // Dynamic browser admin items
                        for (var i = 0; i < _availableBrowsers.length; i++)
                          PopupMenuItem(
                            value: 'admin_browser:$i',
                            child: Row(
                              children: [
                                const Icon(Icons.admin_panel_settings, color: Colors.white70),
                                const SizedBox(width: 12),
                                Text('Administer ${_availableBrowsers[i].executable}'),
                              ],
                            ),
                          ),
                        const PopupMenuDivider(),
                        // User management
                        const PopupMenuItem(
                          value: 'switch_user',
                          child: Row(
                            children: [
                              Icon(Icons.switch_account, color: Colors.white70),
                              SizedBox(width: 12),
                              Text('Switch User'),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: 'about',
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, color: Colors.white70),
                              SizedBox(width: 12),
                              Text('About'),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'exit',
                          child: Row(
                            children: [
                              Icon(Icons.exit_to_app, color: Colors.white70),
                              SizedBox(width: 12),
                              Text('Exit'),
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
                                  return Draggable<int>(
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

class SettingsDialog extends StatefulWidget {
  final List<BrowserInfo> availableBrowsers;
  final String? selectedBrowser;
  final List<String> availableMpv;
  final String? selectedMpv;
  final String mpvOptions;
  final Function(String?) onBrowserChanged;
  final Function(String?) onMpvChanged;
  final Function(String) onMpvOptionsChanged;

  const SettingsDialog({
    super.key,
    required this.availableBrowsers,
    required this.selectedBrowser,
    required this.availableMpv,
    required this.selectedMpv,
    required this.mpvOptions,
    required this.onBrowserChanged,
    required this.onMpvChanged,
    required this.onMpvOptionsChanged,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String? _selectedBrowser;
  late String? _selectedMpv;
  late TextEditingController _mpvCustomController;
  late TextEditingController _mpvOptionsController;
  bool _useCustomMpv = false;

  @override
  void initState() {
    super.initState();
    _selectedBrowser = widget.selectedBrowser;
    _selectedMpv = widget.selectedMpv;
    // Check if current mpv is custom (not in available list)
    _useCustomMpv = widget.selectedMpv != null &&
        !widget.availableMpv.contains(widget.selectedMpv);
    _mpvCustomController = TextEditingController(
      text: _useCustomMpv ? widget.selectedMpv : '',
    );
    _mpvOptionsController = TextEditingController(
      text: widget.mpvOptions,
    );
  }

  @override
  void dispose() {
    _mpvCustomController.dispose();
    _mpvOptionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('Settings', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Browser section
              const Text(
                'Browser',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (widget.availableBrowsers.isEmpty)
                const Text(
                  'No browsers found',
                  style: TextStyle(color: Colors.white70),
                )
              else
                ...widget.availableBrowsers.map((browser) {
                  return RadioListTile<String>(
                    title: Text(
                      '${browser.name} (${browser.executable})',
                      style: const TextStyle(color: Colors.white),
                    ),
                    value: browser.executable,
                    groupValue: _selectedBrowser,
                    activeColor: Colors.blue,
                    onChanged: (value) {
                      setState(() => _selectedBrowser = value);
                      widget.onBrowserChanged(value);
                    },
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  );
                }),

              const SizedBox(height: 24),

              // Mpv section
              const Text(
                'Video Player (mpv)',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (widget.availableMpv.isEmpty && !_useCustomMpv)
                const Text(
                  'No mpv found on PATH',
                  style: TextStyle(color: Colors.white70),
                )
              else
                ...widget.availableMpv.map((mpv) {
                  return RadioListTile<String>(
                    title: Text(
                      mpv,
                      style: const TextStyle(color: Colors.white),
                    ),
                    value: mpv,
                    groupValue: _useCustomMpv ? null : _selectedMpv,
                    activeColor: Colors.blue,
                    onChanged: (value) {
                      setState(() {
                        _useCustomMpv = false;
                        _selectedMpv = value;
                      });
                      widget.onMpvChanged(value);
                    },
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  );
                }),

              RadioListTile<bool>(
                title: const Text(
                  'Custom path',
                  style: TextStyle(color: Colors.white),
                ),
                value: true,
                groupValue: _useCustomMpv,
                activeColor: Colors.blue,
                onChanged: (value) {
                  setState(() => _useCustomMpv = true);
                },
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),

              if (_useCustomMpv)
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                  child: TextField(
                    controller: _mpvCustomController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: '/path/to/mpv',
                      hintStyle: TextStyle(color: Colors.white38),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.white38),
                      ),
                      focusedBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Colors.blue),
                      ),
                    ),
                    onChanged: (value) {
                      setState(() => _selectedMpv = value);
                      widget.onMpvChanged(value);
                    },
                  ),
                ),

              const SizedBox(height: 16),

              // Mpv options section
              const Text(
                'MPV Options',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Additional command-line options for mpv:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _mpvOptionsController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '--hwdec=auto --volume=80',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white38),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.blue),
                  ),
                ),
                onChanged: (value) {
                  widget.onMpvOptionsChanged(value);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
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
  late TextEditingController _matchUrlsController;
  late TextEditingController _commandLineController;
  late TextEditingController _imagePathController;
  late AppType _type;
  late bool _showName;
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.app.name);
    _urlController = TextEditingController(text: widget.app.url ?? '');
    _matchUrlsController = TextEditingController(text: widget.app.matchUrls?.join('\n') ?? '');
    _commandLineController = TextEditingController(text: widget.app.commandLine ?? '');
    _imagePathController = TextEditingController(text: widget.app.imagePath ?? '');
    _type = widget.app.type;
    _showName = widget.app.showName;
    _selectedColor = Color(widget.app.colorValue);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _matchUrlsController.dispose();
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
    // Parse matchUrls from newline-separated text, filter empty lines
    final matchUrlsList = _matchUrlsController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    widget.app.matchUrls = _type == AppType.website && matchUrlsList.isNotEmpty ? matchUrlsList : null;
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
                const SizedBox(height: 16),
                TextField(
                  controller: _matchUrlsController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Additional pages to run JavaScript on',
                    hintText: 'URL prefixes, one per line',
                    border: OutlineInputBorder(),
                  ),
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
  final List<AppConfig> installedApps;

  const ServicePickerDialog({
    super.key,
    required this.onCustom,
    required this.onSelectService,
    required this.installedApps,
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
    // Filter out services that are already installed with identical settings
    final filteredServices = services.where((service) {
      final templateApp = service.toAppConfig();
      return !widget.installedApps.any((installed) =>
        installed.name == templateApp.name &&
        installed.url == templateApp.url &&
        installed.colorValue == templateApp.colorValue &&
        _listEquals(installed.matchUrls, templateApp.matchUrls)
      );
    }).toList();
    if (mounted) {
      setState(() {
        _services = filteredServices;
        _isLoading = false;
      });
    }
  }

  bool _listEquals(List<String>? a, List<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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

class _HelpRow extends StatelessWidget {
  final String shortcut;
  final String description;

  const _HelpRow({required this.shortcut, required this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              shortcut,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            description,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatefulWidget {
  final UserProfile profile;
  final bool isSelected;
  final bool isMoving;
  final bool isDropTarget;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  final VoidCallback onEdit;

  const _UserTile({
    required this.profile,
    required this.isSelected,
    this.isMoving = false,
    this.isDropTarget = false,
    required this.onTap,
    required this.onHover,
    required this.onEdit,
  });

  @override
  State<_UserTile> createState() => _UserTileState();
}

class _UserTileState extends State<_UserTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final circleSize = constraints.maxWidth * 0.75;
            final fontSize = circleSize * 0.4;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              transform: Matrix4.identity()..scale(widget.isSelected ? 1.1 : 1.0),
              transformAlignment: Alignment.center,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: circleSize,
                          height: circleSize,
                          decoration: BoxDecoration(
                            color: widget.profile.hasPhoto
                                ? (widget.isMoving ? Colors.black38 : null)
                                : (widget.isMoving ? widget.profile.color.withOpacity(0.5) : widget.profile.color),
                            shape: BoxShape.circle,
                            border: widget.isMoving
                                ? Border.all(color: Colors.orangeAccent, width: 4)
                                : widget.isDropTarget
                                    ? Border.all(color: Colors.greenAccent, width: 4)
                                    : widget.isSelected
                                        ? Border.all(color: Colors.white, width: 4)
                                        : Border.all(color: Colors.white38, width: 2),
                            boxShadow: widget.isMoving
                                ? [
                                    BoxShadow(
                                      color: Colors.orangeAccent.withOpacity(0.5),
                                      blurRadius: 20,
                                      spreadRadius: 5,
                                    ),
                                  ]
                                : widget.isSelected
                                    ? [
                                        BoxShadow(
                                          color: (widget.profile.hasPhoto ? Colors.white : widget.profile.color).withOpacity(0.5),
                                          blurRadius: 20,
                                          spreadRadius: 5,
                                        ),
                                      ]
                                    : null,
                          ),
                          child: widget.profile.hasPhoto
                              ? ClipOval(
                                  child: Image.file(
                                    File('${getAssetDirectory()}/images/profile-photos/${widget.profile.photoPath}'),
                                    fit: BoxFit.cover,
                                    width: circleSize,
                                    height: circleSize,
                                  ),
                                )
                              : Center(
                                  child: Text(
                                    widget.profile.displayName.isNotEmpty
                                        ? widget.profile.displayName[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      fontSize: fontSize,
                                      fontWeight: FontWeight.bold,
                                      color: widget.profile.color.computeLuminance() > 0.5
                                          ? Colors.black
                                          : Colors.white,
                                    ),
                                  ),
                                ),
                        ),
                        // Gear icon for editing - positioned at top-right of circle
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
                                icon: const Icon(Icons.settings, color: Colors.white, size: 20),
                                onPressed: widget.onEdit,
                                tooltip: 'Edit',
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.profile.displayName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AddUserTile extends StatelessWidget {
  final bool isSelected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  const _AddUserTile({
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final circleSize = constraints.maxWidth * 0.75;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              transform: Matrix4.identity()..scale(isSelected ? 1.1 : 1.0),
              transformAlignment: Alignment.center,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: circleSize,
                      height: circleSize,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(isSelected ? 0.2 : 0.1),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected ? Colors.white : Colors.white38,
                          width: isSelected ? 4 : 2,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Colors.white.withOpacity(0.3),
                                  blurRadius: 20,
                                  spreadRadius: 5,
                                ),
                              ]
                            : null,
                      ),
                      child: Icon(
                        Icons.add,
                        size: circleSize * 0.4,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Add User',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  final bool isNewUser;
  final String? initialName;
  final int? initialColorValue;
  final String? initialPhotoPath;
  final List<String> availablePhotos;
  final bool canDelete;
  final Future<void> Function(String name, int colorValue, String? photoPath) onSave;
  final Future<void> Function()? onDelete;

  const _UserDialog({
    required this.isNewUser,
    this.initialName,
    this.initialColorValue,
    this.initialPhotoPath,
    required this.availablePhotos,
    this.canDelete = false,
    required this.onSave,
    this.onDelete,
  });

  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final TextEditingController _nameController;
  final _focusNode = FocusNode();
  final _textFieldFocusNode = FocusNode();

  String? _selectedPhoto; // null means use color
  late int _selectedColorIndex;
  int _focusedElement = 0; // 0=name, 1=photo circle, 2=color circle, 3+=buttons
  late bool _isTextFieldFocused;

  // Element indices
  static const int _photoCircleIndex = 1;
  static const int _colorCircleIndex = 2;
  int get _deleteIndex => widget.canDelete ? 3 : -1;
  int get _cancelIndex => widget.canDelete ? 4 : 3;
  int get _saveIndex => widget.canDelete ? 5 : 4;

  String get _title => widget.isNewUser ? 'Add User' : 'Configure User';
  String get _saveButtonLabel => widget.isNewUser ? 'Add' : 'Save';

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _selectedPhoto = widget.initialPhotoPath;

    if (widget.initialColorValue != null) {
      _selectedColorIndex = availableColors.indexWhere(
        (c) => c.value == widget.initialColorValue,
      );
      if (_selectedColorIndex < 0) _selectedColorIndex = 0;
    } else {
      _selectedColorIndex = Random().nextInt(availableColors.length);
    }

    _isTextFieldFocused = widget.isNewUser;
    _textFieldFocusNode.addListener(_onTextFieldFocusChange);

    if (widget.isNewUser) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _textFieldFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _focusNode.dispose();
    _textFieldFocusNode.removeListener(_onTextFieldFocusChange);
    _textFieldFocusNode.dispose();
    super.dispose();
  }

  void _onTextFieldFocusChange() {
    setState(() {
      _isTextFieldFocused = _textFieldFocusNode.hasFocus;
      if (_isTextFieldFocused) _focusedElement = 0;
    });
  }

  void _doSave() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context);
    widget.onSave(name, availableColors[_selectedColorIndex].value, _selectedPhoto);
  }

  void _doDelete() async {
    if (widget.onDelete == null) return;
    Navigator.pop(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A4E),
        title: const Text('Delete User', style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "${widget.initialName}" and all their data?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onDelete!();
  }

  void _openPhotoPicker() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _PhotoPickerDialog(
        availablePhotos: widget.availablePhotos,
        selectedPhoto: _selectedPhoto,
      ),
    );
    if (selected != null) {
      setState(() => _selectedPhoto = selected);
    }
  }

  void _openColorPicker() async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => _ColorPickerDialog(
        selectedColorIndex: _selectedColorIndex,
      ),
    );
    if (selected != null) {
      setState(() {
        _selectedColorIndex = selected;
        _selectedPhoto = null; // Clear photo when color is picked
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (_isTextFieldFocused) {
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _isTextFieldFocused = false;
          _focusedElement = widget.availablePhotos.isNotEmpty ? _photoCircleIndex : _colorCircleIndex;
          _textFieldFocusNode.unfocus();
        });
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
      }
      return;
    }

    setState(() {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
        return;
      }

      if (event.logicalKey == LogicalKeyboardKey.enter) {
        if (_focusedElement == 0) {
          _isTextFieldFocused = true;
          _textFieldFocusNode.requestFocus();
        } else if (_focusedElement == _photoCircleIndex) {
          _openPhotoPicker();
        } else if (_focusedElement == _colorCircleIndex) {
          _openColorPicker();
        } else if (_focusedElement == _deleteIndex) {
          _doDelete();
        } else if (_focusedElement == _cancelIndex) {
          Navigator.pop(context);
        } else if (_focusedElement == _saveIndex) {
          _doSave();
        }
        return;
      }

      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_focusedElement == _photoCircleIndex) {
          _focusedElement = _colorCircleIndex;
        } else if (_focusedElement == _deleteIndex) {
          _focusedElement = _cancelIndex;
        } else if (_focusedElement == _cancelIndex) {
          _focusedElement = _saveIndex;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (_focusedElement == _colorCircleIndex && widget.availablePhotos.isNotEmpty) {
          _focusedElement = _photoCircleIndex;
        } else if (_focusedElement == _saveIndex) {
          _focusedElement = _cancelIndex;
        } else if (_focusedElement == _cancelIndex && widget.canDelete) {
          _focusedElement = _deleteIndex;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (_focusedElement == 0) {
          _focusedElement = widget.availablePhotos.isNotEmpty ? _photoCircleIndex : _colorCircleIndex;
        } else if (_focusedElement == _photoCircleIndex || _focusedElement == _colorCircleIndex) {
          _focusedElement = _saveIndex;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_focusedElement == _photoCircleIndex || _focusedElement == _colorCircleIndex) {
          _focusedElement = 0;
        } else if (_focusedElement >= _deleteIndex) {
          _focusedElement = _colorCircleIndex;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedColor = availableColors[_selectedColorIndex];

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: const Color(0xFF2A2A4E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 24),
              // Name field
              GestureDetector(
                onTap: () {
                  setState(() {
                    _focusedElement = 0;
                    _isTextFieldFocused = true;
                    _textFieldFocusNode.requestFocus();
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: (_focusedElement == 0 || _isTextFieldFocused) ? Border.all(color: Colors.blue, width: 2) : null,
                  ),
                  child: TextField(
                    controller: _nameController,
                    focusNode: _textFieldFocusNode,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              // Photo and Color circles
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.availablePhotos.isNotEmpty) ...[
                    _AvatarPickerCircle(
                      label: 'Photo',
                      isFocused: _focusedElement == _photoCircleIndex,
                      isActive: _selectedPhoto != null,
                      onTap: _openPhotoPicker,
                      child: _selectedPhoto != null
                          ? ClipOval(
                              child: Image.file(
                                File('${getAssetDirectory()}/images/profile-photos/$_selectedPhoto'),
                                fit: BoxFit.cover,
                                width: 80,
                                height: 80,
                              ),
                            )
                          : const Icon(Icons.photo, color: Colors.white54, size: 32),
                    ),
                    const SizedBox(width: 32),
                  ],
                  _AvatarPickerCircle(
                    label: 'Color',
                    isFocused: _focusedElement == _colorCircleIndex,
                    isActive: _selectedPhoto == null,
                    onTap: _openColorPicker,
                    backgroundColor: selectedColor,
                    child: Text(
                      _nameController.text.isNotEmpty ? _nameController.text[0].toUpperCase() : '?',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: selectedColor.computeLuminance() > 0.5 ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              // Buttons
              Row(
                children: [
                  if (widget.canDelete)
                    _DialogButton(label: 'Delete', isFocused: _focusedElement == _deleteIndex, isDanger: true, onTap: _doDelete),
                  const Spacer(),
                  _DialogButton(label: 'Cancel', isFocused: _focusedElement == _cancelIndex, onTap: () => Navigator.pop(context)),
                  const SizedBox(width: 16),
                  _DialogButton(label: _saveButtonLabel, isFocused: _focusedElement == _saveIndex, isPrimary: true, onTap: _doSave),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Circle widget for photo/color picker in user dialog
class _AvatarPickerCircle extends StatelessWidget {
  final String label;
  final bool isFocused;
  final bool isActive;
  final VoidCallback onTap;
  final Color? backgroundColor;
  final Widget child;

  const _AvatarPickerCircle({
    required this.label,
    required this.isFocused,
    required this.isActive,
    required this.onTap,
    this.backgroundColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: backgroundColor ?? Colors.white12,
              shape: BoxShape.circle,
              border: isFocused
                  ? Border.all(color: Colors.blue, width: 3)
                  : isActive
                      ? Border.all(color: Colors.white, width: 3)
                      : Border.all(color: Colors.white24, width: 2),
              boxShadow: isFocused ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 8)] : null,
            ),
            child: Center(child: child),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: TextStyle(color: isActive ? Colors.white : Colors.white54)),
              if (isActive) ...[
                const SizedBox(width: 4),
                const Icon(Icons.check, color: Colors.green, size: 16),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// Photo picker modal
class _PhotoPickerDialog extends StatefulWidget {
  final List<String> availablePhotos;
  final String? selectedPhoto;

  const _PhotoPickerDialog({required this.availablePhotos, this.selectedPhoto});

  @override
  State<_PhotoPickerDialog> createState() => _PhotoPickerDialogState();
}

class _PhotoPickerDialogState extends State<_PhotoPickerDialog> {
  static const _itemsPerRow = 4;
  static const _itemSize = 80.0;
  static const _itemSpacing = 16.0;

  final _focusNode = FocusNode();
  final _scrollController = ScrollController();
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedPhoto != null
        ? widget.availablePhotos.indexOf(widget.selectedPhoto!)
        : 0;
    if (_selectedIndex < 0) _selectedIndex = 0;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;

    // Calculate actual cell size from grid (container width - padding - spacing) / columns
    // Container: 500px, padding: 48px (24*2), spacing: 48px (16*3 gaps)
    const containerContentWidth = 500.0 - 48.0;
    const actualCellSize = (containerContentWidth - (_itemsPerRow - 1) * _itemSpacing) / _itemsPerRow;
    final rowHeight = actualCellSize + _itemSpacing;

    final row = _selectedIndex ~/ _itemsPerRow;
    final targetOffset = row * rowHeight;

    // Get visible range
    final viewportHeight = _scrollController.position.viewportDimension;
    final currentOffset = _scrollController.offset;
    final maxOffset = _scrollController.position.maxScrollExtent;

    // Scroll if selected item is outside visible area
    if (targetOffset < currentOffset) {
      _scrollController.animateTo(targetOffset, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    } else if (targetOffset + actualCellSize > currentOffset + viewportHeight) {
      final scrollTo = (targetOffset + actualCellSize - viewportHeight + _itemSpacing).clamp(0.0, maxOffset);
      _scrollController.animateTo(scrollTo, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    int newIndex = _selectedIndex;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return;
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      Navigator.pop(context, widget.availablePhotos[_selectedIndex]);
      return;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_selectedIndex < widget.availablePhotos.length - 1) newIndex++;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (_selectedIndex > 0) newIndex--;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_selectedIndex + _itemsPerRow < widget.availablePhotos.length) {
        newIndex += _itemsPerRow;
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_selectedIndex - _itemsPerRow >= 0) {
        newIndex -= _itemsPerRow;
      }
    }

    if (newIndex != _selectedIndex) {
      setState(() => _selectedIndex = newIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: const Color(0xFF2A2A4E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 500,
          constraints: const BoxConstraints(maxHeight: 500),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose Photo', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 24),
              Flexible(
                child: GridView.builder(
                  controller: _scrollController,
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _itemsPerRow,
                    crossAxisSpacing: _itemSpacing,
                    mainAxisSpacing: _itemSpacing,
                  ),
                  itemCount: widget.availablePhotos.length,
                  itemBuilder: (context, index) {
                    final photoPath = widget.availablePhotos[index];
                    final isSelected = _selectedIndex == index;
                    return GestureDetector(
                      onTap: () => Navigator.pop(context, photoPath),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(color: Colors.blue, width: 3)
                              : Border.all(color: Colors.white24, width: 2),
                          boxShadow: isSelected ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 8)] : null,
                        ),
                        child: ClipOval(
                          child: Image.file(
                            File('${getAssetDirectory()}/images/profile-photos/$photoPath'),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
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

// Color picker modal
class _ColorPickerDialog extends StatefulWidget {
  final int selectedColorIndex;

  const _ColorPickerDialog({required this.selectedColorIndex});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  final _focusNode = FocusNode();
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.selectedColorIndex;
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    const itemsPerRow = 7;

    setState(() {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        Navigator.pop(context);
      } else if (event.logicalKey == LogicalKeyboardKey.enter) {
        Navigator.pop(context, _selectedIndex);
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (_selectedIndex < availableColors.length - 1) _selectedIndex++;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (_selectedIndex > 0) _selectedIndex--;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        if (_selectedIndex + itemsPerRow < availableColors.length) {
          _selectedIndex += itemsPerRow;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_selectedIndex - itemsPerRow >= 0) {
          _selectedIndex -= itemsPerRow;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Dialog(
        backgroundColor: const Color(0xFF2A2A4E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose Color', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: List.generate(availableColors.length, (index) {
                  final color = availableColors[index];
                  final isSelected = _selectedIndex == index;
                  return GestureDetector(
                    onTap: () => Navigator.pop(context, index),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: Colors.blue, width: 3)
                            : Border.all(color: Colors.white24, width: 2),
                        boxShadow: isSelected ? [BoxShadow(color: Colors.blue.withOpacity(0.5), blurRadius: 8)] : null,
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogButton extends StatelessWidget {
  final String label;
  final bool isFocused;
  final bool isPrimary;
  final bool isDanger;
  final VoidCallback onTap;

  const _DialogButton({
    required this.label,
    required this.isFocused,
    this.isPrimary = false,
    this.isDanger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: isPrimary ? Colors.blue : (isDanger ? Colors.red.withOpacity(0.2) : Colors.transparent),
          borderRadius: BorderRadius.circular(4),
          border: isFocused
              ? Border.all(color: Colors.white, width: 2)
              : isDanger
                  ? Border.all(color: Colors.red.withOpacity(0.5), width: 1)
                  : isPrimary
                      ? null
                      : Border.all(color: Colors.white38, width: 1),
          boxShadow: isFocused
              ? [BoxShadow(color: Colors.white.withOpacity(0.3), blurRadius: 8)]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isDanger ? Colors.red : Colors.white,
            fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

