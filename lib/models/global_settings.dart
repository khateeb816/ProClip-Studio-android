import 'package:flutter/material.dart';

/// Global Settings Model
/// All settings apply to ALL selected videos uniformly
class GlobalSettings {
  // Clip Settings
  double clipDuration;
  bool isAutoClipCount;
  int customClipCount;
  
  // Audio Settings
  String? audioPath;
  AudioMode audioMode;
  
  // Aspect Ratio & Fit
  String aspectRatio; // "9:16", "16:9", "1:1", "4:5", "Original"
  FitMode fitMode;
  
  // Transform Values (applied to all videos)
  double scale;
  double rotation;
  Offset translation;
  
  // Export Settings
  int exportHeight;
  int exportFps;
  
  GlobalSettings({
    this.clipDuration = 5.0,
    this.isAutoClipCount = true,
    this.customClipCount = 10,
    this.audioPath,
    this.audioMode = AudioMode.original,
    this.aspectRatio = "9:16",
    this.fitMode = FitMode.fitHeight,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.translation = Offset.zero,
    this.exportHeight = 1280,
    this.exportFps = 30,
  });
  
  GlobalSettings copyWith({
    double? clipDuration,
    bool? isAutoClipCount,
    int? customClipCount,
    String? audioPath,
    AudioMode? audioMode,
    String? aspectRatio,
    FitMode? fitMode,
    double? scale,
    double? rotation,
    Offset? translation,
    int? exportHeight,
    int? exportFps,
  }) {
    return GlobalSettings(
      clipDuration: clipDuration ?? this.clipDuration,
      isAutoClipCount: isAutoClipCount ?? this.isAutoClipCount,
      customClipCount: customClipCount ?? this.customClipCount,
      audioPath: audioPath ?? this.audioPath,
      audioMode: audioMode ?? this.audioMode,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      fitMode: fitMode ?? this.fitMode,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      translation: translation ?? this.translation,
      exportHeight: exportHeight ?? this.exportHeight,
      exportFps: exportFps ?? this.exportFps,
    );
  }
  
  /// Get output width based on aspect ratio and height
  int? getOutputWidth() {
    if (aspectRatio == "Original") return null;
    
    final parts = aspectRatio.split(":");
    if (parts.length != 2) return null;
    
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    if (w == null || h == null) return null;
    
    return (exportHeight * w / h).round();
  }
  
  /// Get crop rect for transform values
  Rect getCropRect(Size videoSize) {
    // Calculate crop based on scale, rotation, translation
    // This will be implemented based on the transform logic
    return const Rect.fromLTWH(0, 0, 1, 1);
  }
}

enum AudioMode {
  mix,       // Original + Background music
  background, // Background music only
  original,   // Original video sound only
  mute,       // No audio
}

enum FitMode {
  fitHeight,
  fitWidth,
  none,
}
