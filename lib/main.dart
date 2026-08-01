import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/dashboard_screen.dart';
import 'services/logger_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await LoggerService.init();

  runApp(const ShadowClipApp());
}

class ShadowClipApp extends StatelessWidget {
  const ShadowClipApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ShadowTrim',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1E2E), // Modern dark color
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF76B900), // Nvidia Green accent
          secondary: Color(0xFF89B4FA),
          surface: Color(0xFF181825),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF11111B),
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF76B900),
            foregroundColor: Colors.white,
            enabledMouseCursor: SystemMouseCursors.click,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            enabledMouseCursor: SystemMouseCursors.click,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            enabledMouseCursor: SystemMouseCursors.click,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            enabledMouseCursor: SystemMouseCursors.click,
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          mouseCursor: WidgetStateProperty.all(SystemMouseCursors.click),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
