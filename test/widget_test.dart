import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowclip_trimmer/services/native_core_bridge.dart';
import 'package:shadowclip_trimmer/services/video_service.dart';

void main() {
  test('Native Core Bridge initialization and version check', () {
    expect(ShadowTrimNativeBridge.isAvailable, isTrue);
    expect(ShadowTrimNativeBridge.version, equals(100));
  });

  test('Native C++ Win32 timestamp restoration works accurately', () async {
    final tempDir = Directory.systemTemp.createTempSync('shadowtrim_test_');
    final srcFile = File('${tempDir.path}\\src.txt')..writeAsStringSync('source content');
    final dstFile = File('${tempDir.path}\\dst.txt')..writeAsStringSync('target content');

    // Artificially change src time to 1 day ago
    final pastTime = DateTime.now().subtract(const Duration(days: 1));
    await srcFile.setLastModified(pastTime);

    final success = ShadowTrimNativeBridge.restoreTimestampsNative(srcFile.path, dstFile.path);
    expect(success, isTrue);

    final dstStat = dstFile.statSync();
    expect(dstStat.modified.difference(pastTime).inSeconds.abs(), lessThanOrEqualTo(2));

    tempDir.deleteSync(recursive: true);
  });

  test('Native C++ Win32 recycleFileNative moves file to recycle bin safely', () {
    final tempDir = Directory.systemTemp.createTempSync('shadowtrim_recycle_test_');
    final dummyFile = File('${tempDir.path}\\dummy_to_recycle.txt')..writeAsStringSync('sample content');
    expect(dummyFile.existsSync(), isTrue);

    final success = ShadowTrimNativeBridge.recycleFileNative(dummyFile.path);
    expect(success, isTrue);
    expect(dummyFile.existsSync(), isFalse);

    tempDir.deleteSync(recursive: true);
  });

  test('VideoTrimmer thumbnail queue clears cleanly', () {
    expect(() => VideoTrimmer.clearThumbnailQueue(), returnsNormally);
  });
}
