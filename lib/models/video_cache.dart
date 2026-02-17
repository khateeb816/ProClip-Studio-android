import 'dart:io';
import 'video_metadata.dart';

/// Video Cache Item
/// Stores pre-loaded video info and thumbnail for instant display
class VideoCacheItem {
  final String path;
  final VideoMetadata metadata;
  final File? thumbnail;
  final DateTime loadedAt;
  
  VideoCacheItem({
    required this.path,
    required this.metadata,
    this.thumbnail,
    DateTime? loadedAt,
  }) : loadedAt = loadedAt ?? DateTime.now();
}

/// Video Cache Service
/// Manages pre-loading and caching of all videos
class VideoCacheService {
  static final Map<String, VideoCacheItem> _cache = {};
  static bool _isLoading = false;
  static double _loadProgress = 0.0;
  
  static bool get isLoading => _isLoading;
  static double get loadProgress => _loadProgress;
  static List<VideoCacheItem> get allVideos => _cache.values.toList();
  
  /// Load all videos from gallery
  static Future<void> loadAllVideos(
    Future<List<File>> Function() getVideos,
    Future<VideoMetadata?> Function(String) getMetadata,
    Future<String?> Function(String) generateThumbnail,
    Function(double)? onProgress,
  ) async {
    _isLoading = true;
    _loadProgress = 0.0;
    _cache.clear();
    
    try {
      final videos = await getVideos();
      final total = videos.length;
      
      for (int i = 0; i < videos.length; i++) {
        final video = videos[i];
        
        // Get metadata
        final metadata = await getMetadata(video.path);
        if (metadata == null) continue;
        
        // Generate thumbnail
        final thumbPath = await generateThumbnail(video.path);
        final thumbnail = thumbPath != null ? File(thumbPath) : null;
        
        // Cache
        _cache[video.path] = VideoCacheItem(
          path: video.path,
          metadata: metadata,
          thumbnail: thumbnail,
        );
        
        // Update progress
        _loadProgress = (i + 1) / total;
        onProgress?.call(_loadProgress);
      }
    } finally {
      _isLoading = false;
      _loadProgress = 1.0;
    }
  }
  
  /// Get cached video
  static VideoCacheItem? getVideo(String path) {
    return _cache[path];
  }
  
  /// Clear cache
  static void clearCache() {
    _cache.clear();
    _loadProgress = 0.0;
  }
  
  /// Clear old thumbnails
  static Future<void> clearThumbnails() async {
    for (final item in _cache.values) {
      if (item.thumbnail != null && await item.thumbnail!.exists()) {
        try {
          await item.thumbnail!.delete();
        } catch (e) {
          print("Failed to delete thumbnail: $e");
        }
      }
    }
  }
}
