import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'logger_service.dart';
import 'native_core_bridge.dart';

class _ThumbRequest {
  final String videoPath;
  final Completer<File?> completer;
  _ThumbRequest(this.videoPath, this.completer);
}

class VideoTrimmer {
  static final List<_ThumbRequest> _thumbQueue = [];
  static final Map<String, Future<File?>> _thumbFutures = {};
  static int _activeThumbJobs = 0;
  static const int _maxConcurrentThumbJobs = 2;

  /// Clears any pending thumbnail requests from previous folders.
  static void clearThumbnailQueue() {
    for (final req in _thumbQueue) {
      if (!req.completer.isCompleted) {
        req.completer.complete(null);
      }
    }
    _thumbQueue.clear();
    _thumbFutures.clear();
  }

  /// Generates a fast JPEG thumbnail image using FFmpeg in system temp folder.
  /// Uses a concurrency-limited queue (max 2 jobs) to prevent CPU/disk saturation and crashes on large folders.
  static Future<File?> generateThumbnail(String videoPath) {
    if (_thumbFutures.containsKey(videoPath)) {
      return _thumbFutures[videoPath]!;
    }
    final future = _generateThumbnailInternal(videoPath);
    _thumbFutures[videoPath] = future;
    return future;
  }

  static Future<File?> _generateThumbnailInternal(String videoPath) async {
    try {
      final file = File(videoPath);
      if (!await file.exists()) return null;

      final tempDir = await getTemporaryDirectory();
      final hash = videoPath.hashCode.abs();
      final thumbPath = path.join(tempDir.path, 'shadowtrim_thumb_$hash.jpg');
      final thumbFile = File(thumbPath);

      if (await thumbFile.exists()) {
        return thumbFile;
      }

      final completer = Completer<File?>();
      _thumbQueue.add(_ThumbRequest(videoPath, completer));
      _processThumbQueue();
      return completer.future;
    } catch (e, stack) {
      LoggerService.logError('Thumbnail generation error for $videoPath: $e', stack);
    }
    return null;
  }

  static void _processThumbQueue() {
    if (_activeThumbJobs >= _maxConcurrentThumbJobs || _thumbQueue.isEmpty) return;
    _activeThumbJobs++;
    final req = _thumbQueue.removeAt(0);
    _doGenerateThumbnail(req.videoPath).then((file) {
      if (!req.completer.isCompleted) req.completer.complete(file);
    }).catchError((e) {
      if (!req.completer.isCompleted) req.completer.complete(null);
    }).whenComplete(() {
      _activeThumbJobs--;
      _processThumbQueue();
    });
  }

  static Future<File?> _doGenerateThumbnail(String videoPath) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final hash = videoPath.hashCode.abs();
      final thumbPath = path.join(tempDir.path, 'shadowtrim_thumb_$hash.jpg');
      final thumbFile = File(thumbPath);

      if (await thumbFile.exists()) {
        return thumbFile;
      }

