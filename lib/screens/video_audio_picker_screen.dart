import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:video_player/video_player.dart';
import '../services/ffmpeg_service.dart';
import '../services/video_cache_manager.dart';

/// Video Picker for Audio Extraction
/// Shows videos with preview player and extracts audio on selection
class VideoAudioPickerScreen extends StatefulWidget {
  const VideoAudioPickerScreen({super.key});
  
  @override
  State<VideoAudioPickerScreen> createState() => _VideoAudioPickerScreenState();
}

class _VideoAudioPickerScreenState extends State<VideoAudioPickerScreen> {
  List<AssetEntity> _videoAssets = [];
  AssetEntity? _selectedAsset;
  VideoPlayerController? _videoController;
  bool _isLoading = true;
  bool _isExtracting = false;

  @override
  void initState() {
    super.initState();
    _fetchVideos();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _fetchVideos() async {
    // Use the already cached and permission-handled videos
    if (!VideoCacheManager().isInitialized) {
      await VideoCacheManager().init();
    }
    
    if (mounted) {
      setState(() {
        _videoAssets = List.from(VideoCacheManager().cachedAssets.reversed);
        _isLoading = false;
      });
    }
  }

  Future<void> _onSelectAsset(AssetEntity asset) async {
    if (_selectedAsset?.id == asset.id && _videoController != null) return;

    // Capture old controller and null it immediately in setState
    final oldController = _videoController;
    
    setState(() {
      _selectedAsset = asset;
      _isLoading = true;
      _videoController = null;
    });

    await oldController?.dispose();
    
    if (!mounted) return;

    final file = await asset.file;
    if (file != null && mounted) {
      final controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
        if (mounted) {
          setState(() {
            _videoController = controller;
            _isLoading = false;
          });
          _videoController!.play();
          _videoController!.setLooping(true);
        } else {
          await controller.dispose();
        }
      } catch (e) {
        debugPrint("Error initializing video player: $e");
        if (mounted) {
          setState(() => _isLoading = false);
        }
        await controller.dispose();
      }
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _extractAndUse() async {
    if (_videoController == null) return;
    
    setState(() => _isExtracting = true);
    
    final file = await _selectedAsset!.file;
    if (file == null) {
      setState(() => _isExtracting = false);
      return;
    }

    final audioPath = await FFMpegService.extractAudioFromVideo(file.path);
    
    if (mounted) {
      setState(() => _isExtracting = false);
      if (audioPath != null) {
        Navigator.pop(context, audioPath);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Failed to extract audio")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Extract Audio from Video"),
        backgroundColor: Colors.black,
      ),
      body: Column(
        children: [
          // Preview Area
          Expanded(
            flex: 2,
            child: Container(
              color: Colors.black,
              child: _selectedAsset == null 
                  ? const Center(child: Text("Select a video to preview", style: TextStyle(color: Colors.white70)))
                  : !_isLoading && _videoController != null && _videoController!.value.isInitialized
                      ? Center(
                          child: AspectRatio(
                            aspectRatio: _videoController!.value.aspectRatio,
                            child: VideoPlayer(_videoController!),
                          ),
                        )
                      : const Center(child: CircularProgressIndicator()),
            ),
          ),
          
          // Video List
          Expanded(
            flex: 3,
            child: _isLoading && _videoAssets.isEmpty 
                ? const Center(child: CircularProgressIndicator())
                : GridView.builder(
                    padding: const EdgeInsets.all(2),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                       crossAxisCount: 3,
                       crossAxisSpacing: 2,
                       mainAxisSpacing: 2,
                    ),
                    itemCount: _videoAssets.length,
                    itemBuilder: (context, index) {
                      final asset = _videoAssets[index];
                      final isSelected = _selectedAsset?.id == asset.id;
                      return GestureDetector(
                        onTap: () => _onSelectAsset(asset),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AssetEntityImage(
                              asset,
                              isOriginal: false,
                              thumbnailSize: const ThumbnailSize.square(200),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: Colors.grey[900],
                                  child: const Center(
                                    child: Icon(Icons.broken_image, color: Colors.grey),
                                  ),
                                );
                              },
                            ),
                            if (isSelected)
                              Container(
                                color: Colors.cyanAccent.withValues(alpha: 0.3),
                                child: const Center(child: Icon(Icons.check_circle, color: Colors.cyanAccent)),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          
          if (_selectedAsset != null && _videoController != null && _videoController!.value.isInitialized)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isExtracting ? null : _extractAndUse,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.all(16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isExtracting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                      : const Text("Extract & Use Audio", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
