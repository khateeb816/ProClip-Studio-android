import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../models/video_metadata.dart';
import 'ffmpeg_service.dart';

class MetadataService {
  static const String _cacheKey = 'video_metadata_cache';
  
  // In-memory cache for instant access during session
  static final Map<String, VideoMetadata> _memCache = {};
  
  static Future<VideoMetadata?> getMetadata(String videoPath) async {
    // 1. Check Memory Cache (Instant)
    if (_memCache.containsKey(videoPath)) {
      return _memCache[videoPath];
    }

    final prefs = await SharedPreferences.getInstance();
    final cacheStr = prefs.getString(_cacheKey);
    Map<String, dynamic> diskCache = {};
    
    if (cacheStr != null) {
      try {
        diskCache = jsonDecode(cacheStr);
      } catch (e) {
        print("Error decoding metadata cache: $e");
      }
    }
    
    // 2. Check Disk Cache
    if (diskCache.containsKey(videoPath)) {
      final meta = VideoMetadata.fromJson(diskCache[videoPath]);
      _memCache[videoPath] = meta; // Populate memory cache
      return meta;
    }
    
    // 3. Extract via FFprobe (Async)
    // Note: FFMpegService.getVideoMetadata uses FFprobeKit which is async and uses platform channels.
    // It does not block the UI thread like MediaMetadataRetriever might.
    final metadata = await FFMpegService.getVideoMetadata(videoPath);
    
    if (metadata != null) {
      // Update Caches
      _memCache[videoPath] = metadata;
      diskCache[videoPath] = metadata.toJson();
      await prefs.setString(_cacheKey, jsonEncode(diskCache));
    }
    
    return metadata;
  }
  
  static Future<String?> getThumbnail(String videoPath) async {
    final tempDir = await getTemporaryDirectory();
    final fileName = videoPath.split('/').last.split('.').first;
    final thumbPath = "${tempDir.path}/thumb_$fileName.jpg";
    
    if (await File(thumbPath).exists()) {
      return thumbPath;
    }
    
    // Generate thumbnail at 1 second mark if it doesn't exist
    // -ss 1 -i input -vframes 1 output
    final cmd = "-ss 00:00:01 -i \"$videoPath\" -vframes 1 -q:v 2 \"$thumbPath\"";
    final session = await FFmpegKit.execute(cmd);
    final returnCode = await session.getReturnCode();
    
    if (ReturnCode.isSuccess(returnCode)) {
      return thumbPath;
    }
    return null;
  }

  // Pre-cache metadata for a list of files
  static Future<void> preCache(List<File> files) async {
    for (var file in files) {
      getMetadata(file.path); // Fire and forget
      getThumbnail(file.path); // Fire and forget
    }
  }
}
