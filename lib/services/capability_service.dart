
class CapabilityService {
  static Future<Map<String, dynamic>> getDeviceCapabilities() async {
    // TODO: Implement real profiling
    // For now, return "High End" defaults to allow 1080p
    return {
      "maxResolution": 1080,
      "maxFps": 60,
      "encoder": "libx264",
      "tier": "high" 
    };
  }
}