      String ffmpegCmd = 'ffmpeg';
      try {
        final appDir = path.dirname(Platform.resolvedExecutable);
        final localFFmpeg = File(path.join(appDir, Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'));
        if (localFFmpeg.existsSync()) {
          ffmpegCmd = localFFmpeg.path;
        }
      } catch (_) {}

      var result = await Process.run(ffmpegCmd, [
        '-ss', '00:00:01',
        '-i', videoPath,
        '-vframes', '1',
        '-q:v', '5',
        '-s', '160x90',
        '-y',
        thumbPath,
      ]);

      if (result.exitCode != 0 || !await thumbFile.exists()) {
        // Fallback for AV1 / high-bitrate video streams: extract first available frame (00:00:00)
        result = await Process.run(ffmpegCmd, [
          '-i', videoPath,
          '-vframes', '1',
          '-q:v', '5',
          '-s', '160x90',
          '-y',
          thumbPath,
        ]);
      }

      if (result.exitCode == 0 && await thumbFile.exists()) {
        return thumbFile;
      } else {
        LoggerService.logError('FFmpeg thumbnail failed exitCode ${result.exitCode}: ${result.stderr}');
      }
    } catch (e, stack) {
      LoggerService.logError('FFmpeg thumbnail execution error for $videoPath: $e', stack);
    }
    return null;
  }
  /// Probes video file for Resolution, FPS, and Bitrate using FFprobe.
  /// Runs asynchronously — does not block UI.
  static Future<Map<String, dynamic>> probeVideoMetadata(String filePath) async {
    try {
      String ffprobeCmd = 'ffprobe';
      try {
        final appDir = path.dirname(Platform.resolvedExecutable);
        final localFFprobe = File(path.join(appDir, Platform.isWindows ? 'ffprobe.exe' : 'ffprobe'));
        if (localFFprobe.existsSync()) {
          ffprobeCmd = localFFprobe.path;
        }
      } catch (_) {
        // Fallback to system ffprobe
      }

      String stdoutString = '';
      int exitCode = -1;

      if (Platform.isWindows && ShadowTrimNativeBridge.isAvailable) {
        final nativeRes = await ShadowTrimNativeBridge.executeProcessNative(
          ffprobeCmd,
          ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', filePath],
        );
        if (nativeRes != null) {
          exitCode = nativeRes['exitCode'] as int;
          stdoutString = nativeRes['output'] as String;
        }
      }

      if (exitCode != 0 || stdoutString.isEmpty) {
        final result = await Process.run(ffprobeCmd, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_format',
          '-show_streams',
          filePath,
        ]);
        exitCode = result.exitCode;
        stdoutString = result.stdout as String;
      }

      if (exitCode == 0 && stdoutString.isNotEmpty) {
        final data = jsonDecode(stdoutString) as Map<String, dynamic>;
        final streams = data['streams'] as List<dynamic>? ?? [];
        final format = data['format'] as Map<String, dynamic>? ?? {};

        String? resStr;
        int? fpsInt;
        String? bitrateStr;
        double? durationSec;
        if (format['duration'] != null) {
          durationSec = double.tryParse(format['duration'].toString());
        }

        for (final stream in streams) {
          if (stream['codec_type'] == 'video') {
            final width = stream['width'];
            final height = stream['height'];
            if (width != null && height != null) {
              resStr = '${width}x$height';
            }

            if (durationSec == null && stream['duration'] != null) {
              durationSec = double.tryParse(stream['duration'].toString());
            }

            final rFrameRate = stream['r_frame_rate'] as String? ?? stream['avg_frame_rate'] as String?;
            if (rFrameRate != null && rFrameRate.contains('/')) {
              final parts = rFrameRate.split('/');
              final num = double.tryParse(parts[0]) ?? 0;
              final den = double.tryParse(parts[1]) ?? 1;
              if (den > 0) {
                fpsInt = (num / den).round();
              }
            }

            final streamBitrate = stream['bit_rate'] as String?;
            if (streamBitrate != null) {
              final bps = double.tryParse(streamBitrate) ?? 0;
              if (bps > 0) {
                bitrateStr = '${(bps / 1000000).toStringAsFixed(1)} Mbps';
              }
            }
            break; // Only need first video stream
          }
        }

        // Fallback: use container-level bitrate if stream didn't have it
        if (bitrateStr == null && format['bit_rate'] != null) {
          final bps = double.tryParse(format['bit_rate'].toString()) ?? 0;
          if (bps > 0) {
            bitrateStr = '${(bps / 1000000).toStringAsFixed(1)} Mbps';
          }
        }

        Duration? durationObj;
        if (durationSec != null && durationSec > 0) {
          durationObj = Duration(milliseconds: (durationSec * 1000).round());
        }

        return {
          'resolution': resStr,
          'fps': fpsInt,
          'bitrate': bitrateStr,
          'duration': durationObj,
        };
      }
    } catch (e, stack) {
      LoggerService.logError('FFprobe metadata probe error for $filePath: $e', stack);
    }
    return {};
  }

  /// Trims a video from [startTime] to [endTime] (in format HH:MM:SS or seconds)
  /// without re-encoding (lossless).
  /// Saves the output in the same directory with `_trimmed` suffix.
  static Future<String?> trimVideo({
    required String inputPath,
    required String startTime,
    required String endTime,
  }) async {
    try {
      final inputFile = File(inputPath);
      if (!await inputFile.exists()) {
        throw Exception('Input file does not exist');
      }

      // Generate output path
      final dir = path.dirname(inputPath);
      final ext = path.extension(inputPath);
      final baseName = path.basenameWithoutExtension(inputPath);
      final outputPath = path.join(dir, '${baseName}_trimmed$ext');

      // Ensure the output file doesn't already exist or overwrite it
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      // Use local ffmpeg.exe if present in the same directory as the app executable, otherwise fallback to system path
      String ffmpegCmd = 'ffmpeg';
      try {
        final appDir = path.dirname(Platform.resolvedExecutable);
        final localFFmpeg = File(path.join(appDir, Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg'));
        if (localFFmpeg.existsSync()) {
          ffmpegCmd = localFFmpeg.path;
        }
      } catch (e) {
        // Fallback to system ffmpeg if Platform.resolvedExecutable fails (e.g. in test env)
      }

      LoggerService.logInfo('Trimming video [lossless]: $inputPath -> $outputPath (start: $startTime, end: $endTime)');

      // 1. High-Performance C++ Native Core execution
      if (Platform.isWindows && ShadowTrimNativeBridge.isAvailable) {
        LoggerService.logInfo('Executing trim via C++ Native Engine (zero subprocess overhead)');
        final exitCode = await ShadowTrimNativeBridge.fastTrimNative(
          ffmpegPath: ffmpegCmd,
          inputPath: inputPath,
          outputPath: outputPath,
          startTime: startTime,
          endTime: endTime,
        );

        if (exitCode == 0 && await outputFile.exists()) {
          LoggerService.logInfo('C++ Native video trim success: $outputPath');
          return outputPath;
        } else {
          LoggerService.logError('C++ Native trim returned code $exitCode, trying fallback runner...');
        }
      }

      // 2. Standard Fallback execution
      final result = await Process.run(ffmpegCmd, [
        '-y', // Force overwrite output file — prevents hang on batch exports
        '-i', inputPath,
        '-ss', startTime,
        '-to', endTime,
        '-c', 'copy',
        '-map', '0', // Keep all streams (video, audio, subtitles, etc)
        outputPath
      ]);

      if (result.exitCode == 0 && await outputFile.exists()) {
        LoggerService.logInfo('Video trim success (fallback): $outputPath');
        // Restore metadata
        await _restoreMetadata(inputFile, outputFile);
        return outputPath;
      } else {
        LoggerService.logError('FFmpeg trim failed exitCode ${result.exitCode}: ${result.stderr}');
      }

      if (result.exitCode != 0) {
        print('FFmpeg Error: ${result.stderr}');
        throw Exception('Failed to trim video. FFmpeg exit code: ${result.exitCode}');
      }

      return outputPath;
    } catch (e) {
      print('Error trimming video: $e');
      return null;
    }
  }

  /// Copies the modified and accessed dates from original to the trimmed file.
  /// Uses C++ Win32 kernel API (GetFileTime / SetFileTime) in < 0.01 ms with zero overhead.
  static Future<void> _restoreMetadata(File original, File newFile) async {
    try {
      // 1. Fast C++ Native Win32 API
      if (Platform.isWindows && ShadowTrimNativeBridge.isAvailable) {
        final success = ShadowTrimNativeBridge.restoreTimestampsNative(original.path, newFile.path);
        if (success) {
          LoggerService.logInfo('Restored timestamps via C++ Native Core (<0.01ms): ${newFile.path}');
          return;
        }
      }

      // 2. Dart File API fallback
      final stat = await original.stat();
      await newFile.setLastModified(stat.modified);
      await newFile.setLastAccessed(stat.accessed);
      
      // 3. PowerShell fallback for Windows CreationTime if native C++ unavailable
      if (Platform.isWindows) {
        final originalPath = original.absolute.path;
        final newPath = newFile.absolute.path;
        final psCommand = '''
        \$orig = Get-Item -LiteralPath "$originalPath";
        \$new = Get-Item -LiteralPath "$newPath";
        \$new.CreationTime = \$orig.CreationTime;
        ''';
        
        await Process.run('powershell', ['-Command', psCommand]);
      }
      
    } catch (e) {
      print('Warning: Failed to restore metadata: $e');
    }
  }
}
