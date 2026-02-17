import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

class VideoCacheManager {
  static final VideoCacheManager _instance = VideoCacheManager._internal();
  factory VideoCacheManager() => _instance;
  VideoCacheManager._internal();

  List<AssetEntity> _cachedAssets = [];
  bool _isInitialized = false;
  
  List<AssetEntity> get cachedAssets => _cachedAssets;
  bool get isInitialized => _isInitialized;

  final _initializationCompleter = Completer<void>();
  Future<void> get initializationFuture => _initializationCompleter.future;

  Future<void> init() async {
    if (_isInitialized) return;
    
    try {
      debugPrint("📦 VideoCacheManager: Starting pre-load...");
      
      // Fetch albums
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        filterOption: FilterOptionGroup(
          videoOption: const FilterOption(
            durationConstraint: DurationConstraint(
              min: Duration(seconds: 1),
            ),
          ),
        ),
      );

      if (albums.isNotEmpty) {
        // Fetch first 200 videos
        _cachedAssets = await albums[0].getAssetListRange(start: 0, end: 200);
        debugPrint("📦 VideoCacheManager: Cached ${_cachedAssets.length} videos");
      } else {
        debugPrint("📦 VideoCacheManager: No video albums found");
      }
      
      _isInitialized = true;
      if (!_initializationCompleter.isCompleted) {
        _initializationCompleter.complete();
      }
    } catch (e) {
      debugPrint("❌ VideoCacheManager Error: $e");
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
