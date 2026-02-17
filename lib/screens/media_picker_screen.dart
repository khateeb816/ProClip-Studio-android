import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
      // Preload service removed

import '../services/video_cache_manager.dart';
import '../services/auth_service.dart';
import 'editor_screen.dart'; // Import EditorScreen
import 'profile_screen.dart'; // For navigation to premium

class MediaPickerScreen extends StatefulWidget {
  const MediaPickerScreen({super.key});

  @override
  State<MediaPickerScreen> createState() => _MediaPickerScreenState();
}

class _MediaPickerScreenState extends State<MediaPickerScreen> {
  List<AssetEntity> _assets = [];
  final List<AssetEntity> _selectedAssets = [];
  bool _isLoading = true;
  final _authService = AuthService();
  Map<String, dynamic>? _userData;

  @override
  void initState() {
    super.initState();
    _loadCachedAssets();
    _loadUserData();
  }

  Future<void> _loadUserData() async {
    final data = await _authService.getUserData();
    if (mounted) {
      setState(() => _userData = data);
    }
  }

  void _loadCachedAssets() {
    final cached = VideoCacheManager().cachedAssets;
    if (cached.isNotEmpty) {
      debugPrint("📸 MediaPicker: Using ${cached.length} cached assets");
      setState(() {
        _assets = cached;
        _isLoading = false;
      });
    } else {
      debugPrint("📸 MediaPicker: Cache empty, fetching...");
      _fetchAssets();
    }
  }

  Future<void> _fetchAssets() async {
    // Keep the logic for freshness or fallback
    if (!VideoCacheManager().isInitialized) {
       await VideoCacheManager().init();
    }
    
    setState(() {
       _assets = VideoCacheManager().cachedAssets;
       _isLoading = false;
    });
  }

  Future<void> _requestPermissions() async {
     bool granted = false;
     if (Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt >= 33) {
           Map<Permission, PermissionStatus> statuses = await [
              Permission.videos,
              Permission.photos,
           ].request();
           if (statuses[Permission.videos]?.isGranted == true || statuses[Permission.photos]?.isGranted == true) {
             granted = true;
           }
        } else {
           if (await Permission.storage.request().isGranted) {
             granted = true;
           }
        }
     } else {
        // iOS handled by Info.plist and PhotoManager usually
        granted = await PhotoManager.requestPermissionExtend().then((ps) => ps.isAuth || ps.hasAccess);
     }

     if (granted) {
        // Retry loading
        setState(() => _isLoading = true);
        VideoCacheManager().refresh();
        await Future.delayed(const Duration(seconds: 1)); // Wait for refresh
        _loadCachedAssets();
     } else {
        _showPermissionDeniedDialog();
     }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Permission Denied"),
        content: const Text("Please grant storage permission to access videos."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("OK"),
          ),
          TextButton(
            onPressed: () {
               Navigator.pop(ctx);
               openAppSettings();
            },
            child: const Text("Settings"),
          ),
        ],
      ),
    );
     setState(() => _isLoading = false);
  }

  void _toggleSelection(AssetEntity asset) {
    setState(() {
      if (_selectedAssets.contains(asset)) {
        _selectedAssets.remove(asset);
      } else {
        // Restriction Check: Free users only 1 video
        final status = _userData?['subscriptionStatus'] as String? ?? 'free';
        if (status == 'free' && _selectedAssets.length >= 1) {
          _showFreeLimitDialog();
          return;
        }
        
        _selectedAssets.add(asset);
        // Performance: Start preloading immediately on selection
      }
    });
  }

  void _showFreeLimitDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text("Free Plan Limit", style: TextStyle(color: Colors.white)),
        content: const Text(
          "Free users can only select 1 video at a time. Upgrade to Premium to select multiple videos.",
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("OK"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
            child: const Text("Update to Premium"),
          ),
        ],
      ),
    );
  }

  Future<void> _proceedToEditor() async {
    if (_selectedAssets.isEmpty) return;

    // Convert Assets to Files
    List<File> files = [];
    for (var asset in _selectedAssets) {
      final file = await asset.file;
      if (file != null) {
        files.add(file);
      }
    }

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => EditorScreen(videoFiles: files),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final duration = Duration(seconds: seconds);
    final minutes = duration.inMinutes;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Select Videos"),
        backgroundColor: Colors.black,
        actions: [
          if (_selectedAssets.isNotEmpty)
            TextButton(
              onPressed: _proceedToEditor,
              child: Text(
                "Next (${_selectedAssets.length})",
                style: const TextStyle(
                  color: Colors.blueAccent, 
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    if (_assets.isEmpty)
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              "No videos found",
                              style: TextStyle(color: Colors.white),
                            ),
                            const SizedBox(height: 10),
                            ElevatedButton(
                              onPressed: _requestPermissions,
                              child: const Text("Check Permissions"),
                            )
                          ],
                        ),
                      ),
                    if (_assets.isNotEmpty)
                      GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        itemCount: _assets.length,
                        itemBuilder: (context, index) {
                          final asset = _assets[index];
                          final isSelected = _selectedAssets.contains(asset);

                          return GestureDetector(
                            onTap: () => _toggleSelection(asset),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // Thumbnail
                                AssetEntityImage(
                                  asset,
                                  isOriginal: false,
                                  thumbnailSize: const ThumbnailSize.square(200),
                                  fit: BoxFit.cover,
                                ),
                                
                                // Duration Overlay
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    color: Colors.black.withValues(alpha: 0.7),
                                    child: Text(
                                      _formatDuration(asset.duration),
                                      style: const TextStyle(color: Colors.white, fontSize: 10),
                                    ),
                                  ),
                                ),

                                // Selection Overlay
                                if (isSelected)
                                  Container(
                                    color: Colors.blueAccent.withValues(alpha: 0.4),
                                    child: const Center(
                                      child: Icon(
                                        Icons.check_circle,
                                        color: Colors.white,
                                        size: 32,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                  ],
                ),
    );
  }
}
