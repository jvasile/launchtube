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

  // Browser selection
  List<BrowserInfo> _availableBrowsers = [];
  String? _selectedBrowser; // executable name

  // Mpv selection
  List<String> _availableMpv = [];
  String? _selectedMpv; // executable path or name

  // Track launched browser process for closing
  Process? _browserProcess;
  BrowserInfo? _launchedBrowser;

  @override
  void initState() {
    super.initState();
    _enterFullscreen();
    _loadApps();
    _detectBrowsers();
    _detectMpv();
    _server.setAppsProvider(() => apps);
    _server.setCloseBrowserCallback(_closeBrowser);
    _server.start();
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

  Future<String> get _browserConfigPath async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/browser.txt';
  }

  Future<String?> _loadSelectedBrowser() async {
    try {
      final path = await _browserConfigPath;
      final file = File(path);
      if (await file.exists()) {
        return (await file.readAsString()).trim();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveSelectedBrowser() async {
    if (_selectedBrowser == null) return;
    try {
      final path = await _browserConfigPath;
      await File(path).writeAsString(_selectedBrowser!);
    } catch (_) {}
  }

  Future<void> _detectMpv() async {
    final mpvList = await detectMpvExecutables();
    final savedMpv = await _loadSelectedMpv();
    setState(() {
      _availableMpv = mpvList;
      // Use saved mpv if set, otherwise first detected
      if (savedMpv != null && savedMpv.isNotEmpty) {
        _selectedMpv = savedMpv;
      } else if (mpvList.isNotEmpty) {
        _selectedMpv = mpvList.first;
      }
    });
    // Update the ExternalPlayer with the selected mpv
    if (_selectedMpv != null) {
      ExternalPlayer.getInstance().setMpvPath(_selectedMpv!);
    }
  }

  Future<String> get _mpvConfigPath async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/mpv.txt';
  }

  Future<String?> _loadSelectedMpv() async {
    try {
      final path = await _mpvConfigPath;
      final file = File(path);
      if (await file.exists()) {
        return (await file.readAsString()).trim();
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveSelectedMpv() async {
    if (_selectedMpv == null) return;
    try {
      final path = await _mpvConfigPath;
      await File(path).writeAsString(_selectedMpv!);
    } catch (_) {}
    // Update the ExternalPlayer with the new mpv path
    ExternalPlayer.getInstance().setMpvPath(_selectedMpv!);
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
        // Find a browser that isn't already running
        BrowserInfo? selectedBrowser;
        List<String> runningBrowsers = [];
        Set<String> seenNames = {};

        for (final browser in _availableBrowsers) {
          if (await _isBrowserRunning(browser.executable)) {
            if (!seenNames.contains(browser.name)) {
              runningBrowsers.add(browser.name);
              seenNames.add(browser.name);
            }
          } else if (selectedBrowser == null) {
            selectedBrowser = browser;
          }
        }

        if (selectedBrowser == null) {
          _showBrowserError(runningBrowsers);
          return;
        }

        if (runningBrowsers.isNotEmpty) {
          _showBrowserWarning(runningBrowsers, selectedBrowser.name);
        }

        // Build args - simple, no profile hacks
        final args = <String>[];
        if (app.kioskMode) {
          args.add(selectedBrowser.fullscreenFlag);
        }

        // Add remote debugging port for server-side extension detection
        const debugPort = 9222;
        args.add('--remote-debugging-port=$debugPort');

        // Start with setup page that checks for userscript manager, then redirects to target
        final setupUrl = 'http://localhost:${_server.port}/setup?target=${Uri.encodeComponent(app.url!)}';
        args.add(setupUrl);

        Log.write('Launching browser: ${selectedBrowser.executable} ${args.join(' ')}');
        _launchedBrowser = selectedBrowser;
        _browserProcess = await Process.start(selectedBrowser.executable, args);
        Log.write('Browser started with PID: ${_browserProcess!.pid}');

        // Clear reference if process exits on its own
        _browserProcess!.exitCode.then((_) {
          Log.write('Browser process exited');
          _browserProcess = null;
          _launchedBrowser = null;
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
          child: Column(
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
                      icon: const Icon(Icons.menu, color: Colors.white54),
                      tooltip: 'Menu',
                      color: const Color(0xFF2A2A4E),
                      onSelected: (value) {
                        switch (value) {
                          case 'settings':
                            _showSettingsDialog();
                            break;
                          case 'install_userscript':
                            _server.openUserscriptInstall();
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

class SettingsDialog extends StatefulWidget {
  final List<BrowserInfo> availableBrowsers;
  final String? selectedBrowser;
  final List<String> availableMpv;
  final String? selectedMpv;
  final Function(String?) onBrowserChanged;
  final Function(String?) onMpvChanged;

  const SettingsDialog({
    super.key,
    required this.availableBrowsers,
    required this.selectedBrowser,
    required this.availableMpv,
    required this.selectedMpv,
    required this.onBrowserChanged,
    required this.onMpvChanged,
  });

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String? _selectedBrowser;
  late String? _selectedMpv;
  late TextEditingController _mpvCustomController;
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
  }

  @override
  void dispose() {
    _mpvCustomController.dispose();
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
