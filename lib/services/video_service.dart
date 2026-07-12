import 'dart:io';
import 'package:path/path.dart' as path;

class VideoTrimmer {
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

      // FFmpeg command: ffmpeg -i input.mp4 -ss start -to end -c copy output.mp4
      final result = await Process.run(ffmpegCmd, [
        '-i', inputPath,
        '-ss', startTime,
        '-to', endTime,
        '-c', 'copy',
        '-map', '0', // Keep all streams (video, audio, subtitles, etc)
        outputPath
      ]);

      if (result.exitCode != 0) {
        print('FFmpeg Error: ${result.stderr}');
        throw Exception('Failed to trim video. FFmpeg exit code: ${result.exitCode}');
      }

      // Restore metadata
      await _restoreMetadata(inputFile, outputFile);

      return outputPath;
    } catch (e) {
      print('Error trimming video: $e');
      return null;
    }
  }

  /// Copies the modified and accessed dates from original to the trimmed file.
  static Future<void> _restoreMetadata(File original, File newFile) async {
    try {
      final stat = await original.stat();
      // Dart's File API allows setting Last Modified and Last Accessed
      await newFile.setLastModified(stat.modified);
      await newFile.setLastAccessed(stat.accessed);
      
      // For Windows Creation Time, we could use a powershell script as a fallback,
      // but modifying lastModified is usually sufficient for file explorer sorting.
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
