import 'dart:io';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/audio_cache_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// Audio File Picker Screen
/// Shows all audio files from device with preview player
class AudioPickerScreen extends StatefulWidget {
  const AudioPickerScreen({super.key});
  
  @override
  State<AudioPickerScreen> createState() => _AudioPickerScreenState();
}

class _AudioPickerScreenState extends State<AudioPickerScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<AssetEntity> _audioAssets = [];
  List<AssetEntity> _filteredAssets = [];
  bool _isLoading = true;
  String? _currentlyPlayingId;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndFetch();
    _searchController.addListener(_filterAudio);
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionsAndFetch() async {
    final PermissionStatus status;
    if (Platform.isAndroid && (await _getAndroidSdkInt()) >= 33) {
      status = await Permission.audio.request();
    } else {
      status = await Permission.storage.request();
    }

    if (status.isGranted) {
      _fetchAudio();
    } else {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Permission denied to access audio files.")),
        );
      }
    }
  }

  Future<int> _getAndroidSdkInt() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.version.sdkInt;
    }
    return 0;
  }

  Future<void> _fetchAudio() async {
    // 1. Check Cache First
    if (AudioCacheManager().isInitialized && AudioCacheManager().cachedAssets.isNotEmpty) {
      debugPrint("🎵 AudioPickerScreen: Using cached audio assets");
      if (mounted) {
        setState(() {
          _audioAssets = AudioCacheManager().cachedAssets;
          _filteredAssets = _audioAssets;
          _isLoading = false;
        });
      }
      return;
    }

    // 2. Fallback to fresh fetch if cache empty
    final result = await PhotoManager.requestPermissionExtend();
    if (!result.isAuth) {
      setState(() => _isLoading = false);
      return;
    }

    final albums = await PhotoManager.getAssetPathList(type: RequestType.audio);
    final Set<String> seenIds = {};
    List<AssetEntity> allAudio = [];
    
    for (var album in albums) {
      final assets = await album.getAssetListRange(start: 0, end: 1000);
      for (var asset in assets) {
        if (!seenIds.contains(asset.id)) {
          allAudio.add(asset);
          seenIds.add(asset.id);
        }
      }
    }

    allAudio.sort((a, b) => (b.createDateTime).compareTo(a.createDateTime));

    if (mounted) {
      setState(() {
        _audioAssets = allAudio;
        _filteredAssets = allAudio;
        _isLoading = false;
      });
    }
  }

  void _filterAudio() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredAssets = _audioAssets.where((asset) {
        final title = asset.title?.toLowerCase() ?? "";
        return title.contains(query);
      }).toList();
    });
  }

  Future<void> _togglePreview(AssetEntity asset) async {
    if (_currentlyPlayingId == asset.id) {
      await _audioPlayer.stop();
      setState(() => _currentlyPlayingId = null);
    } else {
      final file = await asset.file;
      if (file != null) {
        await _audioPlayer.stop();
        await _audioPlayer.play(DeviceFileSource(file.path));
        setState(() => _currentlyPlayingId = asset.id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text("Select Audio", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Search music...",
                hintStyle: const TextStyle(color: Colors.grey),
                prefixIcon: const Icon(Icons.search, color: Colors.cyanAccent),
                filled: true,
                fillColor: Colors.grey[900],
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
          : _filteredAssets.isEmpty
              ? const Center(
                  child: Text("No audio files found", style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _filteredAssets.length,
                  itemBuilder: (context, index) {
                    final asset = _filteredAssets[index];
                    final isPlaying = _currentlyPlayingId == asset.id;
                    final durationString = _formatDuration(Duration(seconds: asset.duration));

                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: isPlaying ? Colors.cyanAccent.withValues(alpha: 0.1) : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isPlaying ? Colors.cyanAccent : Colors.grey[800],
                          child: Icon(
                            isPlaying ? Icons.pause : Icons.music_note,
                            color: isPlaying ? Colors.black : Colors.white70,
                          ),
                        ),
                        title: Text(
                          asset.title ?? "Unknown Track",
                          style: TextStyle(
                            color: isPlaying ? Colors.cyanAccent : Colors.white,
                            fontWeight: isPlaying ? FontWeight.bold : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          durationString,
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                        onTap: () => _togglePreview(asset),
                        trailing: ElevatedButton(
                          onPressed: () async {
                            final file = await asset.file;
                            if (file != null && mounted) {
                              Navigator.pop(context, file.path);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.cyanAccent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          child: const Text("Use", style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }
}
