import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
