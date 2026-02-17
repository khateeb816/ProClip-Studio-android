import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _platformInstagram = true;
  bool _platformYouTube = true;
  bool _platformTikTok = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }
  
  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _platformInstagram = prefs.getBool('platform_instagram') ?? true;
      _platformYouTube = prefs.getBool('platform_youtube') ?? true;
      _platformTikTok = prefs.getBool('platform_tiktok') ?? true;
    });
  }



  Future<void> _togglePlatform(String platform, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('platform_$platform', value);
    setState(() {
      if (platform == 'instagram') _platformInstagram = value;
      if (platform == 'youtube') _platformYouTube = value;
      if (platform == 'tiktok') _platformTikTok = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Platform Settings Section
          const Text(
            "Platform Settings",
            style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          const Text(
            "Enable or disable upload buttons for each platform",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 10),
          
          SwitchListTile(
            tileColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text("Instagram", style: TextStyle(color: Colors.white)),
            subtitle: const Text("Show Instagram upload button", style: TextStyle(color: Colors.grey, fontSize: 12)),
            value: _platformInstagram,
            activeColor: Colors.pinkAccent,
            onChanged: (value) => _togglePlatform('instagram', value),
            secondary: const Icon(Icons.photo_camera, color: Colors.pinkAccent),
          ),
          const SizedBox(height: 10),
          
          SwitchListTile(
            tileColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text("YouTube", style: TextStyle(color: Colors.white)),
            subtitle: const Text("Show YouTube upload button", style: TextStyle(color: Colors.grey, fontSize: 12)),
            value: _platformYouTube,
            activeColor: Colors.redAccent,
            onChanged: (value) => _togglePlatform('youtube', value),
            secondary: const Icon(Icons.video_library, color: Colors.redAccent),
          ),
          const SizedBox(height: 10),
          
          SwitchListTile(
            tileColor: Colors.grey[900],
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text("TikTok", style: TextStyle(color: Colors.white)),
            subtitle: const Text("Show TikTok upload button", style: TextStyle(color: Colors.grey, fontSize: 12)),
            value: _platformTikTok,
            activeColor: Colors.white,
            onChanged: (value) => _togglePlatform('tiktok', value),
            secondary: const Icon(Icons.music_note, color: Colors.white),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
