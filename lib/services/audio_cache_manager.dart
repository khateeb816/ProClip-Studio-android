import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

class AudioCacheManager {
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal();

  List<AssetEntity> _cachedAssets = [];
  bool _isInitialized = false;
  
  List<AssetEntity> get cachedAssets => _cachedAssets;
  bool get isInitialized => _isInitialized;

  final _initializationCompleter = Completer<void>();
  Future<void> get initializationFuture => _initializationCompleter.future;

  Future<void> init({Function(double)? onProgress}) async {
    if (_isInitialized) return;
    
    try {
      debugPrint("📦 AudioCacheManager: Starting pre-load...");
      
      // Fetch only audio
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.audio,
      );

      final Set<String> seenIds = {};
      List<AssetEntity> allAudio = [];
      if (albums.isNotEmpty) {
        for (var album in albums) {
          final count = await album.assetCountAsync;
          final assets = await album.getAssetListRange(start: 0, end: count);
          for (var asset in assets) {
            if (!seenIds.contains(asset.id)) {
              allAudio.add(asset);
              seenIds.add(asset.id);
            }
          }
        }
        
        // Sort by date
        allAudio.sort((a, b) => (b.createDateTime).compareTo(a.createDateTime));
        
        _cachedAssets = allAudio;
        debugPrint("📦 AudioCacheManager: Cached ${_cachedAssets.length} songs");
        
        onProgress?.call(1.0);
      } else {
        debugPrint("📦 AudioCacheManager: No audio albums found");
      }
      
      _isInitialized = true;
      if (!_initializationCompleter.isCompleted) {
        _initializationCompleter.complete();
      }
    } catch (e) {
      debugPrint("❌ AudioCacheManager Error: $e");
      if (!_initializationCompleter.isCompleted) {
        _initializationCompleter.complete(); // Complete anyway to unblock UI
      }
    }
  }

  void refresh() {
    _isInitialized = false;
    init();
  }
}
