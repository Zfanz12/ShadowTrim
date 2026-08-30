import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_window_close/flutter_window_close.dart';
import '../models/clip_model.dart';
import '../services/video_service.dart';
import '../services/logger_service.dart';
import '../services/native_core_bridge.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  // Tabs
  bool _isFolderMode = false;
  bool _deleteOriginalAfterTrim = false;
  bool _viewingTrimmedMode = false;
  final Set<String> _blacklistedClipNames = {};
  final Set<String> _originalClipsToDelete = {};
  List<VideoClip> _deletedClips = [];
  bool _deletedExpanded = true;
  String? _lastSessionWorkspacePath;
  bool _isShowingExitDialog = false;
  bool _isExiting = false;
  bool _isEndingSession = false;
  String _endingSessionStatus = '';
  int _totalDeletingFiles = 0;
  int _currentDeletedCount = 0;
  String _currentDeletingFileName = '';
  bool _isImporting = false;

  // State
  List<VideoClip> _clips = [];
  int _selectedClipIndex = -1;

  // Media Player
  late final Player _player;
  late final VideoController _controller;
  Duration _currentPosition = Duration.zero;
  late final FocusNode _focusNode;
  late final FocusNode _exportNameFocusNode;

  // Export Settings
  final TextEditingController _exportNameController = TextEditingController();
  bool _preserveMetadata = true;
  bool _isExporting = false;
  String _exportStatus = '';
  String? _customExportDir;
  bool _autoCreateTrimmedFolder = true;
  String? _currentWorkspacePath;

  bool _isDragging = false;
  bool _untrimmedExpanded = true;
  bool _trimmedExpanded = true;
  bool _isMetadataExpanded = true;
  bool _isShortcutsExpanded = false;
  bool _isPlayerBuffering = false;
  bool _isClipLoading = false;
  String _importProgressStatus = '';
  String? _currentlyLoadedMediaUrl;
  int _selectClipToken = 0;
  String _sortBy = 'created_desc'; // 'created_desc', 'created_asc'
  double _volume = 100.0;
  double _lastVolume = 100.0;
  double _playbackSpeed = 1.0;
  double? _draggingPositionMs;
  DateTime? _lastSeekTime;
  final Map<VideoClip, GlobalKey> _clipKeys = {};
  final Set<String> _probingPaths = {};

  // P2-2: Store player stream subscriptions for clean disposal
  final List<StreamSubscription> _playerSubscriptions = [];

  // Toast Notification State
  String? _toastMessage;
  bool _isToastError = false;
  bool _isToastDelete = false;
  late final AnimationController _toastAnimController;
  late final Animation<Offset> _toastSlideAnim;
  late final Animation<double> _toastFadeAnim;
  Timer? _toastDismissTimer;

  int _getFirstUntrimmedIndex() {
    final untrimmedIndex = _clips.indexWhere((c) => !c.isTrimmed);
    if (untrimmedIndex != -1) return untrimmedIndex;
    return _clips.isNotEmpty ? 0 : -1;
  }

  void _probeClipMetadata(VideoClip clip) {
    final targetPath = (clip.isTrimmed && clip.trimmedOutputPath != null)
        ? clip.trimmedOutputPath!
        : clip.filePath;
    if (_probingPaths.contains(targetPath)) return;
    _probingPaths.add(targetPath);

    VideoTrimmer.probeVideoMetadata(targetPath).then((meta) {
      _probingPaths.remove(targetPath);
      if (!mounted) return;
      final Duration? dur = meta['duration'] as Duration?;
      setState(() {
        if (dur != null && dur > Duration.zero && clip.duration == Duration.zero) {
          clip.duration = dur;
          if (clip.endCut == Duration.zero) {
            clip.endCut = dur;
          }
        }
        clip.resolution = meta['resolution'] as String? ?? clip.resolution;
        clip.fps = meta['fps'] as int? ?? clip.fps;
        clip.bitrate = meta['bitrate'] as String? ?? clip.bitrate;
        // Auto-cap speed to 2.0x max if video is high FPS (> 60fps) to prevent lag
        if (_selectedClipIndex >= 0 && _selectedClipIndex < _clips.length && _clips[_selectedClipIndex] == clip) {
          if (clip.fps != null && clip.fps! > 60 && _playbackSpeed > 2.0) {
            _playbackSpeed = 2.0;
            _player.setRate(2.0);
          }
        }
      });
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode();
    _exportNameFocusNode = FocusNode();
    _initPlayer();

    // Toast Notification Animation Setup
    _toastAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 250),
    );

    _toastSlideAnim = Tween<Offset>(
      begin: const Offset(0.0, 0.7),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _toastAnimController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ));

    _toastFadeAnim = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _toastAnimController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    ));

    // Load last session pointer so we can show "Continue" button
    _loadLastSessionPointer();

    // Intercept native close window clicks on desktop
    FlutterWindowClose.setWindowShouldCloseHandler(() async {
      final response = await didRequestAppExit();
      return response == AppExitResponse.exit;
    });
  }

  /// Initialize a fresh Player instance with all stream listeners and mpv properties.
  void _initPlayer() {
    // 128MB buffer for smooth 3x playback on high-bitrate Shadowplay recordings
    _player = Player(configuration: const PlayerConfiguration(bufferSize: 128 * 1024 * 1024));
    _controller = VideoController(_player);

    try {
      final platform = _player.platform as dynamic;
      platform.setProperty('hwdec', 'auto-safe');
      platform.setProperty('vd-lavc-dr', 'no');
    } catch (e) {
      debugPrint('mpv property configuration note: $e');
    }

    // P2-2: Store subscriptions so they can be cancelled in dispose()
    _playerSubscriptions.add(
      _player.stream.error.listen((err) {
        LoggerService.logError('MediaKit Player Stream Error: $err');
      }),
    );

    _playerSubscriptions.add(
      _player.stream.volume.listen((vol) {
        if (mounted) {
          setState(() {
            _volume = vol;
          });
        }
      }),
    );

    _playerSubscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (mounted) {
          setState(() {
            _isPlayerBuffering = buffering;
            if (!buffering) _isClipLoading = false;
          });
        }
      }),
    );

    _playerSubscriptions.add(
      _player.stream.position.listen((pos) {
        if (mounted) {
          setState(() {
            _currentPosition = pos;
            if (_isClipLoading && pos > Duration.zero) {
              _isClipLoading = false;
            }
          });
        }
      }),
    );

    // P1-3: Added bounds check (_selectedClipIndex < _clips.length)
    // to prevent RangeError when clips are cleared while stream events are in-flight
    _playerSubscriptions.add(
      _player.stream.duration.listen((duration) {
        if (duration != null && duration > Duration.zero &&
            _selectedClipIndex >= 0 && _selectedClipIndex < _clips.length) {
          final currentClip = _clips[_selectedClipIndex];
          if (!_viewingTrimmedMode && currentClip.duration == Duration.zero) {
            setState(() {
              currentClip.duration = duration;
              currentClip.endCut = duration;
            });
          }
        }
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // P2-2: Cancel all player stream subscriptions before disposing player
    for (final sub in _playerSubscriptions) {
      sub.cancel();
    }
    _playerSubscriptions.clear();
    _toastDismissTimer?.cancel();
    _toastAnimController.dispose();
    _player.dispose();
    _exportNameController.dispose();
    _focusNode.dispose();
    _exportNameFocusNode.dispose();
    super.dispose();
  }

  // Load a video clip into the player
  Future<void> _selectClip(int index, {bool forceOriginal = false}) async {
    if (index < 0 || index >= _clips.length) return;
    final currentToken = ++_selectClipToken;
    final clip = _clips[index];
    setState(() {
      _selectedClipIndex = index;
      if (clip.isTrimmed) {
        _exportNameController.text = path.basenameWithoutExtension(clip.fileName);
      } else {
        _exportNameController.text = path.basenameWithoutExtension(clip.fileName) + '_cut';
      }
      if (forceOriginal) {
        _viewingTrimmedMode = false;
      } else {
        _viewingTrimmedMode = clip.isTrimmed;
      }
    });

    final loadPath = _viewingTrimmedMode ? (clip.trimmedOutputPath ?? clip.filePath) : clip.filePath;
    LoggerService.logInfo('Selecting clip [$index]: ${clip.fileName} (Path: $loadPath)');

    if (_currentlyLoadedMediaUrl == loadPath) {
      LoggerService.logInfo('Media is already active in player: $loadPath. Seeking to start.');
      try {
        await _player.seek(Duration.zero);
        await _player.pause();
      } catch (e) {
        debugPrint('Failed to seek active media: $e');
      }
    } else {
      try {
        if (!mounted || currentToken != _selectClipToken) {
          LoggerService.logInfo('Aborting stale media load token $currentToken (latest is $_selectClipToken)');
          return;
        }
        _currentlyLoadedMediaUrl = loadPath;
        await _player.open(Media(loadPath), play: false);
        if (!mounted || currentToken != _selectClipToken) return;
        await _player.setRate(_playbackSpeed);
      } catch (e, stack) {
        LoggerService.logError('Player failed to open media $loadPath: $e', stack);
      }
    }

    // Async FFprobe probe for quality metadata (resolution, FPS, bitrate, duration)
    if (clip.resolution == null || clip.fps == null || clip.bitrate == null || clip.duration == Duration.zero) {
      final capturedIndex = index;
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted || _selectedClipIndex != capturedIndex) return;
        _probeClipMetadata(clip);
      });
    }

    // Auto-scroll to keep the selected clip visible on screen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final clip = _clips[index];
      final key = _clipKeys[clip];
      if (key != null && key.currentContext != null) {
        Scrollable.ensureVisible(
          key.currentContext!,
          duration: const Duration(milliseconds: 300),
          alignment: 0.5, // Align to middle of viewport
        );
      }
    });
  }

  void _sortClips() {
    VideoClip? selectedClip;
    if (_selectedClipIndex >= 0 && _selectedClipIndex < _clips.length) {
      selectedClip = _clips[_selectedClipIndex];
    }

    switch (_sortBy) {
      case 'created_desc':
        _clips.sort((a, b) => b.dateCreated.compareTo(a.dateCreated));
        break;
      case 'created_asc':
        _clips.sort((a, b) => a.dateCreated.compareTo(b.dateCreated));
        break;
      case 'size_desc':
        _clips.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));
        break;
      case 'size_asc':
        _clips.sort((a, b) => a.fileSizeBytes.compareTo(b.fileSizeBytes));
        break;
    }

    if (selectedClip != null) {
      _selectedClipIndex = _clips.indexOf(selectedClip);
    }
  }

  List<VideoClip> _getVisibleSelectableClips() {
    final List<VideoClip> list = [];
    if (_trimmedExpanded) {
      list.addAll(_getTrimmedClips());
    }
    if (_untrimmedExpanded) {
      list.addAll(_getUntrimmedClips());
    }
    return list;
  }

  void _selectPreviousClip() {
    if (_selectedClipIndex == -1) return;
    final activeClip = _clips[_selectedClipIndex];
    final visibleClips = _getVisibleSelectableClips();
    final idx = visibleClips.indexOf(activeClip);
    if (idx > 0) {
      final prevClip = visibleClips[idx - 1];
      final newIdx = _clips.indexOf(prevClip);
      if (newIdx != -1) {
        _selectClip(newIdx);
      }
    }
  }

  void _selectNextClip() {
    if (_selectedClipIndex == -1) return;
    final activeClip = _clips[_selectedClipIndex];
    final visibleClips = _getVisibleSelectableClips();
    final idx = visibleClips.indexOf(activeClip);
    if (idx != -1 && idx < visibleClips.length - 1) {
      final nextClip = visibleClips[idx + 1];
      final newIdx = _clips.indexOf(nextClip);
      if (newIdx != -1) {
        _selectClip(newIdx);
      }
    }
  }

  Future<List<VideoClip>> _scanClipsInBatches(List<String> filePaths) async {
    final List<VideoClip> result = [];
    const int batchSize = 25;
    final total = filePaths.length;

    for (int i = 0; i < total; i += batchSize) {
      final end = (i + batchSize < total) ? i + batchSize : total;
      final currentBatch = filePaths.sublist(i, end);

      final batchClips = await Future.wait(
        currentBatch.map((fp) => VideoClip.fromPath(fp))
      );
      result.addAll(batchClips);

      if (mounted) {
        setState(() {
          _importProgressStatus = 'Importing video clips ($end / $total)...';
        });
        // Yield execution to the Flutter engine & OS event loop so UI stays 100% responsive
        await Future.delayed(const Duration(milliseconds: 1));
      }
    }
    return result;
  }

  // Import files
  Future<void> _importFiles() async {
    if (_isImporting) return;
    try {
      if (_clips.isNotEmpty) {
        _player.pause();
      }
      List<String> validFilePaths = [];
      try {
        final typeGroup = file_selector.XTypeGroup(
          label: 'Videos',
          extensions: ['mp4', 'mkv', 'avi', 'mov'],
        );
        final files = await file_selector.openFiles(acceptedTypeGroups: [typeGroup]);
        validFilePaths = files.map((f) => f.path).toList();
      } catch (e, stack) {
        LoggerService.logError('file_selector openFiles error: $e', stack);
      }

      if (validFilePaths.isNotEmpty) {
        // Show loading overlay IMMEDIATELY after user confirms selection
        setState(() {
          _isImporting = true;
          _importProgressStatus = 'Preparing to import ${validFilePaths.length} clips...';
        });
        // Paint loading overlay immediately before processing
        await Future.delayed(const Duration(milliseconds: 50));

        final firstPath = validFilePaths.first;
        _currentWorkspacePath = path.dirname(firstPath);

        LoggerService.logInfo('Importing ${validFilePaths.length} files from workspace: $_currentWorkspacePath');

        // Batched parallel file scanning with UI yielding
        final newClips = await _scanClipsInBatches(validFilePaths);

        // Pause player & clear pending thumbnail queue for clean workspace switch
        try {
          await _player.pause();
        } catch (_) {}
        VideoTrimmer.clearThumbnailQueue();

        setState(() {
          _clips.clear();
          _selectedClipIndex = -1;
          _currentlyLoadedMediaUrl = null;
          _clips.addAll(newClips);
          _sortClips();
        });
        await _restoreSessionData();
        setState(() {
          _sortClips();
        });
        if (_clips.isNotEmpty) {
          final targetIndex = _getFirstUntrimmedIndex();
          if (targetIndex != -1) {
            await _selectClip(targetIndex);
          }
        }
      }
    } catch (e, stack) {
      LoggerService.logError('Failed to import files: $e', stack);
      _showSnackBar('Failed to import files: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgressStatus = '';
        });
      }
    }
  }

  // Import Folder
  Future<void> _importFolder() async {
    if (_isImporting) return;
    try {
      if (_clips.isNotEmpty) {
        _player.pause();
      }
      String? directoryPath;
      try {
        directoryPath = await file_selector.getDirectoryPath();
      } catch (e, stack) {
        LoggerService.logError('file_selector getDirectoryPath error: $e', stack);
      }

      if (directoryPath != null) {
        // Show loading overlay IMMEDIATELY after user confirms folder selection
        setState(() {
          _isImporting = true;
          _importProgressStatus = 'Opening workspace folder...';
        });
        // Paint loading overlay immediately before disk operations
        await Future.delayed(const Duration(milliseconds: 50));

        _currentWorkspacePath = directoryPath;
        LoggerService.logInfo('Opening workspace folder: $directoryPath');

        final dir = Directory(directoryPath);
        final List<String> validFilePaths = [];

        int scannedCount = 0;
        await for (final entity in dir.list(followLinks: false)) {
          scannedCount++;
          if (entity is File) {
            final ext = path.extension(entity.path).toLowerCase();
            if (['.mp4', '.mkv', '.avi', '.mov'].contains(ext)) {
              validFilePaths.add(entity.path);
            }
          }
          if (scannedCount % 100 == 0 && mounted) {
            setState(() {
              _importProgressStatus = 'Scanning directory... (${validFilePaths.length} videos found)';
            });
            await Future.delayed(const Duration(milliseconds: 1));
          }
        }

        if (validFilePaths.isEmpty) {
          _showSnackBar('No valid video files found in the selected folder.', isError: false);
          return;
        }

        setState(() {
          _importProgressStatus = 'Found ${validFilePaths.length} videos. Importing...';
        });
        await Future.delayed(const Duration(milliseconds: 20));

        // Batched parallel file scanning with UI yielding
        final newClips = await _scanClipsInBatches(validFilePaths);

        // Pause player & clear pending thumbnail queue for clean workspace switch
        try {
          await _player.pause();
        } catch (_) {}
        VideoTrimmer.clearThumbnailQueue();

        setState(() {
          _clips.clear();
          _selectedClipIndex = -1;
          _currentlyLoadedMediaUrl = null;
          _clips.addAll(newClips);
          _sortClips();
        });
        await _restoreSessionData();
        setState(() {
          _sortClips();
        });
        if (_clips.isNotEmpty) {
          final targetIndex = _getFirstUntrimmedIndex();
          if (targetIndex != -1) {
            await _selectClip(targetIndex);
          }
        }
      }
    } catch (e, stack) {
      LoggerService.logError('Failed to import folder: $e', stack);
      _showSnackBar('Failed to import folder: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgressStatus = '';
        });
      }
    }
  }

  void _handleDroppedFiles(List<String> filePaths) async {
    if (_isImporting) return;
    setState(() {
      _isImporting = true;
      _importProgressStatus = 'Processing dropped items...';
    });
    // Paint loading overlay immediately before file scanning
    await Future.delayed(const Duration(milliseconds: 50));

    try {
      // P1-2: Expand directories — if a dropped path is a folder, scan it for video files
      final List<String> expandedPaths = [];
      for (final fp in filePaths) {
        if (FileSystemEntity.isDirectorySync(fp)) {
          try {
            final dir = Directory(fp);
            await for (final entity in dir.list(followLinks: false)) {
              if (entity is File) {
                final ext = path.extension(entity.path).toLowerCase();
                if (['.mp4', '.mkv', '.avi', '.mov'].contains(ext)) {
                  expandedPaths.add(entity.path);
                }
              }
            }
          } catch (_) {}
        } else {
          expandedPaths.add(fp);
        }
      }

      if (expandedPaths.isNotEmpty) {
        _currentWorkspacePath = path.dirname(expandedPaths.first);
      }

      final validPaths = expandedPaths.where((fp) {
        final ext = path.extension(fp).toLowerCase();
        return ['.mp4', '.mkv', '.avi', '.mov'].contains(ext);
      }).toList();

      if (validPaths.isNotEmpty) {
        LoggerService.logInfo('Dropped ${validPaths.length} files into workspace');
        setState(() {
          _importProgressStatus = 'Importing ${validPaths.length} dropped clips...';
        });
        // Batched parallel file scanning with UI yielding
        final newClips = await _scanClipsInBatches(validPaths);

        // Pause player & clear pending thumbnail queue for clean workspace switch
        try {
          await _player.pause();
        } catch (_) {}
        VideoTrimmer.clearThumbnailQueue();

        setState(() {
          _clips.clear();
          _selectedClipIndex = -1;
          _currentlyLoadedMediaUrl = null;
          _clips.addAll(newClips);
          _sortClips();
        });
        await _restoreSessionData();
        setState(() {
          _sortClips();
        });
        if (_clips.isNotEmpty) {
          final targetIndex = _getFirstUntrimmedIndex();
          if (targetIndex != -1) {
            await _selectClip(targetIndex);
          }
        }
      } else {
        _showSnackBar('No valid video files dropped.', isError: true);
      }
    } catch (e, stack) {
      LoggerService.logError('Failed to handle dropped files: $e', stack);
      _showSnackBar('Failed to handle dropped files: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgressStatus = '';
        });
      }
    }
  }

  // Set Cut Points
  void _setStartCut() {
    if (_selectedClipIndex == -1) return;
    setState(() {
      final clip = _clips[_selectedClipIndex];
      if (_currentPosition < clip.endCut) {
        clip.startCut = _currentPosition;
      } else {
        _showSnackBar('Start point must be before End point.');
      }
    });
  }

  void _setEndCut() {
    if (_selectedClipIndex == -1) return;
    setState(() {
      final clip = _clips[_selectedClipIndex];
      if (_currentPosition > clip.startCut) {
        clip.endCut = _currentPosition;
      } else {
        _showSnackBar('End point must be after Start point.');
      }
    });
  }

  // Formatter helper
  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String milliseconds = (duration.inMilliseconds % 1000).toString().padLeft(3, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds.$milliseconds";
  }

  void _showSnackBar(String message, {bool isError = false, bool isDelete = false, Duration duration = const Duration(seconds: 3)}) {
    if (!mounted) return;

    _toastDismissTimer?.cancel();

    setState(() {
      _toastMessage = message;
      _isToastError = isError;
      _isToastDelete = isDelete;
    });

    _toastAnimController.forward(from: 0.0);

    _toastDismissTimer = Timer(duration, () {
      _dismissToast();
    });
  }

  void _dismissToast() {
    _toastDismissTimer?.cancel();
    if (mounted && _toastMessage != null) {
      _toastAnimController.reverse().then((_) {
        if (mounted && _toastAnimController.isDismissed) {
          setState(() {
            _toastMessage = null;
          });
        }
      });
    }
  }

  Widget _buildToastNotification() {
    if (_toastMessage == null) return const SizedBox.shrink();

    final Color accentColor = (_isToastError || _isToastDelete)
        ? const Color(0xFFEF4444)
        : const Color(0xFF76B900);

    final IconData icon = _isToastError
        ? Icons.error_outline_rounded
        : (_isToastDelete ? Icons.delete_outline_rounded : Icons.check_circle_outline_rounded);

    return Positioned(
      bottom: _isEndingSession ? 84 : 24,
      right: 28,
      child: SlideTransition(
        position: _toastSlideAnim,
        child: FadeTransition(
          opacity: _toastFadeAnim,
          child: Material(
            color: Colors.transparent,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _dismissToast,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480, minWidth: 260),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161622).withOpacity(0.96),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: accentColor.withOpacity(0.45),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.55),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: accentColor.withOpacity(0.15),
                        blurRadius: 12,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: accentColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(icon, color: accentColor, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _toastMessage!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      InkWell(
                        onTap: _dismissToast,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMute() {
    setState(() {
      if (_volume > 0) {
        _lastVolume = _volume;
        _volume = 0;
      } else {
        _volume = _lastVolume > 0 ? _lastVolume : 100;
      }
      _player.setVolume(_volume);
    });
  }

  List<double> get _availablePlaybackSpeeds {
    if (_selectedClipIndex >= 0 && _selectedClipIndex < _clips.length) {
      final activeClip = _clips[_selectedClipIndex];
      if (activeClip.fps != null && activeClip.fps! > 60) {
        return [0.25, 0.5, 1.0, 1.5, 2.0];
      }
    }
    return [0.25, 0.5, 1.0, 1.5, 2.0, 3.0];
  }

  void _changeSpeed(bool increase) {
    final List<double> speeds = _availablePlaybackSpeeds;
    int index = speeds.indexOf(_playbackSpeed);
    if (index == -1) {
      _playbackSpeed = speeds.last;
      index = speeds.length - 1;
    }

    if (increase) {
      if (index < speeds.length - 1) {
        index++;
      }
    } else {
      if (index > 0) {
        index--;
      }
    }

    setState(() {
      _playbackSpeed = speeds[index];
    });
    _player.setRate(speeds[index]);
  }

  Future<void> _deleteToRecycleBin(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return;

      // 1. High-Performance C++ Win32 Recycle Bin (<1ms)
      if (Platform.isWindows && ShadowTrimNativeBridge.isAvailable) {
        final success = ShadowTrimNativeBridge.recycleFileNative(filePath);
        if (success) {
          LoggerService.logInfo('Recycled file via C++ Native Core: $filePath');
          return;
        }
      }

      // 2. PowerShell Fallback
      if (Platform.isWindows) {
        final escapedPath = filePath.replaceAll('"', '`"');
        final cmd = 'Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("$escapedPath", "OnlyErrorDialogs", "SendToRecycleBin")';
        final res = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd]);
        if (res.exitCode == 0) return;
      }

      // 3. Direct File Delete Fallback
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  Future<File> _getLegacyBlacklistFile() async {
    if (_currentWorkspacePath != null) {
      return File(path.join(_currentWorkspacePath!, '.shadowtrim_blacklist.json'));
    }
    final docDir = await getApplicationDocumentsDirectory();
    return File(path.join(docDir.path, 'shadowtrim_global_blacklist.json'));
  }

  Future<String?> _showSessionSavePrompt() async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.8),
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.pop(ctx, 'cancel');
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 400,
            decoration: BoxDecoration(
              color: const Color(0xFF11111B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF76B900).withOpacity(0.35), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF0F1E15),
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.save_outlined, color: Color(0xFF76B900), size: 18),
                      const SizedBox(width: 8),
                      const Text('Save Session?', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.3)),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(ctx, 'cancel'),
                          child: const Icon(Icons.close, size: 16, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
                // Content
                const Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'You have active clips in this session.',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Do you want to save the session? Saving will remember previously trimmed clips.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // Actions
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, 'cancel'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Color(0xFF2E2E3E)),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, 'delete'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade900,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
                            ),
                          ),
                          child: const Text('End This Session', style: TextStyle(fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, 'save'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF76B900),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: const Color(0xFF76B900).withOpacity(0.5)),
                            ),
                          ),
                          child: const Text('Save Session', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAboutDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.8),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 380,
          decoration: BoxDecoration(
            color: const Color(0xFF11111B),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF76B900).withOpacity(0.35), width: 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: const BoxDecoration(
                  color: Color(0xFF0F1E15),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFF76B900), size: 18),
                    const SizedBox(width: 8),
                    const Text('About ShadowTrim', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.3)),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/app_icon.png', width: 64, height: 64),
                    const SizedBox(height: 16),
                    const Text(
                      'Hi, this is just a small project I made for fun',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Version : v2.2.0',
                      style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 24),
                    // Social / Support Buttons
                    _buildAboutLinkButton(
                      icon: Icons.code,
                      label: 'GitHub',
                      color: const Color(0xFF24292F),
                      url: 'https://github.com/Zfanz12',
                    ),
                    const SizedBox(height: 8),
                    _buildAboutLinkButton(
                      icon: Icons.camera_alt_outlined,
                      label: 'Instagram',
                      color: const Color(0xFFE1306C),
                      url: 'https://www.instagram.com/zulfanfalah_12/',
                    ),
                    const SizedBox(height: 8),
                    _buildAboutLinkButton(
                      icon: Icons.coffee,
                      label: 'Buy me a Roti-O',
                      color: const Color(0xFFFF5E5B),
                      url: 'https://ko-fi.com/S4Y52325J2',
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          LoggerService.openLogFolder();
                        },
                        icon: const Icon(Icons.bug_report_outlined, size: 16, color: Color(0xFF76B900)),
                        label: const Text('View Crash Logs', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF76B900))),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: const Color(0xFF76B900).withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAboutLinkButton({
    required IconData icon,
    required String label,
    required Color color,
    required String url,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => _launchUrl(url),
        icon: Icon(icon, size: 16, color: Colors.white),
        label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', url.replaceAll('&', '^&')], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      debugPrint('Failed to launch URL: $e');
    }
  }

  void _openInExplorer(String path, {bool select = false}) {
    try {
      if (Platform.isWindows) {
        if (select) {
          Process.start('explorer', ['/select,', path], mode: ProcessStartMode.detached);
        } else {
          Process.start('explorer', [path], mode: ProcessStartMode.detached);
        }
      } else if (Platform.isMacOS) {
        if (select) {
          Process.start('open', ['-R', path], mode: ProcessStartMode.detached);
        } else {
          Process.start('open', [path], mode: ProcessStartMode.detached);
        }
      } else if (Platform.isLinux) {
        final dirPath = select ? File(path).parent.path : path;
        Process.start('xdg-open', [dirPath], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      debugPrint('Failed to open explorer: $e');
    }
  }

  Future<void> _deleteQueuedOriginalFiles() async {
    for (final filePath in _originalClipsToDelete) {
      await _deleteToRecycleBin(filePath);
    }
    _originalClipsToDelete.clear();
  }

  // ── Full Session Persistence ──────────────────────────────────────────────

  Future<File> _getSessionFile() async {
    if (_currentWorkspacePath != null) {
      return File(path.join(_currentWorkspacePath!, '.shadowtrim_session.json'));
    }
    final docDir = await getApplicationDocumentsDirectory();
    return File(path.join(docDir.path, 'shadowtrim_global_session.json'));
  }

  Future<File> _getLastSessionPointerFile() async {
    final docDir = await getApplicationDocumentsDirectory();
    return File(path.join(docDir.path, 'shadowtrim_last_session_ptr.json'));
  }

  Future<void> _saveLastSessionPointer() async {
    try {
      if (_currentWorkspacePath == null) return;
      final file = await _getLastSessionPointerFile();
      await file.writeAsString(jsonEncode({'workspacePath': _currentWorkspacePath}));
    } catch (e) {
      debugPrint('Failed to save last session pointer: $e');
    }
  }

  Future<void> _loadLastSessionPointer() async {
    try {
      final file = await _getLastSessionPointerFile();
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(content);
      final String? wp = data['workspacePath'] as String?;
      if (wp == null) return;
      // Check if the session file actually exists there
      final sessionFile = File(path.join(wp, '.shadowtrim_session.json'));
      if (await sessionFile.exists()) {
        if (mounted) setState(() => _lastSessionWorkspacePath = wp);
      }
    } catch (e) {
      debugPrint('Failed to load last session pointer: $e');
    }
  }

  Future<void> _saveSessionData() async {
    try {
      final file = await _getSessionFile();
      final List<Map<String, dynamic>> clipData = _clips.map((c) => {
        'filePath': c.filePath,
        'fileName': c.fileName,
        'originalFileName': c.originalFileName,
        'isTrimmed': c.isTrimmed,
        'trimmedOutputPath': c.trimmedOutputPath,
        'startCutMs': c.startCut.inMilliseconds,
        'endCutMs': c.endCut.inMilliseconds,
        'durationMs': c.duration.inMilliseconds,
        'flaggedForDeletion': _originalClipsToDelete.contains(c.filePath),
      }).toList();
      final List<Map<String, dynamic>> deletedData = _deletedClips.map((c) => {
        'filePath': c.filePath,
        'fileName': c.fileName,
        'originalFileName': c.originalFileName,
      }).toList();
      await file.writeAsString(jsonEncode({
        'version': 2,
        'clips': clipData,
        'deletedClips': deletedData,
        'originalClipsToDelete': _originalClipsToDelete.toList(),
        'blacklistedClips': _blacklistedClipNames.toList(),
      }));
      await _saveLastSessionPointer();

      // Clean up legacy blacklist file if it still exists
      final legacy = await _getLegacyBlacklistFile();
      if (await legacy.exists()) {
        try {
          await legacy.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Failed to save session data: $e');
    }
  }

  Future<void> _restoreSessionData() async {
    try {
      final file = await _getSessionFile();
      final legacyFile = await _getLegacyBlacklistFile();
      
      // If neither session file nor legacy blacklist file exists, return
      if (!await file.exists() && !await legacyFile.exists()) return;

      Map<String, dynamic> json = {};
      if (await file.exists()) {
        final content = await file.readAsString();
        json = jsonDecode(content);
      }

      final List<dynamic> savedClips = json['clips'] ?? [];
      final List<dynamic> savedDeleted = json['deletedClips'] ?? [];
      final List<dynamic> savedToDelete = json['originalClipsToDelete'] ?? [];
      final List<dynamic> savedBlacklist = json['blacklistedClips'] ?? [];

      final Map<String, Map<String, dynamic>> byPath = {
        for (final c in savedClips) (c['filePath'] as String): c as Map<String, dynamic>
      };
      final List<VideoClip> restoredDeleted = [];
      for (final d in savedDeleted) {
        final fp = d['filePath'] as String;
        final file = File(fp);
        if (await file.exists()) {
          final length = await file.length();
          final stat = await file.stat();
          restoredDeleted.add(VideoClip(
            filePath: fp,
            fileName: d['fileName'] as String? ?? path.basename(fp),
            originalFileName: d['originalFileName'] as String? ?? path.basename(fp),
            fileSizeBytes: length,
            dateModified: stat.modified,
            dateCreated: stat.changed,
          ));
        }
      }

      // Check legacy blacklist file for migration
      final Set<String> migratedBlacklist = savedBlacklist.cast<String>().toSet();
      if (await legacyFile.exists()) {
        try {
          final legacyContent = await legacyFile.readAsString();
          final List<dynamic> legacyList = jsonDecode(legacyContent);
          migratedBlacklist.addAll(legacyList.cast<String>());
          await legacyFile.delete();
        } catch (_) {}
      }

      setState(() {
        _blacklistedClipNames.clear();
        _blacklistedClipNames.addAll(migratedBlacklist);

        for (final clip in _clips) {
          final saved = byPath[clip.filePath];
          if (saved != null) {
            clip.fileName = saved['fileName'] as String? ?? clip.fileName;
            clip.isTrimmed = saved['isTrimmed'] as bool? ?? false;
            clip.trimmedOutputPath = saved['trimmedOutputPath'] as String?;
            clip.startCut = Duration(milliseconds: (saved['startCutMs'] as int?) ?? 0);
            clip.endCut = Duration(milliseconds: (saved['endCutMs'] as int?) ?? 0);
            clip.duration = Duration(milliseconds: (saved['durationMs'] as int?) ?? 0);
            if (clip.isTrimmed) _blacklistedClipNames.add(clip.filePath);
          }
        }
        _deletedClips = restoredDeleted;
        _originalClipsToDelete.addAll(savedToDelete.cast<String>());
        // P0-3: Remove ghost clips — clips that are in _deletedClips should not appear in _clips
        final deletedPaths = restoredDeleted.map((d) => d.filePath).toSet();
        _clips.removeWhere((clip) => deletedPaths.contains(clip.filePath));
      });
    } catch (e) {
      debugPrint('Failed to restore session data: $e');
    }
  }

  Future<void> _deleteSessionData() async {
    try {
      final file = await _getSessionFile();
      if (await file.exists()) await file.delete();
      // Also remove the last session pointer
      final ptr = await _getLastSessionPointerFile();
      if (await ptr.exists()) await ptr.delete();
      // Delete legacy blacklist file if present
      final legacy = await _getLegacyBlacklistFile();
      if (await legacy.exists()) await legacy.delete();

      if (mounted) {
        setState(() {
          _blacklistedClipNames.clear();
        });
      }
    } catch (e) {
      debugPrint('Failed to delete session data: $e');
    }
  }

  /// Restores a session from a given workspace path (for "Continue" button)
  Future<void> _continueLastSession(String workspacePath) async {
    _currentWorkspacePath = workspacePath;
    final sessionFile = File(path.join(workspacePath, '.shadowtrim_session.json'));
    if (!await sessionFile.exists()) return;
    final content = await sessionFile.readAsString();
    final Map<String, dynamic> json = jsonDecode(content);
    final List<dynamic> savedClips = json['clips'] ?? [];
    final List<dynamic> savedDeleted = json['deletedClips'] ?? [];
    final List<dynamic> savedToDelete = json['originalClipsToDelete'] ?? [];
    final List<dynamic> savedBlacklist = json['blacklistedClips'] ?? [];

    final List<VideoClip> restoredClips = [];
    for (final c in savedClips) {
      final fp = c['filePath'] as String;
      if (File(fp).existsSync()) {
        final clip = await VideoClip.fromPath(fp);
        clip.fileName = c['fileName'] as String? ?? clip.fileName;
        clip.isTrimmed = c['isTrimmed'] as bool? ?? false;
        clip.trimmedOutputPath = c['trimmedOutputPath'] as String?;
        clip.startCut = Duration(milliseconds: (c['startCutMs'] as int?) ?? 0);
        clip.endCut = Duration(milliseconds: (c['endCutMs'] as int?) ?? 0);
        clip.duration = Duration(milliseconds: (c['durationMs'] as int?) ?? 0);
        if (clip.isTrimmed) _blacklistedClipNames.add(clip.filePath);
        restoredClips.add(clip);
      }
    }
    final List<VideoClip> restoredDeleted = [];
    for (final d in savedDeleted) {
      final fp = d['filePath'] as String;
      if (File(fp).existsSync()) {
        restoredDeleted.add(VideoClip(
          filePath: fp,
          fileName: d['fileName'] as String? ?? path.basename(fp),
          originalFileName: d['originalFileName'] as String? ?? path.basename(fp),
          fileSizeBytes: File(fp).lengthSync(),
          dateModified: File(fp).lastModifiedSync(),
          dateCreated: File(fp).lastModifiedSync(),
        ));
      }
    }
    setState(() {
      _clips = restoredClips;
      _deletedClips = restoredDeleted;
      _originalClipsToDelete.addAll(savedToDelete.cast<String>());
      _blacklistedClipNames.clear();
      _blacklistedClipNames.addAll(savedBlacklist.cast<String>());
      _lastSessionWorkspacePath = null;
      _sortClips();
      if (_clips.isNotEmpty) {
        final targetIndex = _getFirstUntrimmedIndex();
        if (targetIndex != -1) {
          _selectClip(targetIndex);
        }
      }
    });
  }



  // ── End Session Dialog & Cleanup Loading Indicator ────────────────────────

  Future<void> _showEndSessionDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.8),
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.pop(ctx, false);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 420,
            decoration: BoxDecoration(
              color: const Color(0xFF11111B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.redAccent.withOpacity(0.35), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1A0808),
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                      const SizedBox(width: 8),
                      const Text('End This Session?', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.3)),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(ctx, false),
                          child: const Icon(Icons.close, size: 16, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
                // Content
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Are you sure you want to end this session?',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'All clips flagged for deletion will be permanently moved to the Recycle Bin. '
                        'This session\'s history will be cleared — trimmed clips will not be restored '
                        'the next time you open this folder.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // Actions
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Color(0xFF2E2E3E)),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text('Cancel', style: TextStyle(fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade900,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
                            ),
                          ),
                          child: const Text('End Session', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      // P1-5: Deduplicate file paths to avoid double-counting
      final allPathsToDelete = <String>{
        ..._deletedClips.map((c) => c.filePath),
        ..._originalClipsToDelete,
      };
      final totalCount = allPathsToDelete.length;
      final processedPaths = <String>{};
      setState(() {
        _isEndingSession = true;
        _totalDeletingFiles = totalCount;
        _currentDeletedCount = 0;
        _currentDeletingFileName = '';
        _endingSessionStatus = totalCount > 0
            ? 'Deleting session files... (0/$totalCount) deleted'
            : 'Cleaning up session files...';
      });

      try {
        // Delete clips flagged via "Delete Clip" button
        for (final clip in List<VideoClip>.from(_deletedClips)) {
          if (!mounted) break;
          if (processedPaths.contains(clip.filePath)) continue;
          processedPaths.add(clip.filePath);
          setState(() {
            _currentDeletingFileName = clip.fileName;
          });
          await _deleteToRecycleBin(clip.filePath);
          if (!mounted) break;
          setState(() {
            _currentDeletedCount++;
            _endingSessionStatus = 'Deleting session files... ($_currentDeletedCount/$_totalDeletingFiles) deleted';
          });
        }

        // Delete clips flagged via "Delete original clip after trim"
        for (final filePath in List<String>.from(_originalClipsToDelete)) {
          if (!mounted) break;
          if (processedPaths.contains(filePath)) continue;
          processedPaths.add(filePath);
          setState(() {
            _currentDeletingFileName = path.basename(filePath);
          });
          await _deleteToRecycleBin(filePath);
          if (!mounted) break;
          setState(() {
            _currentDeletedCount++;
            _endingSessionStatus = 'Deleting session files... ($_currentDeletedCount/$_totalDeletingFiles) deleted';
          });
        }
        _originalClipsToDelete.clear();

        await _deleteSessionData();

        if (mounted) {
          setState(() {
            _endingSessionStatus = 'Session cleanup complete! ($_totalDeletingFiles/$_totalDeletingFiles)';
          });
        }
        await Future.delayed(const Duration(milliseconds: 300));
      } finally {
        if (mounted) {
          final deletedTotal = _totalDeletingFiles;
          setState(() {
            _clips.clear();
            _deletedClips.clear();
            _selectedClipIndex = -1;
            _blacklistedClipNames.clear();
            _originalClipsToDelete.clear();
            _isEndingSession = false;
            _totalDeletingFiles = 0;
            _currentDeletedCount = 0;
            _currentDeletingFileName = '';
          });
          _player.pause();
          _showSnackBar(deletedTotal > 0
              ? 'Session ended cleanly ($deletedTotal files deleted).'
              : 'Session ended cleanly.');
        }
      }
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (!mounted) return AppExitResponse.exit;
    if (_isExiting) return AppExitResponse.exit; // Already approved exit, let it close!
    if (_isShowingExitDialog) return AppExitResponse.cancel;

    if (_clips.isNotEmpty || _blacklistedClipNames.isNotEmpty || _deletedClips.isNotEmpty) {
      try {
        setState(() => _isShowingExitDialog = true);
        final result = await _showSessionSavePrompt();
        setState(() => _isShowingExitDialog = false);

        if (result == 'save') {
          setState(() => _isExiting = true);
          // Save session WITHOUT executing deletions — they only run on End Session
          await _saveSessionData();
          return AppExitResponse.exit;
        } else if (result == 'delete') {
          // P1-5: Deduplicate file paths to avoid double-counting
          final allPathsToDelete = <String>{
            ..._deletedClips.map((c) => c.filePath),
            ..._originalClipsToDelete,
          };
          final totalCount = allPathsToDelete.length;
          final processedPaths = <String>{};
          setState(() {
            _isExiting = true;
            _isEndingSession = true;
            _totalDeletingFiles = totalCount;
            _currentDeletedCount = 0;
            _currentDeletingFileName = '';
            _endingSessionStatus = totalCount > 0
                ? 'Deleting session files... (0/$totalCount) deleted'
                : 'Cleaning up session files...';
          });

          // End This Session — execute all pending deletions with progress
          for (final clip in List<VideoClip>.from(_deletedClips)) {
            if (!mounted) break;
            if (processedPaths.contains(clip.filePath)) continue;
            processedPaths.add(clip.filePath);
            setState(() {
              _currentDeletingFileName = clip.fileName;
            });
            await _deleteToRecycleBin(clip.filePath);
            if (!mounted) break;
            setState(() {
              _currentDeletedCount++;
              _endingSessionStatus = 'Deleting session files... ($_currentDeletedCount/$_totalDeletingFiles) deleted';
            });
          }

          for (final filePath in List<String>.from(_originalClipsToDelete)) {
            if (!mounted) break;
            if (processedPaths.contains(filePath)) continue;
            processedPaths.add(filePath);
            setState(() {
              _currentDeletingFileName = path.basename(filePath);
            });
            await _deleteToRecycleBin(filePath);
            if (!mounted) break;
            setState(() {
              _currentDeletedCount++;
              _endingSessionStatus = 'Deleting session files... ($_currentDeletedCount/$_totalDeletingFiles) deleted';
            });
          }
          _originalClipsToDelete.clear();

          await _deleteSessionData();
          return AppExitResponse.exit;
        } else {
          return AppExitResponse.cancel;
        }
      } catch (e) {
        setState(() => _isShowingExitDialog = false);
        debugPrint('Error showing exit dialog: $e');
        setState(() => _isExiting = true);
        return AppExitResponse.exit;
      }
    }
    
    setState(() => _isExiting = true);
    return AppExitResponse.exit;
  }

  // Delete file with confirmation dialog
  Future<void> _confirmDeleteFile(VideoClip clip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.8),
      builder: (ctx) => Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
              Navigator.pop(ctx, true);
              return KeyEventResult.handled;
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              Navigator.pop(ctx, false);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: 380,
            decoration: BoxDecoration(
              color: const Color(0xFF11111B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.redAccent.withOpacity(0.35), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1A0A0A),
                    borderRadius: BorderRadius.only(topLeft: Radius.circular(9), topRight: Radius.circular(9)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.delete_forever_outlined, color: Colors.redAccent, size: 18),
                      const SizedBox(width: 8),
                      const Text('Delete Clip', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 0.3)),
                      const Spacer(),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(ctx, false),
                          child: const Icon(Icons.close, size: 16, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ),
                // Content
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Permanently delete this clip from disk?',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0B0B0F),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF2E2E3E)),
                        ),
                        child: Text(
                          clip.fileName,
                          style: const TextStyle(fontSize: 11, color: Colors.white60, fontFamily: 'monospace'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange.shade700),
                          const SizedBox(width: 5),
                          Text('This action cannot be undone.', style: TextStyle(color: Colors.orange.shade700, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                ),
                // Actions
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Color(0xFF2E2E3E)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.delete_forever_outlined, size: 14),
                          label: const Text('Delete', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade900,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                              side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      setState(() {
        _clips.remove(clip);
        _deletedClips.add(clip);
        // Reset selection if the deleted clip was selected
        if (_selectedClipIndex >= _clips.length) {
          _selectedClipIndex = _clips.isEmpty ? -1 : _clips.length - 1;
        }
        if (_selectedClipIndex >= 0) {
          _selectClip(_selectedClipIndex);
        } else if (_clips.isEmpty) {
          _player.pause();
          _selectedClipIndex = -1;
        }
      });
      _showSnackBar('Clip flagged for deletion. Will be removed on End Session.', isDelete: true);
    }
  }

  // Export
  Future<void> _exportActiveClip() async {
    if (_selectedClipIndex == -1) return;
    final clip = _clips[_selectedClipIndex];

    setState(() {
      _isExporting = true;
      _exportStatus = 'Trimming Video...';
    });

    // Get customized export path
    String dir = _customExportDir ?? path.dirname(clip.filePath);
    if (_autoCreateTrimmedFolder) {
      dir = path.join(dir, 'Trimmed');
      final trimmedDir = Directory(dir);
      if (!await trimmedDir.exists()) {
        await trimmedDir.create(recursive: true);
      }
    }
    final ext = path.extension(clip.filePath);
    String cleanName = _exportNameController.text.trim();
    if (cleanName.isEmpty) {
      cleanName = path.basenameWithoutExtension(clip.fileName) + '_trimmed';
    }
    String customOutputPath = path.join(dir, '$cleanName$ext');
    if (!clip.isTrimmed || customOutputPath != clip.trimmedOutputPath) {
      int counter = 1;
      while (File(customOutputPath).existsSync()) {
        counter++;
        customOutputPath = path.join(dir, '$cleanName ($counter)$ext');
      }
    }

    final String? oldTrimmedPath = clip.isTrimmed ? clip.trimmedOutputPath : null;

    // P1-4: Release player file lock if the player is currently playing the file
    // that will be overwritten, to prevent Windows sharing violation
    if (oldTrimmedPath != null && _currentlyLoadedMediaUrl == oldTrimmedPath) {
      try {
        await _player.stop();
        _currentlyLoadedMediaUrl = null;
      } catch (_) {}
    }

    try {
      // Time parameters formatted as HH:MM:SS.xxx
      final startTimeStr = _formatDuration(clip.startCut);
      final endTimeStr = _formatDuration(clip.endCut);

      final result = await VideoTrimmer.trimVideo(
        inputPath: clip.filePath,
        startTime: startTimeStr,
        endTime: endTimeStr,
      );

      // Handle custom rename if needed (VideoTrimmer returns default _trimmed)
      if (result != null && result != customOutputPath) {
        final defaultFile = File(result);
        final customFile = File(customOutputPath);
        if (await customFile.exists()) {
          await customFile.delete();
        }
        // P0-2: Safe cross-drive move — try rename first, fallback to copy+delete
        try {
          await defaultFile.rename(customOutputPath);
        } catch (_) {
          // rename fails across drive boundaries (errno 17), use copy+delete
          await defaultFile.copy(customOutputPath);
          await defaultFile.delete();
        }
      }

      if (result != null) {
        // Delete old trimmed file if path changed to prevent duplication
        if (oldTrimmedPath != null && oldTrimmedPath != customOutputPath) {
          final oldFile = File(oldTrimmedPath);
          if (oldFile.existsSync()) {
            try {
              oldFile.deleteSync();
            } catch (e) {
              debugPrint('Failed to delete old trimmed file: $e');
            }
          }
        }

        setState(() {
          clip.isAnimating = true;
        });

        await Future.delayed(const Duration(milliseconds: 400));

        setState(() {
          clip.isTrimmed = true;
          clip.isAnimating = false;
          clip.trimmedOutputPath = customOutputPath;
          clip.fileName = path.basename(customOutputPath);
          _blacklistedClipNames.add(clip.filePath); // Add to blacklist
        });

        if (_deleteOriginalAfterTrim) {
          setState(() {
            _originalClipsToDelete.add(clip.filePath);
          });
        }

        // Auto-Advance on Trim
        if (_selectedClipIndex < _clips.length - 1) {
          _selectClip(_selectedClipIndex + 1);
        }
      }

      _showSnackBar('Export Success: $customOutputPath');
    } catch (e, stack) {
      LoggerService.logError('Export Failed: $e', stack);
      _showSnackBar('Export Failed: $e', isError: true);
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }

  Future<void> _changeExportDirectory() async {
    try {
      String? selectedDirectory;
      try {
        selectedDirectory = await file_selector.getDirectoryPath();
      } catch (e, stack) {
        LoggerService.logError('file_selector getDirectoryPath error: $e', stack);
      }
      if (selectedDirectory != null) {
        setState(() {
          _customExportDir = selectedDirectory;
        });
      }
    } catch (e) {
      _showSnackBar('Failed to select directory: $e', isError: true);
    }
  }

  String _getExportDirectoryPath(VideoClip? activeClip) {
    if (_customExportDir != null) {
      return _customExportDir!;
    }
    if (activeClip != null) {
      return path.dirname(activeClip.filePath);
    }
    return 'No directory selected';
  }

  @override
  Widget build(BuildContext context) {
    final activeClip = _selectedClipIndex != -1 ? _clips[_selectedClipIndex] : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F16),
      body: DropTarget(
        onDragDone: (detail) {
          if (detail.files.isNotEmpty) {
            _handleDroppedFiles(detail.files.map((f) => f.path).toList());
          }
        },
        onDragEntered: (detail) => setState(() => _isDragging = true),
        onDragExited: (detail) => setState(() => _isDragging = false),
        child: Stack(
          children: [
            Column(
              children: [
                // Top Bar
                _buildTopBar(),
                // P2-5: Removed duplicate LinearProgressIndicator — the bottom bar already has one
                const Divider(height: 1, color: Color(0xFF1E1E2E)),
                
                // Main Content Area
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left Column: Workspaces & Clips (width: 300)
                      _buildLeftSidebar(),
                      const VerticalDivider(width: 1, color: Color(0xFF1E1E2E)),
                      
                      // Middle Column: Large Video Preview & Controls (flexible)
                      Expanded(
                        flex: 5,
                        child: _buildCenterPlayer(activeClip),
                      ),
                      const VerticalDivider(width: 1, color: Color(0xFF1E1E2E)),
                      
                      // Right Column: Small Settings & Export (width: 260)
                      _buildRightSettings(activeClip),
                    ],
                  ),
                ),

                // Bottom Deletion Progress Bar
                if (_isEndingSession)
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF130E14),
                      border: Border(
                        top: BorderSide(
                          color: Colors.redAccent.withOpacity(0.35),
                          width: 1,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          minHeight: 4,
                          value: _totalDeletingFiles > 0
                              ? (_currentDeletedCount / _totalDeletingFiles).clamp(0.0, 1.0)
                              : null,
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF76B900)),
                          backgroundColor: const Color(0xFF1E1E2E),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(Icons.delete_sweep_outlined, size: 16, color: Colors.redAccent),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          _totalDeletingFiles > 0
                                              ? 'Deleting session files: ($_currentDeletedCount/$_totalDeletingFiles) deleted'
                                              : 'Cleaning up session files...',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                        const SizedBox(width: 8),
                                        if (_totalDeletingFiles > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF76B900).withOpacity(0.15),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: const Color(0xFF76B900).withOpacity(0.4), width: 0.8),
                                            ),
                                            child: Text(
                                              '${((_currentDeletedCount / _totalDeletingFiles) * 100).toInt()}%',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF76B900),
                                                fontFamily: 'monospace',
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (_currentDeletingFileName.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        _currentDeletingFileName,
                                        style: const TextStyle(fontSize: 11, color: Colors.white60, fontFamily: 'monospace'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF76B900)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),

            // Toast Floating Notification
            _buildToastNotification(),
          ],
        ),
      ),
    );
  }

  // --- Top Bar Widget ---
  Widget _buildTopBar() {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: const Color(0xFF161622),
      child: Row(
        children: [
          GestureDetector(
            onTap: _showAboutDialog,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  Image.asset('assets/app_icon.png', width: 28, height: 28),
                  const SizedBox(width: 8),
                  RichText(
                    text: const TextSpan(
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5),
                      children: [
                        TextSpan(text: 'Shadow', style: TextStyle(color: Color(0xFF76B900))),
                        TextSpan(text: 'Trim', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (_clips.isNotEmpty)
            TextButton.icon(
              onPressed: _showEndSessionDialog,
              icon: const Icon(Icons.stop_circle_outlined, size: 14, color: Colors.redAccent),
              label: const Text('End Session', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
            ),
        ],
      ),
    );
  }

  // --- Left Sidebar (Clips & Import) ---
  Widget _buildLeftSidebar() {
    return Container(
      width: 290,
      color: const Color(0xFF11111B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Action Buttons (Open File / Open Folder)
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _importFiles,
                    icon: const Icon(Icons.video_library_outlined, size: 14),
                    label: const Text('Open Clip', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E1E2E),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: const BorderSide(color: Color(0xFF2E2E3E)),
                      ),
                    ).copyWith(
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const Color(0xFF252636);
                        }
                        return const Color(0xFF1E1E2E);
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const Color(0xFF76B900);
                        }
                        return Colors.white;
                      }),
                      side: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const BorderSide(color: Color(0xFF76B900), width: 1);
                        }
                        return const BorderSide(color: Color(0xFF2E2E3E));
                      }),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _importFolder,
                    icon: const Icon(Icons.folder_open_outlined, size: 14),
                    label: const Text('Open Folder', style: TextStyle(fontSize: 11)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E1E2E),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: const BorderSide(color: Color(0xFF2E2E3E)),
                      ),
                    ).copyWith(
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const Color(0xFF252636);
                        }
                        return const Color(0xFF1E1E2E);
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const Color(0xFF76B900);
                        }
                        return Colors.white;
                      }),
                      side: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.hovered)) {
                          return const BorderSide(color: Color(0xFF76B900), width: 1);
                        }
                        return const BorderSide(color: Color(0xFF2E2E3E));
                      }),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          
          // Header list label & Sort Menu & Open Folder
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Tooltip(
                    message: _currentWorkspacePath ?? 'No Workspace Open',
                    child: Text(
                      _currentWorkspacePath ?? 'NO WORKSPACE OPEN',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade600, letterSpacing: 0.5),
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_currentWorkspacePath != null) ...[
                      HoverIconButton(
                        icon: Icons.folder_open,
                        size: 14,
                        defaultColor: Colors.grey,
                        hoverColor: const Color(0xFF76B900),
                        tooltip: 'Open Workspace Folder in File Explorer',
                        onPressed: () {
                          if (_currentWorkspacePath != null) {
                            _openInExplorer(_currentWorkspacePath!);
                          }
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.sort, size: 14, color: Colors.grey),
                      tooltip: 'Sort list by...',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onSelected: (val) {
                        setState(() {
                          _sortBy = val;
                          _sortClips();
                        });
                      },
                      color: const Color(0xFF1E1E2E),
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'created_desc',
                          child: Text('Date Created (Newest)', style: TextStyle(fontSize: 11, color: _sortBy == 'created_desc' ? const Color(0xFF76B900) : Colors.white)),
                        ),
                        PopupMenuItem(
                          value: 'created_asc',
                          child: Text('Date Created (Oldest)', style: TextStyle(fontSize: 11, color: _sortBy == 'created_asc' ? const Color(0xFF76B900) : Colors.white)),
                        ),
                        PopupMenuItem(
                          value: 'size_desc',
                          child: Text('File Size (Biggest)', style: TextStyle(fontSize: 11, color: _sortBy == 'size_desc' ? const Color(0xFF76B900) : Colors.white)),
                        ),
                        PopupMenuItem(
                          value: 'size_asc',
                          child: Text('File Size (Smallest)', style: TextStyle(fontSize: 11, color: _sortBy == 'size_asc' ? const Color(0xFF76B900) : Colors.white)),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Clip list
          Expanded(
            child: _clips.isEmpty && _deletedClips.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.upload_file,
                            size: 40,
                            color: Colors.grey.shade600,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Import video or folder files',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade400),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Drag & Drop here',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      _buildHeaderSection('TRIMMED', _getTrimmedClips().length, _trimmedExpanded, () {
                        setState(() => _trimmedExpanded = !_trimmedExpanded);
                      }),
                      if (_trimmedExpanded)
                        ..._getTrimmedClips().map((clip) => _buildClipTile(clip)),
                      const SizedBox(height: 12),
                      _buildHeaderSection('UNTRIMMED', _getUntrimmedClips().length, _untrimmedExpanded, () {
                        setState(() => _untrimmedExpanded = !_untrimmedExpanded);
                      }),
                      if (_untrimmedExpanded)
                        ..._getUntrimmedClips().map((clip) => _buildClipTile(clip)),
                      if (_deletedClips.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _buildDeletedHeaderSection(),
                        if (_deletedExpanded)
                          ..._deletedClips.map((clip) => _buildDeletedClipTile(clip)),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  List<VideoClip> _getUntrimmedClips() {
    return _clips.where((c) => !c.isTrimmed).toList();
  }

  List<VideoClip> _getTrimmedClips() {
    return _clips.where((c) => c.isTrimmed).toList();
  }

  Widget _buildDeletedHeaderSection() {
    return InkWell(
      onTap: () => setState(() => _deletedExpanded = !_deletedExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Icon(
              _deletedExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              size: 14,
              color: Colors.red.shade400,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.delete_sweep_outlined, size: 12, color: Colors.redAccent),
            const SizedBox(width: 5),
            Text(
              'DELETED',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.red.shade400,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.red.shade900.withOpacity(0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${_deletedClips.length}',
                style: TextStyle(fontSize: 9, color: Colors.red.shade300, fontWeight: FontWeight.bold),
              ),
            ),
            const Spacer(),
            Text(
              'on End Session',
              style: TextStyle(fontSize: 9, color: Colors.red.shade700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeletedClipTile(VideoClip clip) {
    return Container(
      height: 50,
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade900.withOpacity(0.3), width: 1),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        leading: SizedBox(
          width: 48,
          height: 36,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix([
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0.2126, 0.7152, 0.0722, 0, 0,
                    0,      0,      0,      1, 0,
                  ]),
                  child: VideoThumbnailWidget(filePath: clip.filePath),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.red.shade800,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.red.shade300, width: 0.5),
                  ),
                  child: const Icon(Icons.delete_outline, size: 9, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        title: Text(
          clip.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Colors.red.shade300, fontWeight: FontWeight.normal),
        ),
        subtitle: Text(
          clip.fileSizeFormatted,
          style: TextStyle(fontSize: 10, color: Colors.red.shade800),
        ),
        trailing: Tooltip(
          message: 'Remove from deletion queue',
          child: GestureDetector(
            onTap: () {
              setState(() {
                _deletedClips.remove(clip);
                _clips.add(clip);
                _sortClips();
              });
            },
            child: const Icon(Icons.undo_outlined, size: 15, color: Colors.grey),
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderSection(String title, int count, bool isExpanded, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Icon(
              isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              size: 14,
              color: Colors.grey.shade500,
            ),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey.shade500, letterSpacing: 0.5),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade400, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClipTile(VideoClip clip) {
    // P1-1: Removed _probeClipMetadata call from build pass — probing is already
    // triggered by _selectClip and during initial import, not during every rebuild.

    final int idx = _clips.indexOf(clip);
    final isSelected = idx == _selectedClipIndex;
    
    final tileKey = _clipKeys.putIfAbsent(clip, () => GlobalKey());
    return AnimatedSlide(
      key: tileKey,
      offset: clip.isAnimating ? const Offset(0.0, -0.8) : Offset.zero,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      child: AnimatedOpacity(
        opacity: clip.isAnimating ? 0.0 : 1.0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          height: clip.isAnimating
              ? 0
              : (clip.isTrimmed && clip.fileName != clip.originalFileName ? 68 : 54),
          margin: clip.isAnimating ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: clip.isAnimating 
              ? const SizedBox.shrink() 
              : SlideInClipTile(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF1E1E2E) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? const Color(0xFF76B900).withOpacity(0.5) : Colors.transparent,
                        width: 1,
                      ),
                    ),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      leading: SizedBox(
                        width: 48,
                        height: 36,
                        child: Stack(
                          children: [
                            Positioned.fill(child: VideoThumbnailWidget(filePath: clip.filePath)),
                            // Red trash icon (bottom-LEFT) if original is flagged for deletion
                            if (_originalClipsToDelete.contains(clip.filePath))
                              Positioned(
                                left: 0,
                                bottom: 0,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade800,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.red.shade300, width: 0.5),
                                  ),
                                  child: const Icon(Icons.delete_outline, size: 9, color: Colors.white),
                                ),
                              ),
                            // Green check icon (bottom-RIGHT) if trimmed
                            if (clip.isTrimmed)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF76B900),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.check, size: 10, color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                      title: isSelected
                          ? MarqueeText(
                              text: clip.fileName,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: clip.isTrimmed
                                    ? const Color(0xFF76B900)
                                    : Colors.white,
                              ),
                            )
                          : Text(
                              clip.fileName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.normal,
                                color: clip.isTrimmed
                                    ? const Color(0xFF76B900)
                                    : Colors.grey.shade300,
                              ),
                            ),
                      subtitle: (clip.isTrimmed && clip.fileName != clip.originalFileName)
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  clip.originalFileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                                ),
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      clip.fileSizeFormatted,
                                      style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                                    ),
                                    Text(
                                      clip.duration != Duration.zero 
                                          ? _formatDuration(clip.duration).split('.')[0]
                                          : 'Loading...',
                                      style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                                    ),
                                  ],
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  clip.fileSizeFormatted,
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                                ),
                                Text(
                                  clip.duration != Duration.zero 
                                      ? _formatDuration(clip.duration).split('.')[0]
                                      : 'Loading...',
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                                ),
                              ],
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // P2-4: Avoid sync disk I/O in build — the original file is available for edit
                          // if it's not flagged for deletion (checked in _originalClipsToDelete set)
                          if (clip.isTrimmed && !_originalClipsToDelete.contains(clip.filePath)) ...[
                            IconButton(
                              icon: const Icon(Icons.edit, size: 14, color: Color(0xFF76B900)),
                              tooltip: 'Edit / Revise',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _selectClip(idx, forceOriginal: true),
                            ),
                            const SizedBox(width: 8),
                          ],
                          HoverIconButton(
                            icon: Icons.folder_open,
                            size: 14,
                            defaultColor: Colors.grey,
                            hoverColor: const Color(0xFF76B900),
                            tooltip: 'Reveal in File Explorer',
                            onPressed: () {
                              final revealPath = (clip.isTrimmed && clip.trimmedOutputPath != null)
                                  ? clip.trimmedOutputPath!
                                  : clip.filePath;
                              _openInExplorer(revealPath, select: true);
                            },
                          ),
                          const SizedBox(width: 4),
                          HoverIconButton(
                            icon: Icons.close,
                            size: 14,
                            defaultColor: Colors.grey,
                            hoverColor: Colors.redAccent,
                            hoverBgColor: Colors.redAccent.withValues(alpha: 0.25),
                            enableSpin: true,
                            tooltip: 'Remove from list',
                            onPressed: () {
                              setState(() {
                                _clips.removeAt(idx);
                                if (_selectedClipIndex == idx) {
                                    _selectedClipIndex = -1;
                                    _player.pause();
                                    if (_clips.isNotEmpty) {
                                      _selectClip(0);
                                    }
                                } else if (_selectedClipIndex > idx) {
                                  _selectedClipIndex--;
                                }
                              });
                            },
                          ),
                        ],
                      ),
                      onTap: () {
                        final fileToLoad = clip.isTrimmed ? (clip.trimmedOutputPath ?? clip.filePath) : clip.filePath;
                        if (!File(fileToLoad).existsSync()) {
                          _showSnackBar('Target file does not exist.', isError: true);
                        } else {
                          _selectClip(idx);
                        }
                      },
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  // --- Center Area (Video Player & Main Timeline) ---
  Widget _buildCenterPlayer(VideoClip? activeClip) {
    if (activeClip == null) {
      return Container(
        color: const Color(0xFF0F0F16),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.movie_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'Import and select a video to start trimming.',
                style: TextStyle(color: Colors.grey),
              ),
              if (_lastSessionWorkspacePath != null) ...[
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => _continueLastSession(_lastSessionWorkspacePath!),
                  icon: const Icon(Icons.restore_outlined, size: 16),
                  label: Text(
                    'Continue last session  (${path.basename(_lastSessionWorkspacePath!)})',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E1E2E),
                    foregroundColor: const Color(0xFF76B900),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: const Color(0xFF76B900).withValues(alpha: 0.5)),
                    ),
                  ).copyWith(
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.hovered)) {
                        return const Color(0xFF27293D);
                      }
                      return const Color(0xFF1E1E2E);
                    }),
                    side: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.hovered)) {
                        return const BorderSide(color: Color(0xFF76B900), width: 1.5);
                      }
                      return BorderSide(color: const Color(0xFF76B900).withValues(alpha: 0.5));
                    }),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final Duration duration = _viewingTrimmedMode
        ? (activeClip.endCut - activeClip.startCut)
        : activeClip.duration;
    final double maxMs = duration.inMilliseconds.toDouble();

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
          if (event.logicalKey == LogicalKeyboardKey.space || event.logicalKey == LogicalKeyboardKey.keyK) {
            if (_player.state.playing) {
              _player.pause();
            } else {
              _player.play();
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            final newPos = _currentPosition - const Duration(seconds: 1);
            _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            final newPos = _currentPosition + const Duration(seconds: 1);
            _player.seek(newPos > duration ? duration : newPos);
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            if (isShiftPressed) {
              setState(() {
                _volume = (_volume + 5.0).clamp(0.0, 100.0);
              });
              _player.setVolume(_volume);
              return KeyEventResult.handled;
            }
            _selectPreviousClip();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            if (isShiftPressed) {
              setState(() {
                _volume = (_volume - 5.0).clamp(0.0, 100.0);
              });
              _player.setVolume(_volume);
              return KeyEventResult.handled;
            }
            _selectNextClip();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyJ) {
            if (isShiftPressed) {
              if (activeClip != null) {
                _player.seek(activeClip.startCut);
              }
              return KeyEventResult.handled;
            } else {
              final newPos = _currentPosition - const Duration(seconds: 5);
              _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
              return KeyEventResult.handled;
            }
          } else if (event.logicalKey == LogicalKeyboardKey.keyL) {
            if (isShiftPressed) {
              if (activeClip != null) {
                _player.seek(activeClip.endCut);
              }
              return KeyEventResult.handled;
            } else {
              final newPos = _currentPosition + const Duration(seconds: 5);
              _player.seek(newPos > duration ? duration : newPos);
              return KeyEventResult.handled;
            }
          } else if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
            if (!_viewingTrimmedMode) {
              _setStartCut();
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
            if (!_viewingTrimmedMode) {
              _setEndCut();
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            if (!_isExporting && activeClip != null) {
              _exportActiveClip();
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyI) {
            if (isShiftPressed) {
              _player.seek(Duration.zero);
            } else {
              if (duration > Duration.zero) {
                _player.seek(Duration(milliseconds: (duration.inMilliseconds * 0.25).toInt()));
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyO) {
            if (duration > Duration.zero) {
              _player.seek(Duration(milliseconds: (duration.inMilliseconds * 0.50).toInt()));
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyP) {
            if (isShiftPressed) {
              _player.seek(duration);
            } else {
              if (duration > Duration.zero) {
                _player.seek(Duration(milliseconds: (duration.inMilliseconds * 0.75).toInt()));
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.keyM) {
            _toggleMute();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.comma) {
            if (isShiftPressed) {
              _changeSpeed(false);
              return KeyEventResult.handled;
            }
          } else if (event.logicalKey == LogicalKeyboardKey.period) {
            if (isShiftPressed) {
              _changeSpeed(true);
              return KeyEventResult.handled;
            }
          } else if (event.logicalKey == LogicalKeyboardKey.delete) {
            if (activeClip != null && !_isExporting) {
              _confirmDeleteFile(activeClip);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.f2) {
            if (activeClip != null) {
              _exportNameFocusNode.requestFocus();
              _exportNameController.selection = TextSelection(
                baseOffset: 0,
                extentOffset: _exportNameController.text.length,
              );
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.f12 ||
              (event.logicalKey == LogicalKeyboardKey.keyI &&
                  isShiftPressed &&
                  HardwareKeyboard.instance.isControlPressed)) {
            setState(() {
              debugPaintSizeEnabled = !debugPaintSizeEnabled;
            });
            _showSnackBar(
              debugPaintSizeEnabled
                  ? 'Inspect Bounding Box Enabled (F12)'
                  : 'Inspect Bounding Box Disabled',
            );
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: const Color(0xFF0B0B0F),
        child: Column(
          children: [
            // Large Video Container
            Expanded(
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: () {
                          if (_isImporting) return;
                          if (_player.state.playing) {
                            _player.pause();
                          } else {
                            _player.play();
                          }
                          _focusNode.requestFocus();
                        },
                        child: Video(
                          controller: _controller,
                          controls: NoVideoControls,
                        ),
                      ),
                    ),
                    if (_isImporting)
                      Positioned.fill(
                        child: Container(
                          color: const Color(0xE60D0E15),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
                              decoration: BoxDecoration(
                                color: const Color(0xFF14151F),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFF76B900).withValues(alpha: 0.3),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.5),
                                    blurRadius: 20,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const SizedBox(
                                    width: 42,
                                    height: 42,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 3.5,
                                      color: Color(0xFF76B900),
                                      backgroundColor: Color(0xFF222433),
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  Text(
                                    _importProgressStatus.isNotEmpty ? _importProgressStatus : 'Importing workspace folder...',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Parsing video clips & building thumbnail cache',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Timeline & Trim Controls Area
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF11111B),
              child: Column(
                children: [
                  // Cut Duration Details Row
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _formatDuration(_currentPosition),
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'START: ${_formatDuration(activeClip.startCut)}',
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFF76B900)),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'END: ${_formatDuration(activeClip.endCut)}',
                            style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.redAccent),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          'DURATION AFTER CUT: ${_formatDuration(activeClip.endCut - activeClip.startCut)}',
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Aligned Sliders - both use same horizontal inset (8px = bracket half-width)
                  if (maxMs > 0)
                    Column(
                      children: [
                        // Playhead slider — overlay radius set to 8 to match RangeSlider bracket half-width
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2,
                            activeTrackColor: Colors.grey.shade400,
                            inactiveTrackColor: Colors.grey.shade800,
                            thumbColor: Colors.white,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            // Key: set overlay to same 8px as bracket thumb half-width
                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                            trackShape: const AlignedSliderTrackShape(),
                          ),
                          child: Slider(
                            min: 0,
                            max: maxMs,
                            value: _draggingPositionMs ?? _currentPosition.inMilliseconds.toDouble().clamp(0.0, maxMs),
                            onChanged: (val) {
                              setState(() {
                                _draggingPositionMs = val;
                              });
                              final now = DateTime.now();
                              if (_lastSeekTime == null || now.difference(_lastSeekTime!) > const Duration(milliseconds: 150)) {
                                _lastSeekTime = now;
                                _player.seek(Duration(milliseconds: val.toInt()));
                              }
                            },
                            onChangeEnd: (val) {
                              _player.seek(Duration(milliseconds: val.toInt()));
                              setState(() {
                                _draggingPositionMs = null;
                              });
                            },
                          ),
                        ),
                        // Range Selector Slider — bracket thumb half-width = 8px (matches overlay above)
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 6,
                            activeTrackColor: _viewingTrimmedMode ? Colors.grey.shade700 : const Color(0xFF76B900),
                            inactiveTrackColor: Colors.grey.shade900,
                            thumbColor: _viewingTrimmedMode ? Colors.grey.shade600 : const Color(0xFF76B900),
                            rangeThumbShape: const BracketRangeSliderThumbShape(),
                            overlayShape: SliderComponentShape.noOverlay,
                            rangeTrackShape: const AlignedRangeSliderTrackShape(),
                          ),
                          child: RangeSlider(
                            min: 0,
                            max: maxMs,
                            values: RangeValues(
                              _viewingTrimmedMode ? 0.0 : activeClip.startCut.inMilliseconds.toDouble().clamp(0.0, maxMs),
                              _viewingTrimmedMode ? maxMs : activeClip.endCut.inMilliseconds.toDouble().clamp(0.0, maxMs),
                            ),
                            onChanged: _viewingTrimmedMode ? null : (RangeValues vals) {
                              setState(() {
                                activeClip.startCut = Duration(milliseconds: vals.start.toInt());
                                activeClip.endCut = Duration(milliseconds: vals.end.toInt());
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),

                  // Player Operations Row
                  Row(
                    children: [
                      // Start cut shortcuts (Left Aligned)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _viewingTrimmedMode ? null : _setStartCut,
                                icon: Text(
                                  '[',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: _viewingTrimmedMode ? Colors.grey : const Color(0xFF76B900),
                                  ),
                                ),
                                label: const Text('Set Start', style: TextStyle(fontSize: 11)),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: _viewingTrimmedMode ? Colors.grey.withOpacity(0.3) : const Color(0xFF76B900).withOpacity(0.5)),
                                  foregroundColor: _viewingTrimmedMode ? Colors.grey : Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _viewingTrimmedMode ? null : _setEndCut,
                                icon: Text(
                                  ']',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: _viewingTrimmedMode ? Colors.grey : Colors.redAccent,
                                  ),
                                ),
                                label: const Text('Set End', style: TextStyle(fontSize: 11)),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(color: _viewingTrimmedMode ? Colors.grey.withOpacity(0.3) : Colors.redAccent.withOpacity(0.5)),
                                  foregroundColor: _viewingTrimmedMode ? Colors.grey : Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Center Control Buttons (Absolutely Centered)
                      Expanded(
                        child: Align(
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.first_page, color: Color(0xFF76B900)),
                                tooltip: 'Jump to Start Cut (Shift+J)',
                                hoverColor: const Color(0xFF76B900).withValues(alpha: 0.15),
                                onPressed: () {
                                  if (activeClip != null) {
                                    _player.seek(activeClip.startCut);
                                  }
                                },
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.replay_5, color: Colors.grey),
                                tooltip: 'Seek -5s (J)',
                                hoverColor: Colors.white12,
                                onPressed: () {
                                  final newPos = _currentPosition - const Duration(seconds: 5);
                                  _player.seek(newPos < Duration.zero ? Duration.zero : newPos);
                                },
                              ),
                              const SizedBox(width: 8),
                              Container(
                                decoration: const BoxDecoration(
                                  color: Color(0xFF76B900),
                                  shape: BoxShape.circle,
                                ),
                                child: StreamBuilder<bool>(
                                  stream: _player.stream.playing,
                                  builder: (context, snapshot) {
                                    final isPlaying = snapshot.data ?? false;
                                    return IconButton(
                                      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                                      hoverColor: Colors.white24,
                                      onPressed: () {
                                        if (isPlaying) {
                                          _player.pause();
                                        } else {
                                          _player.play();
                                        }
                                      },
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.forward_5, color: Colors.grey),
                                tooltip: 'Seek +5s (L)',
                                hoverColor: Colors.white12,
                                onPressed: () {
                                  final newPos = _currentPosition + const Duration(seconds: 5);
                                  _player.seek(newPos > duration ? duration : newPos);
                                },
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.last_page, color: Colors.redAccent),
                                tooltip: 'Jump to End Cut (Shift+L)',
                                hoverColor: Colors.redAccent.withValues(alpha: 0.15),
                                onPressed: () {
                                  if (activeClip != null) {
                                    _player.seek(activeClip.endCut);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Volume & Speed Control (Right Aligned)
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Playback speed selector with hover effect & 0.25x support
                              PopupMenuButton<double>(
                                tooltip: 'Playback Speed (< or >)',
                                offset: const Offset(0, -195),
                                borderRadius: BorderRadius.circular(6),
                                color: const Color(0xFF1E1E2E),
                                child: Ink(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF161622),
                                    border: Border.all(color: Colors.grey.shade800),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(4),
                                    hoverColor: const Color(0xFF76B900).withValues(alpha: 0.15),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                                      child: Text(
                                        _playbackSpeed == 0.25
                                            ? '0.25x'
                                            : '${_playbackSpeed.toStringAsFixed(_playbackSpeed % 1 == 0 ? 0 : 1)}x',
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70),
                                      ),
                                    ),
                                  ),
                                ),
                                onSelected: (speed) {
                                  setState(() {
                                    _playbackSpeed = speed;
                                  });
                                  _player.setRate(speed);
                                },
                                itemBuilder: (context) => _availablePlaybackSpeeds.map((speed) => PopupMenuItem<double>(
                                  value: speed,
                                  child: Text(
                                    speed == 0.25 ? '0.25x' : '${speed.toStringAsFixed(speed % 1 == 0 ? 0 : 1)}x',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: _playbackSpeed == speed ? FontWeight.bold : FontWeight.normal,
                                      color: _playbackSpeed == speed ? const Color(0xFF76B900) : Colors.white,
                                    ),
                                  ),
                                )).toList(),
                              ),
                              const SizedBox(width: 10),
                              HoverIconButton(
                                icon: _volume == 0 ? Icons.volume_off : (_volume < 50 ? Icons.volume_down : Icons.volume_up),
                                size: 15,
                                defaultColor: _volume == 0 ? Colors.redAccent : Colors.grey.shade400,
                                hoverColor: const Color(0xFF76B900),
                                tooltip: _volume == 0 ? 'Unmute (M)' : 'Mute (M)',
                                onPressed: _toggleMute,
                              ),
                              const SizedBox(width: 4),
                              SizedBox(
                                width: 80,
                                child: SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 2,
                                    activeTrackColor: const Color(0xFF76B900),
                                    inactiveTrackColor: Colors.grey.shade800,
                                    thumbColor: Colors.white,
                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
                                  ),
                                  child: Slider(
                                    min: 0,
                                    max: 100,
                                    value: _volume.clamp(0.0, 100.0),
                                    onChanged: (val) {
                                      setState(() {
                                        _volume = val;
                                      });
                                      _player.setVolume(val);
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Right Settings Panel (Small Export Panel) ---
  Widget _buildRightSettings(VideoClip? activeClip) {
    return Container(
      width: 250,
      color: const Color(0xFF11111B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top scrollable settings & metadata area
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'TRIMMING & METADATA',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  
                  // Export name input
                  const Text(
                    'Export File Name',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _exportNameController,
                    focusNode: _exportNameFocusNode,
                    enabled: activeClip != null,
                    style: const TextStyle(fontSize: 12),
                    onSubmitted: (_) {
                      _focusNode.requestFocus();
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      filled: true,
                      fillColor: const Color(0xFF1E1E2E),
                      hintText: 'Enter file name',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none,
                      ),
                      suffixText: activeClip != null ? path.extension(activeClip.filePath) : '',
                      suffixStyle: const TextStyle(color: Colors.grey, fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Destination Info Card
                  const Text(
                    'Export Destination',
                    style: TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                  const SizedBox(height: 6),
                  InkWell(
                    onTap: _changeExportDirectory,
                    mouseCursor: SystemMouseCursors.click,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E2E),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _customExportDir != null ? const Color(0xFF76B900).withValues(alpha: 0.5) : Colors.transparent,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_open, size: 16, color: Color(0xFF76B900)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _getExportDirectoryPath(activeClip),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10, color: Colors.grey.shade400, fontFamily: 'monospace'),
                            ),
                          ),
                          if (activeClip != null || _customExportDir != null)
                            HoverIconButton(
                              icon: Icons.open_in_new,
                              size: 14,
                              defaultColor: Colors.grey,
                              hoverColor: const Color(0xFF76B900),
                              tooltip: 'Open in File Explorer',
                              onPressed: () {
                                final dir = _getExportDirectoryPath(activeClip);
                                _openInExplorer(dir);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_customExportDir != null) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: InkWell(
                        onTap: () => setState(() => _customExportDir = null),
                        mouseCursor: SystemMouseCursors.click,
                        child: const Text(
                          'Reset to source folder',
                          style: TextStyle(fontSize: 10, color: Colors.grey, decoration: TextDecoration.underline),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),

                  // Automatically add Trimmed folder checkbox
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _autoCreateTrimmedFolder = !_autoCreateTrimmedFolder;
                        });
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: Checkbox(
                              value: _autoCreateTrimmedFolder,
                              activeColor: const Color(0xFF76B900),
                              onChanged: (val) {
                                setState(() {
                                  _autoCreateTrimmedFolder = val ?? false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Automatically add "Trimmed" folder',
                              style: TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Delete original clip after trim checkbox
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _deleteOriginalAfterTrim = !_deleteOriginalAfterTrim;
                        });
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: Checkbox(
                              value: _deleteOriginalAfterTrim,
                              activeColor: Colors.redAccent,
                              onChanged: (val) {
                                setState(() {
                                  _deleteOriginalAfterTrim = val ?? false;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Delete original clip after trim',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _deleteOriginalAfterTrim ? Colors.redAccent : Colors.white70,
                                    fontWeight: _deleteOriginalAfterTrim ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                                if (_deleteOriginalAfterTrim)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.warning_amber_rounded, size: 11, color: Colors.redAccent),
                                        const SizedBox(width: 4),
                                        const Flexible(
                                          child: Text(
                                            "You can't revise the clip after ending the session!",
                                            style: TextStyle(fontSize: 9, color: Colors.redAccent),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Metadata Information Card (Collapsible, Open by default)
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2E),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade900, width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => setState(() => _isMetadataExpanded = !_isMetadataExpanded),
                          mouseCursor: SystemMouseCursors.click,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline, color: Color(0xFF76B900), size: 15),
                                const SizedBox(width: 6),
                                const Expanded(
                                  child: Text(
                                    'METADATA INFORMATION',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF76B900)),
                                  ),
                                ),
                                Icon(
                                  _isMetadataExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: const Color(0xFF76B900),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isMetadataExpanded)
                          Padding(
                            padding: const EdgeInsets.only(left: 10, right: 10, bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Divider(height: 1, color: Color(0xFF2E2E3E)),
                                const SizedBox(height: 8),
                                if (activeClip != null) ...[
                                  _buildMetadataRow('File', activeClip.fileName),
                                  if (activeClip.fileName != activeClip.originalFileName)
                                    _buildMetadataRow('Original File', activeClip.originalFileName),
                                  _buildMetadataRow('Format', path.extension(activeClip.filePath).toUpperCase().replaceAll('.', '')),
                                  _buildMetadataRow('Duration', _formatDuration(activeClip.duration).split('.')[0]),
                                  _buildMetadataRow('Size', activeClip.fileSizeFormatted),
                                  _buildMetadataRow('Quality', activeClip.qualityString),
                                  FutureBuilder<FileStat>(
                                    future: File(activeClip.filePath).stat(),
                                    builder: (context, snapshot) {
                                      if (snapshot.hasData) {
                                        final stat = snapshot.data!;
                                        final modifiedStr = stat.modified.toString().split('.')[0];
                                        return _buildMetadataRow('Modified', modifiedStr);
                                      }
                                      return const SizedBox.shrink();
                                    },
                                  ),
                                ] else
                                  const Text(
                                    'No video selected',
                                    style: TextStyle(fontSize: 10, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Shortcuts Card (Collapsible, Collapsed by default)
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E2E),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade900, width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => setState(() => _isShortcutsExpanded = !_isShortcutsExpanded),
                          mouseCursor: SystemMouseCursors.click,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                const Icon(Icons.keyboard_outlined, color: Color(0xFF76B900), size: 16),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'SHORTCUTS',
                                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF76B900)),
                                  ),
                                ),
                                Icon(
                                  _isShortcutsExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                  size: 16,
                                  color: const Color(0xFF76B900),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isShortcutsExpanded)
                          const Padding(
                            padding: EdgeInsets.only(left: 10, right: 10, bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Divider(height: 1, color: Color(0xFF2E2E3E)),
                                SizedBox(height: 8),
                                _ShortcutRow(keys: 'K / Space', desc: 'Play / Pause'),
                                _ShortcutRow(keys: 'Arrow Left / Right', desc: 'Seek 1s'),
                                _ShortcutRow(keys: 'J / L', desc: 'Seek 5s'),
                                _ShortcutRow(keys: 'Shift + J', desc: 'Jump to Start Cut'),
                                _ShortcutRow(keys: 'Shift + L', desc: 'Jump to End Cut'),
                                _ShortcutRow(keys: '[ / ]', desc: 'Set Start / End Cut'),
                                _ShortcutRow(keys: 'Arrow Up / Down', desc: 'Prev / Next Video'),
                                _ShortcutRow(keys: 'Shift + Up / Down', desc: 'Volume Up / Down'),
                                _ShortcutRow(keys: 'M', desc: 'Mute / Unmute'),
                                _ShortcutRow(keys: 'i / o / p', desc: 'Jump to 25% / 50% / 75%'),
                                _ShortcutRow(keys: 'Shift + i / p', desc: 'Jump to Start / End'),
                                _ShortcutRow(keys: 'Shift + < / >', desc: 'Playback Rate Down / Up'),
                                _ShortcutRow(keys: 'Enter', desc: 'Execute Trim'),
                                _ShortcutRow(keys: 'F2', desc: 'Rename Export File'),
                                _ShortcutRow(keys: 'F12 / Ctrl+Shift+I', desc: 'Inspect Bounding Box'),
                                _ShortcutRow(keys: 'Del', desc: 'Delete Selected Clip'),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const Divider(height: 1, color: Color(0xFF1E1E2E)),

          // Bottom pinned action buttons area
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isExporting)
                  Column(
                    children: [
                      const LinearProgressIndicator(color: Color(0xFF76B900), backgroundColor: Color(0xFF1E1E2E)),
                      const SizedBox(height: 8),
                      Text(_exportStatus, style: const TextStyle(fontSize: 10, color: Colors.grey), textAlign: TextAlign.center),
                    ],
                  )
                else
                  ElevatedButton.icon(
                    onPressed: activeClip != null ? _exportActiveClip : null,
                    icon: const Icon(Icons.cut_outlined, size: 16),
                    label: const Text('Trim!', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF76B900),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      disabledBackgroundColor: Colors.grey.shade800,
                    ),
                  ),
                const SizedBox(height: 8),
                // Delete Files button with 1080 deg spin animation on hover
                SpinningDeleteButton(
                  onPressed: activeClip != null ? () => _confirmDeleteFile(activeClip!) : null,
                ),
                const SizedBox(height: 10),
                Center(
                  child: InkWell(
                    onTap: _showAboutDialog,
                    mouseCursor: SystemMouseCursors.click,
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        'Created by ZFanz',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(width: 8),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: MarqueeText(
                text: value,
                style: const TextStyle(fontSize: 10, color: Colors.white70, fontFamily: 'monospace'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SlideInClipTile extends StatefulWidget {
  final Widget child;
  const SlideInClipTile({super.key, required this.child});

  @override
  State<SlideInClipTile> createState() => _SlideInClipTileState();
}

class _SlideInClipTileState extends State<SlideInClipTile> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacityAnimation;
  late final Animation<Offset> _offsetAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _opacityAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _offsetAnimation = Tween<Offset>(
      begin: const Offset(0.0, -0.4),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacityAnimation,
      child: SlideTransition(
        position: _offsetAnimation,
        child: widget.child,
      ),
    );
  }
}

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const MarqueeText({super.key, required this.text, required this.style});

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _startScrolling() async {
    if (!mounted) return;
    // Wait for frame rendering to get accurate metrics
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      while (mounted) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        if (!_scrollController.hasClients) return;
        await _scrollController.animateTo(
          maxScroll,
          duration: Duration(milliseconds: (maxScroll * 35).toInt().clamp(1000, 20000)),
          curve: Curves.linear,
        );
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        if (!_scrollController.hasClients) return;
        await _scrollController.animateTo(
          0,
          duration: Duration(milliseconds: (maxScroll * 35).toInt().clamp(1000, 20000)),
          curve: Curves.linear,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Text(
          widget.text,
          style: widget.style,
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final String keys;
  final String desc;
  const _ShortcutRow({required this.keys, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(keys, style: const TextStyle(fontSize: 9, color: Color(0xFF76B900), fontFamily: 'monospace')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              desc,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class BracketRangeSliderThumbShape extends RangeSliderThumbShape {
  const BracketRangeSliderThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(16, 24);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool? isOnTop,
    required SliderThemeData sliderTheme,
    TextDirection textDirection = TextDirection.ltr,
    Thumb thumb = Thumb.start,
    bool isPressed = false,
  }) {
    final Canvas canvas = context.canvas;
    final Color enabledColor = thumb == Thumb.start
        ? (sliderTheme.thumbColor ?? const Color(0xFF76B900))
        : Colors.redAccent;
    final Color disabledColor = Colors.grey.shade700;
    final Color color = Color.lerp(disabledColor, enabledColor, enableAnimation.value)!;

    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    if (thumb == Thumb.start) {
      // Draw '[': top bar, vertical bar, bottom bar
      final p = Path();
      p.moveTo(center.dx + 4, center.dy - 10);
      p.lineTo(center.dx - 2, center.dy - 10);
      p.lineTo(center.dx - 2, center.dy + 10);
      p.lineTo(center.dx + 4, center.dy + 10);
      canvas.drawPath(p, paint);
    } else {
      // Draw ']': top bar, vertical bar, bottom bar
      final p = Path();
      p.moveTo(center.dx - 4, center.dy - 10);
      p.lineTo(center.dx + 2, center.dy - 10);
      p.lineTo(center.dx + 2, center.dy + 10);
      p.lineTo(center.dx - 4, center.dy + 10);
      canvas.drawPath(p, paint);
    }
  }
}

/// Custom track shape for the playhead Slider — forces exactly 8px horizontal inset
/// so the track visually aligns with the RangeSlider's BracketRangeSliderThumbShape (half-width = 8px).
class AlignedSliderTrackShape extends RoundedRectSliderTrackShape {
  const AlignedSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double inset = 8.0;
    final double trackHeight = sliderTheme.trackHeight ?? 2.0;
    final double trackLeft = offset.dx + inset;
    final double trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width - 2 * inset;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

/// Custom range track shape for the RangeSlider — forces exactly 8px horizontal inset
/// to perfectly match AlignedSliderTrackShape above.
class AlignedRangeSliderTrackShape extends RoundedRectRangeSliderTrackShape {
  const AlignedRangeSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double inset = 8.0;
    final double trackHeight = sliderTheme.trackHeight ?? 6.0;
    final double trackLeft = offset.dx + inset;
    final double trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width - 2 * inset;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}

/// Displays a lightweight JPEG thumbnail extracted via FFmpeg image cache.
/// Zero native Player instances — prevents 0x8001010e COM thread crash and folder switching lag.
class VideoThumbnailWidget extends StatefulWidget {
  final String filePath;
  const VideoThumbnailWidget({super.key, required this.filePath});

  @override
  State<VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<VideoThumbnailWidget> {
  late Future<File?> _thumbnailFuture;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = VideoTrimmer.generateThumbnail(widget.filePath);
  }

  @override
  void didUpdateWidget(VideoThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _thumbnailFuture = VideoTrimmer.generateThumbnail(widget.filePath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: FutureBuilder<File?>(
        future: _thumbnailFuture,
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.file(
              snapshot.data!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            );
          }
          return Container(
            color: const Color(0xFF1A1A2E),
            child: const Center(
              child: Icon(Icons.video_file_outlined, size: 16, color: Colors.grey),
            ),
          );
        },
      ),
    );
  }
}

class HoverIconButton extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color defaultColor;
  final Color hoverColor;
  final Color? hoverBgColor;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool enableSpin;

  const HoverIconButton({
    super.key,
    required this.icon,
    this.size = 14,
    this.defaultColor = Colors.grey,
    this.hoverColor = const Color(0xFF76B900),
    this.hoverBgColor,
    this.tooltip,
    this.onPressed,
    this.enableSpin = false,
  });

  @override
  State<HoverIconButton> createState() => _HoverIconButtonState();
}

class _HoverIconButtonState extends State<HoverIconButton> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  void _onHover(bool isHovered) {
    setState(() {
      _isHovered = isHovered;
    });
    if (widget.enableSpin && isHovered) {
      _spinController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveHoverBg = widget.hoverBgColor ?? widget.hoverColor.withValues(alpha: 0.2);

    Widget iconWidget = Icon(
      widget.icon,
      size: widget.size,
      color: _isHovered ? widget.hoverColor : widget.defaultColor,
    );

    if (widget.enableSpin) {
      iconWidget = RotationTransition(
        turns: Tween<double>(begin: 0.0, end: 0.5).animate(
          CurvedAnimation(parent: _spinController, curve: Curves.easeOutCubic),
        ),
        child: iconWidget,
      );
    }

    Widget result = MouseRegion(
      cursor: widget.onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isHovered ? effectiveHoverBg : Colors.transparent,
          ),
          child: iconWidget,
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}

class SpinningDeleteButton extends StatefulWidget {
  final VoidCallback? onPressed;
  const SpinningDeleteButton({super.key, this.onPressed});

  @override
  State<SpinningDeleteButton> createState() => _SpinningDeleteButtonState();
}

class _SpinningDeleteButtonState extends State<SpinningDeleteButton> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late final AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onPressed != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        setState(() => _isHovered = true);
        if (widget.onPressed != null) {
          _spinController.forward(from: 0.0);
        }
      },
      onExit: (_) => setState(() => _isHovered = false),
      child: ElevatedButton.icon(
        onPressed: widget.onPressed,
        icon: RotationTransition(
          turns: Tween<double>(begin: 0.0, end: 3.0).animate(
            CurvedAnimation(parent: _spinController, curve: Curves.easeOutCubic),
          ),
          child: Icon(
            Icons.delete_forever_outlined,
            size: 16,
            color: _isHovered ? Colors.redAccent : Colors.redAccent.withValues(alpha: 0.8),
          ),
        ),
        label: Text(
          'Delete Clip',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: _isHovered ? Colors.white : Colors.redAccent,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isHovered ? const Color(0xFF3D1622) : const Color(0xFF2A1520),
          elevation: _isHovered ? 2 : 0,
          padding: const EdgeInsets.symmetric(vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(
              color: _isHovered ? Colors.redAccent : Colors.redAccent.withValues(alpha: 0.5),
              width: _isHovered ? 1.5 : 1.0,
            ),
          ),
          disabledBackgroundColor: Colors.grey.shade900,
        ),
      ),
    );
  }
}

