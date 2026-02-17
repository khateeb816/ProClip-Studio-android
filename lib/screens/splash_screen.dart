import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:async';
import '../services/video_cache_manager.dart';
import '../services/audio_cache_manager.dart';
import 'home_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  String _statusMessage = "Initializing...";
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
    
    _startStartupSequence();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startStartupSequence() async {
    await Future.delayed(const Duration(milliseconds: 500));
    
    try {
      if (mounted) setState(() => _statusMessage = "Checking Android Version...");
      
      bool permissionGranted = false;
      
      if (Platform.isAndroid) {
         final androidInfo = await DeviceInfoPlugin().androidInfo;
         final int sdkInt = androidInfo.version.sdkInt;
         
         if (sdkInt >= 33) {
            if (mounted) setState(() => _statusMessage = "Requesting Photos/Videos...");
            
            // Request multiple permissions for Android 13+
            Map<Permission, PermissionStatus> statuses = await [
               Permission.videos,
               Permission.photos,
               Permission.audio,
            ].request();
            
            if (statuses[Permission.videos]?.isGranted == true && 
                statuses[Permission.photos]?.isGranted == true &&
                statuses[Permission.audio]?.isGranted == true) {
               permissionGranted = true;
            } else {
               // Detail which ones failed for debugging/user info
               final denied = statuses.entries
                 .where((e) => !e.value.isGranted)
                 .map((e) => e.key.toString().split('.').last)
                 .join(", ");
               debugPrint("❌ Missing permissions: $denied");
            }
         } else {
            if (mounted) setState(() => _statusMessage = "Requesting Storage...");
            
            // Request storage for Android < 13
            final status = await Permission.storage.request();
            if (status.isGranted) {
               permissionGranted = true;
            }
         }
      } else {
         // iOS: Use PhotoManager's request or Permission.photos
         if (mounted) setState(() => _statusMessage = "Requesting Library Access...");
         final ps = await PhotoManager.requestPermissionExtend();
         if (ps.isAuth || ps.hasAccess) {
            permissionGranted = true;
         }
      }

      if (!permissionGranted) {
         if (mounted) {
           setState(() {
             _statusMessage = "Access denied. Please enable in settings.";
             _permissionDenied = true;
           });
         }
         return;
      }

      if (mounted) setState(() => _statusMessage = "Loading assets...");
      
      // Critical: Tell PhotoManager we already handled permissions to avoid double-check hang
      PhotoManager.setIgnorePermissionCheck(true);
      
      // Initialize both caches
      await Future.wait([
        VideoCacheManager().init(onProgress: (progress) {
          if (mounted && progress < 1.0) {
            setState(() => _statusMessage = "Loading videos... ${(progress * 100).toInt()}%");
          }
        }),
        AudioCacheManager().init(),
      ]);
      
      // 3. Navigate to Home
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      debugPrint("❌ Splash Error: $e");
      if (mounted) {
        setState(() {
          _statusMessage = "Startup Error: $e";
          _permissionDenied = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Beautiful Logo
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.cyanAccent.withValues(alpha: 0.3),
                      blurRadius: 30,
                      spreadRadius: 5,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(70),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 140,
                    height: 140,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              
              const SizedBox(height: 40),
              
              const Text(
                "PRO CLIP STUDIO",
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: Colors.white,
                ),
              ),
              
              const SizedBox(height: 60),
              
              if (!_permissionDenied)
                const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                  ),
                ),
              
              const SizedBox(height: 20),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _permissionDenied ? Colors.redAccent : Colors.grey,
                    fontSize: 14,
                  ),
                ),
              ),
              
              if (_permissionDenied) ...[
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                       _permissionDenied = false;
                       _statusMessage = "Retrying...";
                    });
                    _startStartupSequence();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent.withValues(alpha: 0.2)),
                  child: const Text("Retry Permissions"),
                ),
                TextButton(
                  onPressed: () => openAppSettings(),
                  child: const Text("Open Settings"),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }
}
