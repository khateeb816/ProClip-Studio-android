class VideoMetadata {
  final double duration;
  final int width;
  final int height;
  final double fps;
  final int bitrate;
  final String codec;
  final int rotation;

  VideoMetadata({
    required this.duration,
    required this.width,
    required this.height,
    required this.fps,
    required this.bitrate,
    required this.codec,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() => {
    'duration': duration,
    'width': width,
    'height': height,
    'fps': fps,
    'bitrate': bitrate,
    'codec': codec,
    'rotation': rotation,
  };

  factory VideoMetadata.fromJson(Map<String, dynamic> json) => VideoMetadata(
    duration: json['duration'],
    width: json['width'],
    height: json['height'],
    fps: json['fps'],
    bitrate: json['bitrate'],
    codec: json['codec'],
    rotation: json['rotation'] ?? 0,
  );
}
