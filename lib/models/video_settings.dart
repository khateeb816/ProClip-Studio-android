import 'package:flutter/material.dart';
import 'video_metadata.dart';

class VideoSettings {
  final String videoPath;
  
  // Per-Video Crop & Transform State
  Rect? cropRect; // Normalized
  Matrix4? transform; // For restoring UI state
  double scale = 1.0;
  double tx = 0.0;
  double ty = 0.0;
  Size viewportSize;
  
  // Metadata
  VideoMetadata? metadata;

  // Performance
  String? proxyPath;
  ProxyStatus proxyStatus = ProxyStatus.none;

  // Audio (Added for Export Pipeline)
  String? audioPath;
  String audioMode = "mix";
  bool isMuted = false;
  String? thumbnailPath;
  String aspectRatio = '9:16';
  double? displayAR;

  VideoSettings({
    required this.videoPath,
    this.transform,
    this.cropRect,
    this.viewportSize = Size.zero,
    this.metadata,
    this.proxyPath,
  });
}

enum ProxyStatus {
  none,
  generating,
  ready,
  failed,
}
