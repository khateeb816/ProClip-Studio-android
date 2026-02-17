import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/ffmpeg_service.dart';

import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    debugPrint("🚀 Starting App Initialization...");
    await NotificationService.init();
    await FFMpegService.init(); // Initialize FFMpeg Config
    await BackgroundService.initializeService(); // Initialize Background Service
    debugPrint("✅ Initialization Complete");
  } catch (e, stack) {
    debugPrint("❌ Initialization Error: $e");
    debugPrint(stack.toString());
  }
  
  runApp(const ProClipStudioApp());
}

class ProClipStudioApp extends StatelessWidget {
  const ProClipStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProClip Studio',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF181818),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF007ACC),
          secondary: Color(0xFF00C853),
          surface: Color(0xFF202020),
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.interTextTheme(
          Theme.of(context).textTheme.apply(bodyColor: const Color(0xFFE0E0E0)),
        ),
      ),
      home: const SplashScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
