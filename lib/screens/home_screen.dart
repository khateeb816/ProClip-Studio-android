import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'media_picker_screen.dart'; // Import Custom Picker
import 'clips_screen.dart';
import 'settings_screen.dart';
import 'profile_screen.dart';
import '../services/clip_repository.dart';
import '../services/admin_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:package_info_plus/package_info_plus.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  
  final List<Widget> _pages = [
    const _HomeTab(),
    const ClipsScreen(),
    const SettingsScreen(),
    const ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    ClipRepository.init(); // Initialize repo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAnnouncement();
    });
  }

  Future<void> _checkAnnouncement() async {
    try {
      final announcement = await AdminService().getAnnouncement();
      debugPrint("📢 Announcement fetch: $announcement");
      
      if (announcement != null && announcement['isActive'] == true) {
        final deadlineRaw = announcement['deadline'];
        if (deadlineRaw == null) return;
        
        final deadline = (deadlineRaw as Timestamp).toDate();
        if (deadline.isAfter(DateTime.now())) {
          final prefs = await SharedPreferences.getInstance();
          
          // Use createdAt as a unique ID if message is the same
          final currentMessage = announcement['message'] as String? ?? '';
          final createdAtRaw = announcement['createdAt'];
          final String announcementId = createdAtRaw != null 
              ? (createdAtRaw as Timestamp).millisecondsSinceEpoch.toString() 
              : currentMessage;

          final lastSeenId = prefs.getString('last_announcement_id') ?? '';
          
          debugPrint("📢 Checking: currentId=$announcementId, lastId=$lastSeenId");
          
          if (lastSeenId != announcementId) {
            if (!mounted) return;
            _showAnnouncementPopup(currentMessage);
            await prefs.setString('last_announcement_id', announcementId);
          }
        } else {
          debugPrint("📢 Announcement expired at $deadline");
        }
      } else {
        debugPrint("📢 No active announcement found");
      }
    } catch (e) {
      debugPrint("❌ Error checking announcement: $e");
    }
  }

  void _showAnnouncementPopup(String message) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (context, animation, secondaryAnimation) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E).withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5), width: 1.5),
                boxShadow: [
                  BoxShadow(color: Colors.cyanAccent.withValues(alpha: 0.15), blurRadius: 30, spreadRadius: 5),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.campaign, size: 56, color: Colors.cyanAccent),
                  const SizedBox(height: 16),
                  const Text('Admin Announcement', 
                    style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.1)
                  ),
                  const SizedBox(height: 16),
                  Text(message, 
                    textAlign: TextAlign.center, 
                    style: TextStyle(color: Colors.grey[300], fontSize: 16, height: 1.4)
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      minimumSize: const Size(double.infinity, 52),
                      elevation: 8,
                    ),
                    child: const Text('GOT IT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 1.2)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return ScaleTransition(
          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
          child: FadeTransition(
            opacity: animation,
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: Colors.cyanAccent,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: "Home"),
          BottomNavigationBarItem(icon: Icon(Icons.video_library), label: "Clips"),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: "Settings"),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: "Profile"),
        ],
      ),
    );
  }
}

class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  String? _customOutputPath;
  String _appVersion = "";

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = info.version;
      });
    }
  }
  
  // Reload settings every time the tab is built/visible to catch updates from SettingsScreen
  @override 
  void didChangeDependencies() {
     super.didChangeDependencies();
     _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _customOutputPath = prefs.getString('custom_output_path');
      });
    }
  }

  Future<void> _pickVideo() async {
    // Navigate to Custom Media Picker
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const MediaPickerScreen(),
      ),
    );
  }

  Future<void> _quitApp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Quit App?"),
        content: const Text("This will stop all background services and close the app completely."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text("Quit"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Cancel the foreground notification directly
      final FlutterLocalNotificationsPlugin notificationsPlugin = 
          FlutterLocalNotificationsPlugin();
      await notificationsPlugin.cancel(888);
      
      // Stop background service
      FlutterBackgroundService().invoke("stopService");
      
      // Small delay to ensure cleanup
      await Future.delayed(const Duration(milliseconds: 300));
      
      // Forcefully terminate the app process
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("ProClip Studio Mobile"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.power_settings_new, color: Colors.redAccent),
            tooltip: "Quit App",
            onPressed: _quitApp,
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.cyanAccent.withValues(alpha: 0.3),
                        blurRadius: 20,
                        spreadRadius: 3,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(60),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                
                const SizedBox(height: 32),
                
                const Text(
                  "Create New Clip",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                
                const SizedBox(height: 12),
                
                Text(
                  "Select a video to continue",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey[400],
                  ),
                ),

                if (_customOutputPath != null) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.3)),
                      ),
                      child: Text(
                        "Output: ${_customOutputPath!.split('/').last}",
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                
                const SizedBox(height: 48),
                
                ElevatedButton.icon(
                  onPressed: _pickVideo,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text("Select Video"),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    textStyle: const TextStyle(fontSize: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
                if (_appVersion.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    "Version $_appVersion",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
