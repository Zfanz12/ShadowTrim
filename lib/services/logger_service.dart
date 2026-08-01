import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class LoggerService {
  static Directory? _logDir;
  static File? _currentLogFile;

  /// Returns an accurate OS version string.
  /// On Windows, kernel version 10.0 with Build >= 22000 corresponds to Windows 11.
  static String get accurateOsVersion {
    String version = Platform.operatingSystemVersion;
    final buildMatch = RegExp(r'Build (\d+)').firstMatch(version);
    if (buildMatch != null) {
      final buildNum = int.tryParse(buildMatch.group(1) ?? '0') ?? 0;
      if (buildNum >= 22000 && version.contains('Windows 10')) {
        version = version.replaceFirst('Windows 10', 'Windows 11');
      }
    }
    return version;
  }

  /// Initializes the logger, registers global uncaught error listeners,
  /// checks for previous native crashes, and cleans up old logs.
  static Future<void> init() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      _logDir = Directory(path.join(docDir.path, 'ShadowTrim', 'logs'));
      if (!await _logDir!.exists()) {
        await _logDir!.create(recursive: true);
      }

      final dateStr = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
      _currentLogFile = File(path.join(_logDir!.path, 'shadowtrim_$dateStr.log'));

      await _writeHeader();
      await _checkNativeCrashLogs();
      await _cleanOldLogs();

      // Catch Flutter framework UI & Widget tree errors
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        logError('FlutterError: ${details.exceptionAsString()}', details.stack);
      };

      // Catch uncaught Dart asynchronous errors & Isolate exceptions
      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        logError('UncaughtAsyncError: $error', stack);
        return true; // Error handled gracefully
      };

      logInfo('LoggerService initialized successfully on $accurateOsVersion');
    } catch (e) {
      debugPrint('Failed to initialize LoggerService: $e');
    }
  }

  static Future<void> _writeHeader() async {
    if (_currentLogFile == null) return;
    final header = '''
================================================================================
ShadowTrim Detailed Crash & Diagnostic Session Log
Timestamp       : ${DateTime.now().toIso8601String()}
OS Version      : $accurateOsVersion
Locale          : ${Platform.localeName}
CPU Cores       : ${Platform.numberOfProcessors}
Dart Runtime    : ${Platform.version.split(' ').first}
Working Directory: ${Directory.current.path}
Executable Path : ${Platform.resolvedExecutable}
================================================================================

''';
    await _currentLogFile!.writeAsString(header, mode: FileMode.append, flush: true);
  }

  /// Checks if C++ native crash handler generated a native_crash.log from a previous run
  static Future<void> _checkNativeCrashLogs() async {
    try {
      if (_logDir == null) return;
      final nativeCrashFile = File(path.join(_logDir!.path, 'native_crash.log'));
      if (await nativeCrashFile.exists()) {
        final content = await nativeCrashFile.readAsString();
        if (content.trim().isNotEmpty && _currentLogFile != null) {
          await _currentLogFile!.writeAsString('\n[PREVIOUS NATIVE C/C++ CRASH DETECTED]:\n$content\n', mode: FileMode.append, flush: true);
        }
        await nativeCrashFile.delete();
      }
    } catch (_) {}
  }

  /// Appends error message & stack trace to log file with immediate disk flush.
  static void logError(String message, [StackTrace? stack]) async {
    try {
      final timestamp = DateTime.now().toIso8601String();
      final sb = StringBuffer();
      sb.writeln('[$timestamp] [ERROR] $message');
      if (stack != null) {
        sb.writeln('Stack Trace:');
        sb.writeln(stack.toString());
      }
      sb.writeln('--------------------------------------------------------------------------------');

      if (_currentLogFile != null) {
        await _currentLogFile!.writeAsString(sb.toString(), mode: FileMode.append, flush: true);
      }
      debugPrint(sb.toString());
    } catch (e) {
      debugPrint('Failed to write error log: $e');
    }
  }

  /// Appends general info message to log file with immediate disk flush.
  static void logInfo(String message) async {
    try {
      final timestamp = DateTime.now().toIso8601String();
      final logLine = '[$timestamp] [INFO] $message\n';
      if (_currentLogFile != null) {
        await _currentLogFile!.writeAsString(logLine, mode: FileMode.append, flush: true);
      }
    } catch (_) {}
  }

  /// Opens the log directory in File Explorer.
  static Future<void> openLogFolder() async {
    try {
      if (_logDir != null && await _logDir!.exists()) {
        if (Platform.isWindows) {
          Process.start('explorer', [_logDir!.path], mode: ProcessStartMode.detached);
        } else if (Platform.isMacOS) {
          Process.start('open', [_logDir!.path], mode: ProcessStartMode.detached);
        } else if (Platform.isLinux) {
          Process.start('xdg-open', [_logDir!.path], mode: ProcessStartMode.detached);
        }
      }
    } catch (e) {
      debugPrint('Failed to open log folder: $e');
    }
  }

  /// Retains only the 10 most recent log files.
  static Future<void> _cleanOldLogs() async {
    try {
      if (_logDir == null || !await _logDir!.exists()) return;
      final files = await _logDir!.list().where((e) => e is File && e.path.endsWith('.log')).cast<File>().toList();
      if (files.length > 10) {
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (int i = 0; i < files.length - 10; i++) {
          await files[i].delete();
        }
      }
    } catch (_) {}
  }
}
