import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../models/clip_model.dart';
import '../services/video_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  // Tabs
  bool _isFolderMode = false;
  bool _deleteOriginalAfterTrim = false;
  bool _viewingTrimmedMode = false;
  final Set<String> _blacklistedClipNames = {};
  final Set<String> _originalClipsToDelete = {};

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
  String _sortBy = 'created_desc'; // 'created_desc', 'created_asc'
  double _volume = 100.0;
  double _lastVolume = 100.0;
  double _playbackSpeed = 1.0;
  double? _draggingPositionMs;
  DateTime? _lastSeekTime;
  final Map<VideoClip, GlobalKey> _clipKeys = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode();
    _exportNameFocusNode = FocusNode();
    _player = Player();
    _controller = VideoController(_player);

    // Track volume position
    _player.stream.volume.listen((vol) {
      if (mounted) {
        setState(() {
          _volume = vol;
        });
      }
    });

    // Track playhead position
    _player.stream.position.listen((pos) {
      if (mounted) {
        setState(() {
          _currentPosition = pos;
        });
      }
    });

    // Automatically update duration when video is loaded
    _player.stream.duration.listen((duration) {
      if (duration != null && duration > Duration.zero && _selectedClipIndex != -1) {
        final currentClip = _clips[_selectedClipIndex];
        if (currentClip.duration == Duration.zero) {
          setState(() {
            currentClip.duration = duration;
            currentClip.endCut = duration;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _exportNameController.dispose();
    _focusNode.dispose();
    _exportNameFocusNode.dispose();
    super.dispose();
  }

  // Load a video clip into the player
  void _selectClip(int index, {bool forceOriginal = false}) {
    if (index < 0 || index >= _clips.length) return;
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
    _player.open(Media(loadPath), play: false);
    _player.setRate(_playbackSpeed);

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
    }

    if (selectedClip != null) {
      _selectedClipIndex = _clips.indexOf(selectedClip);
    }
  }

  void _selectPreviousClip() {
    if (_selectedClipIndex > 0) {
      _selectClip(_selectedClipIndex - 1);
    }
  }

  void _selectNextClip() {
    if (_selectedClipIndex >= 0 && _selectedClipIndex < _clips.length - 1) {
      _selectClip(_selectedClipIndex + 1);
    }
  }

  // Import files
  Future<void> _importFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp4', 'mkv', 'avi', 'mov'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final firstPath = result.files.first.path;
        if (firstPath != null) {
          _currentWorkspacePath = path.dirname(firstPath);
          await _loadSessionBlacklist();
        }

        List<VideoClip> newClips = [];
        for (var file in result.files) {
          if (file.path != null) {
            final clip = await VideoClip.fromPath(file.path!);
            newClips.add(clip);
          }
        }

        setState(() {
          _clips.clear();
          _selectedClipIndex = -1;
          _clips.addAll(newClips);
          _sortClips();
        });
        await _restoreSessionData();
        setState(() {
          _sortClips();
          if (_clips.isNotEmpty) _selectClip(0);
        });
      }
    } catch (e) {
      _showSnackBar('Failed to import files: $e', isError: true);
    }
  }

  // Import Folder
  Future<void> _importFolder() async {
    try {
      String? directoryPath = await FilePicker.platform.getDirectoryPath();

      if (directoryPath != null) {
        _currentWorkspacePath = directoryPath;
        await _loadSessionBlacklist();

        final dir = Directory(directoryPath);
        final List<FileSystemEntity> entities = await dir.list().toList();
        
        List<VideoClip> newClips = [];
        for (var entity in entities) {
          if (entity is File) {
            final ext = path.extension(entity.path).toLowerCase();
            if (['.mp4', '.mkv', '.avi', '.mov'].contains(ext)) {
              final clip = await VideoClip.fromPath(entity.path);
              newClips.add(clip);
            }
          }
        }

        if (newClips.isEmpty) {
          _showSnackBar('No valid video files found in the selected folder.', isError: false);
          return;
        }

        setState(() {
          _clips.clear();
          _selectedClipIndex = -1;
          _clips.addAll(newClips);
          _sortClips();
        });
        await _restoreSessionData();
        setState(() {
          _sortClips();
          if (_clips.isNotEmpty) _selectClip(0);
        });
      }
    } catch (e) {
      _showSnackBar('Failed to import folder: $e', isError: true);
    }
  }

  void _handleDroppedFiles(List<String> filePaths) async {
    if (filePaths.isNotEmpty) {
      _currentWorkspacePath = path.dirname(filePaths.first);
      await _loadSessionBlacklist();
    }

    List<VideoClip> newClips = [];
    for (var filePath in filePaths) {
      final ext = path.extension(filePath).toLowerCase();
      if (['.mp4', '.mkv', '.avi', '.mov'].contains(ext)) {
        final clip = await VideoClip.fromPath(filePath);
        newClips.add(clip);
      }
    }

    if (newClips.isNotEmpty) {
      setState(() {
        _clips.clear();
        _selectedClipIndex = -1;
        _clips.addAll(newClips);
        _sortClips();
      });
      await _restoreSessionData();
      setState(() {
        _sortClips();
        if (_clips.isNotEmpty) _selectClip(0);
      });
    } else {
      _showSnackBar('No valid video files dropped.', isError: true);
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

  void _showSnackBar(String message, {bool isError = false, bool isDelete = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: (isError || isDelete) ? Colors.red.shade800 : Colors.green.shade800,
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

  void _changeSpeed(bool increase) {
    final List<double> speeds = [1.0, 1.5, 2.0, 3.0];
    int index = speeds.indexOf(_playbackSpeed);
    if (index == -1) index = 0;

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
      final escapedPath = filePath.replaceAll('"', '`"');
      final cmd = 'Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("$escapedPath", "OnlyErrorDialogs", "SendToRecycleBin")';
      final res = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', cmd]);
      if (res.exitCode != 0) {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<File> _getBlacklistFile() async {
    if (_currentWorkspacePath != null) {
      return File(path.join(_currentWorkspacePath!, '.shadowtrim_blacklist.json'));
    }
    final docDir = await getApplicationDocumentsDirectory();
    return File(path.join(docDir.path, 'shadowtrim_global_blacklist.json'));
  }

  Future<void> _saveSessionBlacklist() async {
    try {
      final file = await _getBlacklistFile();
      final jsonString = jsonEncode(_blacklistedClipNames.toList());
      await file.writeAsString(jsonString);
    } catch (e) {
      debugPrint('Failed to save blacklist: $e');
    }
  }

  Future<void> _deleteSessionBlacklist() async {
    try {
      final file = await _getBlacklistFile();
      if (await file.exists()) {
        await file.delete();
      }
      setState(() {
        _blacklistedClipNames.clear();
      });
    } catch (e) {
      debugPrint('Failed to delete blacklist: $e');
    }
  }

  Future<void> _loadSessionBlacklist() async {
    try {
      final file = await _getBlacklistFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> list = jsonDecode(content);
        setState(() {
          _blacklistedClipNames.clear();
          _blacklistedClipNames.addAll(list.cast<String>());
        });
      }
    } catch (e) {
      debugPrint('Failed to load blacklist: $e');
    }
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
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx, 'cancel'),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
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
                        'You have active items in this session.',
                        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Do you want to save the session? Saving will remember previously trimmed clips so they do not reappear next time.',
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
                          child: const Text('Save', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
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
      }).toList();
      await file.writeAsString(jsonEncode({'clips': clipData}));
    } catch (e) {
      debugPrint('Failed to save session data: $e');
    }
  }

  Future<void> _restoreSessionData() async {
    try {
      final file = await _getSessionFile();
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final Map<String, dynamic> json = jsonDecode(content);
      final List<dynamic> savedClips = json['clips'] ?? [];
      final Map<String, Map<String, dynamic>> byPath = {
        for (final c in savedClips) (c['filePath'] as String): c as Map<String, dynamic>
      };
      setState(() {
        for (final clip in _clips) {
          final saved = byPath[clip.filePath];
          if (saved != null) {
            clip.fileName = saved['fileName'] as String? ?? clip.fileName;
            clip.isTrimmed = saved['isTrimmed'] as bool? ?? false;
            clip.trimmedOutputPath = saved['trimmedOutputPath'] as String?;
            clip.startCut = Duration(milliseconds: (saved['startCutMs'] as int?) ?? 0);
            clip.endCut = Duration(milliseconds: (saved['endCutMs'] as int?) ?? 0);
            if (clip.isTrimmed) _blacklistedClipNames.add(clip.filePath);
          }
        }
      });
    } catch (e) {
      debugPrint('Failed to restore session data: $e');
    }
  }

  Future<void> _deleteSessionData() async {
    try {
      final file = await _getSessionFile();
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('Failed to delete session data: $e');
    }
  }

  // ── End Session Dialog (from button in top bar) ───────────────────────────

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
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx, false),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
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
      await _deleteQueuedOriginalFiles();
      await _deleteSessionBlacklist();
      await _deleteSessionData();
      setState(() {
        _clips.clear();
        _selectedClipIndex = -1;
        _blacklistedClipNames.clear();
      });
      _player.stop();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (_clips.isNotEmpty || _blacklistedClipNames.isNotEmpty) {
      final result = await _showSessionSavePrompt();
      if (result == 'save') {
        await _deleteQueuedOriginalFiles();
        await _saveSessionData();
        await _saveSessionBlacklist();
        return AppExitResponse.exit;
      } else if (result == 'delete') {
        await _deleteQueuedOriginalFiles();
        await _deleteSessionBlacklist();
        await _deleteSessionData();
        return AppExitResponse.exit;
      } else {
        return AppExitResponse.cancel;
      }
    }
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
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx, false),
                        child: const Icon(Icons.close, size: 16, color: Colors.grey),
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
      try {
        await _deleteToRecycleBin(clip.filePath);
        setState(() {
          _clips.remove(clip);
          // Reset selection if the deleted clip was selected
          if (_selectedClipIndex >= _clips.length) {
            _selectedClipIndex = _clips.isEmpty ? -1 : _clips.length - 1;
          }
          if (_selectedClipIndex >= 0) {
            _selectClip(_selectedClipIndex);
          }
        });
        _showSnackBar('Clip deleted successfully: ${clip.fileName}', isDelete: true);
      } catch (e) {
        _showSnackBar('Failed to delete file: $e', isError: true);
      }
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
    if (!clip.isTrimmed) {
      int counter = 1;
      while (File(customOutputPath).existsSync()) {
        counter++;
        customOutputPath = path.join(dir, '$cleanName ($counter)$ext');
      }
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
        await defaultFile.rename(customOutputPath);
      }

      if (result != null) {
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
    } catch (e) {
      _showSnackBar('Export Failed: $e', isError: true);
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }

  Future<void> _changeExportDirectory() async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
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
        child: Column(
          children: [
            // Top Bar
            _buildTopBar(),
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
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          
          // Header list label & Sort Menu
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
                  ],
                ),
              ],
            ),
          ),

          // Clip list
          Expanded(
            child: _clips.isEmpty
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
                          alignment: Alignment.bottomRight,
                          children: [
                            VideoThumbnailWidget(filePath: clip.filePath),
                            if (clip.isTrimmed)
                              Container(
                                width: 14,
                                height: 14,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF76B900),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.check, size: 10, color: Colors.white),
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
                          if (clip.isTrimmed && File(clip.filePath).existsSync()) ...[
                            IconButton(
                              icon: const Icon(Icons.edit, size: 14, color: Color(0xFF76B900)),
                              tooltip: 'Edit / Revise',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _selectClip(idx, forceOriginal: true),
                            ),
                            const SizedBox(width: 8),
                          ],
                          IconButton(
                            icon: const Icon(Icons.folder_open, size: 14, color: Colors.grey),
                            tooltip: 'Reveal in File Explorer',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              final revealPath = (clip.isTrimmed && clip.trimmedOutputPath != null)
                                  ? clip.trimmedOutputPath!
                                  : clip.filePath;
                              Process.run('explorer', ['/select,', revealPath]);
                            },
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.close, size: 14, color: Colors.grey),
                            tooltip: 'Remove from list',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () {
                              setState(() {
                                _clips.removeAt(idx);
                                if (_selectedClipIndex == idx) {
                                    _selectedClipIndex = -1;
                                    _player.open(Media(''), play: false);
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
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.movie_outlined, size: 48, color: Colors.grey),
              SizedBox(height: 12),
              Text(
                'Import and select a video to start trimming.',
                style: TextStyle(color: Colors.grey),
              ),
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
              child: Center(
                child: GestureDetector(
                  onTap: () {
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
            ),

            // Timeline & Trim Controls Area
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF11111B),
              child: Column(
                children: [
                  // Cut Duration Details Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(_currentPosition),
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70),
                      ),
                      Row(
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
                      Text(
                        'DURATION AFTER CUT: ${_formatDuration(activeClip.endCut - activeClip.startCut)}',
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold, color: Colors.white),
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
                                onPressed: () {
                                  if (activeClip != null) {
                                    _player.seek(activeClip.startCut);
                                  }
                                },
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.replay_5, color: Colors.grey),
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
                                onPressed: () {
                                  final newPos = _currentPosition + const Duration(seconds: 5);
                                  _player.seek(newPos > duration ? duration : newPos);
                                },
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.last_page, color: Colors.redAccent),
                                tooltip: 'Jump to End Cut (Shift+L)',
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
                              // Playback speed selector
                              PopupMenuButton<double>(
                                tooltip: 'Playback Speed (< or >)',
                                offset: const Offset(0, -145),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey.shade800),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${_playbackSpeed.toStringAsFixed(1).replaceAll('.0', '')}x',
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white70),
                                  ),
                                ),
                                onSelected: (speed) {
                                  setState(() {
                                    _playbackSpeed = speed;
                                  });
                                  _player.setRate(speed);
                                },
                                itemBuilder: (context) => [1.0, 1.5, 2.0, 3.0].map((speed) => PopupMenuItem<double>(
                                  value: speed,
                                  child: Text('${speed.toStringAsFixed(1).replaceAll('.0', '')}x', style: TextStyle(fontSize: 11, color: _playbackSpeed == speed ? const Color(0xFF76B900) : Colors.white)),
                                )).toList(),
                              ),
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: _toggleMute,
                                child: Icon(
                                  _volume == 0 ? Icons.volume_off : (_volume < 50 ? Icons.volume_down : Icons.volume_up),
                                  size: 14,
                                  color: _volume == 0 ? Colors.redAccent : Colors.grey.shade500,
                                ),
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
            borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _customExportDir != null ? const Color(0xFF76B900).withOpacity(0.5) : Colors.transparent,
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
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 14, color: Colors.grey),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        final dir = _getExportDirectoryPath(activeClip);
                        Process.run('explorer', [dir]);
                      },
                      tooltip: 'Open in File Explorer',
                    )
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
                child: const Text(
                  'Reset to source folder',
                  style: TextStyle(fontSize: 10, color: Colors.grey, decoration: TextDecoration.underline),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),

          // Automatically add Trimmed folder checkbox
          Row(
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
          const SizedBox(height: 8),

          // Delete original clip after trim checkbox
          Row(
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
          const SizedBox(height: 20),

          // Video Metadata Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade900, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF76B900), size: 16),
                    SizedBox(width: 6),
                    Text(
                      'VIDEO METADATA',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF76B900)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (activeClip != null) ...[
                  _buildMetadataRow('File', activeClip.fileName),
                  if (activeClip.fileName != activeClip.originalFileName)
                    _buildMetadataRow('Original File', activeClip.originalFileName),
                  _buildMetadataRow('Format', path.extension(activeClip.filePath).toUpperCase().replaceAll('.', '')),
                  _buildMetadataRow('Size', activeClip.fileSizeFormatted),
                  _buildMetadataRow('Duration', _formatDuration(activeClip.duration).split('.')[0]),
                  _buildMetadataRow('Cut Start', _formatDuration(activeClip.startCut).split('.')[0]),
                  _buildMetadataRow('Cut End', _formatDuration(activeClip.endCut).split('.')[0]),
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
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade900, width: 1),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '[]',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF76B900),
                        fontFamily: 'monospace',
                      ),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'SHORTCUTS',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF76B900)),
                    ),
                  ],
                ),
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
                _ShortcutRow(keys: 'Del', desc: 'Delete Selected Clip'),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Export Button
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
          // Delete Files button
          ElevatedButton.icon(
            onPressed: activeClip != null ? () => _confirmDeleteFile(activeClip!) : null,
            icon: const Icon(Icons.delete_forever_outlined, size: 16),
            label: const Text('Delete Clip', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2A1520),
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
              ),
              disabledBackgroundColor: Colors.grey.shade900,
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
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Colors.white70, fontFamily: 'monospace'),
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
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(
        widget.text,
        style: widget.style,
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
    final Color enabledColor = sliderTheme.thumbColor ?? const Color(0xFF76B900);
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

/// Extracts a thumbnail from a video file using a dedicated Player instance.
class VideoThumbnailWidget extends StatefulWidget {
  final String filePath;
  const VideoThumbnailWidget({super.key, required this.filePath});

  @override
  State<VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<VideoThumbnailWidget> {
  late final Player _thumbPlayer;
  late final VideoController _thumbController;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _thumbPlayer = Player(configuration: const PlayerConfiguration(muted: true));
    _thumbController = VideoController(_thumbPlayer);
    _loadFrame();
  }

  Future<void> _loadFrame() async {
    final file = File(widget.filePath);
    if (!await file.exists()) {
      return;
    }
    await _thumbPlayer.open(Media(widget.filePath), play: false);
    // Seek to 5% into the video for a more representative frame
    final duration = _thumbPlayer.state.duration;
    if (duration > Duration.zero) {
      await _thumbPlayer.seek(Duration(milliseconds: (duration.inMilliseconds * 0.05).toInt()));
    }
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  void dispose() {
    _thumbPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: _ready
          ? Video(
              controller: _thumbController,
              controls: NoVideoControls,
            )
          : Container(
              color: const Color(0xFF1A1A2E),
              child: const Center(
                child: Icon(Icons.video_file_outlined, size: 16, color: Colors.grey),
              ),
            ),
    );
  }
}

