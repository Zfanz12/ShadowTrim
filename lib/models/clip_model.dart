import 'dart:io';
import 'package:path/path.dart' as path;

class VideoClip {
  final String filePath;
  final String fileName;
  final int fileSizeBytes;
  Duration duration;
  Duration startCut;
  Duration endCut;
  String? resolution;
  int? fps;
  bool isTrimmed;
  bool isAnimating;
  final DateTime dateModified;
  final DateTime dateCreated;

  VideoClip({
    required this.filePath,
    required this.fileName,
    required this.fileSizeBytes,
    required this.dateModified,
    required this.dateCreated,
    this.duration = Duration.zero,
    this.startCut = Duration.zero,
    this.endCut = Duration.zero,
    this.resolution,
    this.fps,
    this.isTrimmed = false,
    this.isAnimating = false,
  });

  String get fileSizeFormatted {
    final double mb = fileSizeBytes / (1024 * 1024);
    if (mb >= 1024) {
      final double gb = mb / 1024;
      return '${gb.toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  // Create VideoClip from a File path
  static Future<VideoClip> fromPath(String filePath) async {
    final file = File(filePath);
    final size = await file.length();
    final name = path.basename(filePath);
    final stat = await file.stat();
    final dateModified = stat.modified;
    final dateCreated = stat.changed;

    return VideoClip(
      filePath: filePath,
      fileName: name,
      fileSizeBytes: size,
      dateModified: dateModified,
      dateCreated: dateCreated,
    );
  }
}
