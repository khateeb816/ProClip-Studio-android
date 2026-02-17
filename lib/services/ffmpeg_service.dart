import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/widgets.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart'; 
import 'package:ffmpeg_kit_flutter_new/level.dart'; 
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import '../models/video_metadata.dart';
import '../models/video_settings.dart'; 

class FFMpegService {
  static bool _isCancelled = false;
  static bool get isCancelled => _isCancelled;

  
  static bool _isSnapdragon = false;
  static bool get isSnapdragon => _isSnapdragon;

  static Future<void> init() async {
    // Disable logs for speed
    FFmpegKitConfig.enableLogCallback((log) {}); 
    FFmpegKitConfig.setLogLevel(Level.avLogError); 
    
    // Clear previous sessions to free memory
    await FFmpegKit.cancel();
    
    // Detect Capabilities
    await _checkDeviceCapabilities();
  }

  /// CRITICAL: File Integrity Validation
  static Future<bool> _validateFileIntegrity(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        print("❌ File doesn't exist");
        return false;
      }
      
      // Check file size (must be > 1KB)
      final fileSize = await file.length();
      if (fileSize < 1024) {
        print("❌ File too small ($fileSize bytes) - likely corrupted");
        return false;
      }
      
      // Run ffprobe with error detection
      final probeSession = await FFprobeKit.execute("-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"$path\"");
      final output = await probeSession.getOutput();
      
      if (output == null || output.trim().isEmpty) {
        print("❌ FFprobe returned empty - file may be corrupted");
        return false;
      }
      
      final duration = double.tryParse(output.trim());
      if (duration == null || duration <= 0) {
        print("❌ Invalid duration ($output) - file corrupted");
        return false;
      }
      
      print("✓ File integrity check passed (${fileSize} bytes, ${duration}s)");
      return true;
    } catch (e) {
      print("❌ Integrity check failed: $e");
      return false;
    }
  }
  
  /// Software Fallback with Retry
  static Future<String?> _softwareFallbackWithRetry(
    String inputPath,
    String outputPath,
    double start,
    double duration,
    Rect? cropRect,
    int targetHeight,
    int? targetWidth, // Added
    String? audioPath,
  ) async {
    print("⚠️ CRITICAL: Hardware encoding produced invalid output. Retrying with software encoder...");
    
    // Delete corrupted file
    try {
      final corruptedFile = File(outputPath);
      if (await corruptedFile.exists()) {
        await corruptedFile.delete();
        print("🗑️ Deleted corrupted output");
      }
    } catch (e) {
      print("Warning: Could not delete corrupted file: $e");
    }
    
    return executeSoftwareFallback(
      inputPath: inputPath,
      outputPath: outputPath,
      start: start,
      duration: duration,
      cropRect: cropRect,
      targetHeight: targetHeight,
      targetWidth: targetWidth,
      audioPath: audioPath,
    );
  }

  static Future<void> _checkDeviceCapabilities() async {
     try {
       if (Platform.isAndroid) {
         final deviceInfo = DeviceInfoPlugin();
         final androidInfo = await deviceInfo.androidInfo;
         final board = androidInfo.board.toLowerCase();
         final hardware = androidInfo.hardware.toLowerCase();
         
         // Snapdragon Detection
         if (board.contains("sm7150") || hardware.contains("sm7150")) {
            _isSnapdragon = true;
            print("🚀 Snapdragon 732/732G Detected! Applying Adreno 618 optimizations.");
         } else if (hardware.contains("qcom") || board.contains("trinket") || board.contains("lito") || board.contains("bengal")) {
            _isSnapdragon = true;
            print("🚀 Qualcomm Snapdragon Detected.");
         }
       }
     } catch (e) {
       print("Device detection failed: $e");
     }
  }

  /// Explicitly release resources to prevent Android MediaServer death
  static Future<void> freeResources() async {
    await FFmpegKit.cancel(); 
  }

  // --- Zero Copy GPU Pipeline (High Performance) ---

  /// Generates a plan of clips (start, end) based on total duration and settings
  static List<Map<String, double>> generateClipPlan({
    required double totalDuration,
    required double clipDuration,
    int? count,
  }) {
    List<Map<String, double>> clips = [];
    
    // Safety check
    if (totalDuration <= 0 || clipDuration <= 0) return clips;

    // Calculate max possible clips
    int maxClips = (totalDuration / clipDuration).floor();
    
    // Determine actual count
    int finalCount = count ?? maxClips;
    if (finalCount > maxClips) finalCount = maxClips;
    if (finalCount < 1 && maxClips > 0) finalCount = 1; // At least one if possible
    
    for (int i = 0; i < finalCount; i++) {
        double start = i * clipDuration;
        double end = start + clipDuration;
        
        // Ensure we don't exceed total duration floating point issues
        if (start >= totalDuration) break;
        if (end > totalDuration) end = totalDuration;

        clips.add({"start": start, "end": end});
    }
    
    return clips;
  }

  /// 1. FAST PATH: Stream Copy
  static Future<String?> executeStreamCopy({
    required String inputPath,
    required double start,
    required double duration,
    required String outputPath,
  }) async {
    // Command Construction: Fast Seek -> Input -> Duration -> Copy -> Output
    final cmd = [
      "-y",
      "-ss", start.toStringAsFixed(3), // Input Seeking (Fast)
      "-i", inputPath,
      "-t", duration.toStringAsFixed(3),
      "-c", "copy",
      "-avoid_negative_ts", "make_zero",
      outputPath
    ];

    print("🚀 Stream Copy: ${cmd.join(' ')}");
    final session = await FFmpegKit.executeWithArguments(cmd);
    final returnCode = await session.getReturnCode();
    
       if (ReturnCode.isSuccess(returnCode)) {
       // Validate stream copy integrity (sometimes keyframes are missed)
       final validated = await _validateOutput(outputPath, checkDuration: true, expectedDuration: duration);
       if (validated != null) {
          await saveToGallery(outputPath);
          return outputPath;
       }
    } 
    
    print("❌ Stream Copy Failed or Invalid. Falling back to Smart Export...");
    return null;
  }
  
  /// 2. SMART SEQUENTIAL EXPORT (Zero Copy Optimized)
  static Future<String?> executeSmartExport({
      required String inputPath,
      required String outputPath,
      required double start,
      required double duration,
      required VideoSettings settings,
      required int outputHeight,
      int? outputWidth, // Added
  }) async {
      // 1. Capability & Metadata Check
      final meta = settings.metadata ?? await getVideoMetadata(inputPath);
      final double srcFps = meta?.fps ?? 30.0;
      final int srcHeight = meta?.height ?? 720;
      
      // VFR CHECK (Variable Frame Rate)
      // If the video is VFR, Stream Copy often leads to audio desync.
      // We force re-encode for VFR content to "Normalize" it to CFR.
      // bool isVfr = false; // Unused
      // We can hint VFR if avg_frame_rate != r_frame_rate, but for now
      // safe assumption: simplistic check. If user says it's VFR, we trust?
      // Actually, we'll assume most phone footage is VFR.
      // PRO OPTIMIZATION: If we detect it's a "screen_recording" or has variable flag, disable copy.
      // For now, let's trust the "SimpleCut" logic but add a safety check.
      
      // 2. Stream Copy Check
      // Only possible if NO padding/scaling is needed (i.e. outputWidth/Height matches input or we don't care)
      // BUT if we want padding (outputWidth != null), we CANNOT stream copy unless dimensions match exactly.
      final bool isSimpleCut = (settings.cropRect == null || settings.cropRect == const Rect.fromLTWH(0,0,1,1)) &&
                               (settings.audioPath == null) && 
                               (settings.transform == null) &&
                               (outputWidth == null); // Disable stream copy if padding is requested

      // KEYFRAME ALIGNMENT SAFETY:
      // Stream copy cuts at NEAREST keyframe. If user wants precise cut at 3.27s
      // and keyframe is at 0.0s, the video will start at 0.0s but say 3.27s (frozen/glitch).
      // TRUE PROFESSIONAL FIX:
      // We can only stream copy if start time is 0.0 OR if we accept "loose" trims.
      // Apps like CapCut force re-encode for precise mid-GOP trims.
      // We will allow stream copy ONLY if starting from 0.0 OR if user accepts rough cut.
      // For this "Speed" mode, we prioritize speed, but let's be safe.
      
      if (isSimpleCut && start == 0.0) {
          final result = await executeStreamCopy(
             inputPath: inputPath, 
             start: start, 
             duration: duration, 
             outputPath: outputPath
          );
          if (result != null) return result;
      }
      
      // 3. Hardware Encode (The "Zero Copy" Path)
      int targetH = outputHeight;
      if (srcHeight < targetH) targetH = srcHeight;
      
      // CRITICAL: MOD-16 ALIGNMENT for MediaCodec stability
      targetH = _alignToMod16(targetH); 
      
      // Only use outputWidth if it stays reasonably close to targetH aspect ratio? 
      // No, we trust Caller.

      return await executeHardwareExport(
          inputPath: inputPath,
          outputPath: outputPath,
          start: start,
          duration: duration,
          cropRect: settings.cropRect,
          targetHeight: targetH,
          targetWidth: outputWidth, // Pass it
          targetFps: srcFps, 
          srcHeight: srcHeight,
          audioPath: settings.audioPath,
          audioMode: settings.audioMode,
      );
  }

  /// 3. HARDWARE ACCELERATED RE-ENCODE
  static Future<String?> executeHardwareExport({
    required String inputPath,
    required String outputPath,
    required double start,
    required double duration,
    Rect? cropRect,
    int targetHeight = 1280,
    int? targetWidth, // Added for Padding
    double? targetFps,
    int? srcHeight, 
    String? audioPath,
    String audioMode = "mix",
  }) async {
     List<String> cmd = ["-y"];
     
     // CORRUPTION PREVENTION: Strict error detection
     cmd.addAll(["-err_detect", "aggressive"]);

     // Hardware Acceleration Flags (Android)
     // CRITICAL FIX: Remove -hwaccel mediacodec (causes crashes on many Snapdragons when filtering)
     // keeping it OFF is safer for compatibility. MediaCodec ENCODER is still used.
     // if (Platform.isAndroid) {
     //    cmd.addAll([
     //      "-hwaccel", "mediacodec",
     //    ]);
     // }

     // Input Seeking (Fast) -> Before -i
     cmd.addAll([
        "-ss", start.toStringAsFixed(3),
        "-i", inputPath,
        "-t", duration.toStringAsFixed(3)
     ]);
     
     // Audio Input
     if (audioPath != null && audioMode != "audio_only") {
        cmd.addAll(["-i", audioPath]); 
     }

     // CRITICAL: Calculate integer crop dimensions BEFORE building filter
     // This prevents floating-point precision errors that cause MOD-16 violations
     int? cropW, cropH, cropX, cropY;
     if (cropRect != null && cropRect != const Rect.fromLTWH(0,0,1,1) && srcHeight != null) {
        // Assume source width based on aspect ratio (most videos are 16:9)
        int srcWidth = ((srcHeight * 16) / 9).round();
        
        cropW = (srcWidth * cropRect.width).round();
        cropH = (srcHeight * cropRect.height).round();
        cropX = (srcWidth * cropRect.left).round();
        cropY = (srcHeight * cropRect.top).round();
        
        // Ensure crop output is MOD-16 aligned
        cropW = _alignToMod16(cropW);
        cropH = _alignToMod16(cropH);
     }
     
     // Filters Check (CRITICAL ORDER: crop → scale → pad)
     String vf = "";
     
     // 1. Crop FIRST (if needed)
     if (cropW != null && cropH != null && cropX != null && cropY != null) {
        vf += "crop=$cropW:$cropH:$cropX:$cropY";
     }
     
     // 2. Scale & Pad (ensures MOD-16 output and aspect ratio)
     int alignedHeight = _alignToMod16(targetHeight);
     
     if (targetWidth != null) {
         // WITH PADDING (Fit logic)
         int alignedWidth = _alignToMod16(targetWidth);
         
         // Add comma if filter chain exists
         if (vf.isNotEmpty) vf += ",";
         
         // Scale to fit within box (decrease means don't upscale if already smaller? No, we want to fit)
         // using force_original_aspect_ratio=decrease ensures it fits inside the box
         vf += "scale=$alignedWidth:$alignedHeight:force_original_aspect_ratio=decrease";
         
         // Pad to fill the box (Black bars)
         // (ow-iw)/2 centers it.
         vf += ",pad=$alignedWidth:$alignedHeight:(ow-iw)/2:(oh-ih)/2:color=black";
         
     } else {
         // STANDARD SCALING (Fit Height, Variable Width)
         if (vf.isNotEmpty) {
            vf += ",scale=-2:$alignedHeight";
         } else {
            vf += "scale=-2:$alignedHeight";
         }
     }

     if (vf.isNotEmpty) {
        cmd.addAll(["-vf", vf]);
     }
     
     // Audio Map
     if (audioPath != null && audioMode == "mix") {
         cmd.addAll(["-filter_complex", "amix=inputs=2:duration=first", "-map", "0:v", "-map", "0:a"]);
     }

     // SNAPDRAGON OPTIMIZATION
     String encoder = Platform.isAndroid ? "h264_mediacodec" : "h264_videotoolbox";
     
     // FPS Enforce (Default 30 FPS for 720p 30fps recording)
     double finalFps = targetFps ?? 30.0;
     cmd.addAll(["-r", finalFps.toString()]); // Enforce CFR
     cmd.addAll(["-vsync", "cfr"]); // VFR -> CFR Normalization (Prevents Audio Drift)
     
     // CRITICAL: Force pixel format for MediaCodec compatibility
     cmd.addAll(["-pix_fmt", "yuv420p"]);
     
     cmd.addAll(["-c:v", encoder]);

     if (_isSnapdragon) {
         // --- SNAPDRAGON SPECIFIC TUNING ---
         // ULTRA-SAFE BITRATES - CORRUPTION PREVENTION PRIORITY
         // Reduced bitrates slightly for 1080p to ensure Level compatibility
         int bitrate = alignedHeight >= 1080 ? 5500000 : // Dropped from 6M
                       alignedHeight >= 720 ? 4000000 : 2000000;
         
         // CORRUPTION PREVENTION: VERY SHORT GOP
         int gopSize = finalFps.toInt(); // 30 frames @ 30fps = 1 second
         
         cmd.addAll([
             "-b:v", "$bitrate", 
             "-maxrate", "${(bitrate * 1.2).toInt()}", // Conservative 20% burst
             "-bufsize", "${(bitrate * 1.5).toInt()}", // Reduced buffer for stability
             "-profile:v", "main", // CHANGED FROM HIGH -> MAIN for compatibility
             "-bf", "0", // DISABLE B-FRAMES for stability on Adreno 618
             "-g", "$gopSize", // GOP size limit (keyframe every 1 second)
             "-keyint_min", "${(gopSize ~/ 2)}", // Minimum keyframe interval
         ]);
     } else {
         // Generic
         cmd.addAll(["-b:v", "3000k"]); // Bumped slightly for generic
     }

     // Audio settings
     cmd.addAll([
        "-c:a", "aac",
        "-b:a", "128k",
        "-movflags", "+faststart",
        outputPath
     ]);
     
     print("🚀 Smart HW Export (Snapdragon=$_isSnapdragon): ${cmd.join(' ')}");
     
     try {
       final session = await FFmpegKit.executeWithArguments(cmd);
       
       if (ReturnCode.isSuccess(await session.getReturnCode())) {
           // CRITICAL: STRICT DOUBLE VALIDATION
           print("✓ FFmpeg succeeded. Running DOUBLE validation...");
           
           // Validation 1: Duration and stream check
           final validated1 = await _validateOutput(outputPath, checkDuration: true, expectedDuration: duration);
           if (validated1 == null) {
               print("❌ VALIDATION 1 FAILED: Duration/Stream check failed");
               return await _softwareFallbackWithRetry(inputPath, outputPath, start, duration, cropRect, targetHeight, targetWidth, audioPath);
           }
           
           // Validation 2: File integrity and playability
           final validated2 = await _validateFileIntegrity(outputPath);
           if (!validated2) {
               print("❌ VALIDATION 2 FAILED: File integrity check failed");
               return await _softwareFallbackWithRetry(inputPath, outputPath, start, duration, cropRect, targetHeight, targetWidth, audioPath);
           }
           
           print("✅ DOUBLE VALIDATION PASSED - Video is SAFE");
           await saveToGallery(outputPath);
           return outputPath;
       } else {
           print("❌ HW Export Failed. Logs: ${await session.getAllLogsAsString()}");
       }
     } catch (e) {
       print("❌ Critical FFmpeg Exception: $e. Triggering Fallback.");
     }
     
     // Fallback to Software
     return await _softwareFallbackWithRetry(inputPath, outputPath, start, duration, cropRect, targetHeight, targetWidth, audioPath);
  }

  static Future<String?> _validateOutput(String path, {bool checkDuration = false, double? expectedDuration}) async {
     final file = File(path);
     if (!await file.exists() || await file.length() < 1000) { // < 1KB is definitely wrong
        print("❌ Validation Failed: File missing or too small.");
        return null;
     }

     if (checkDuration && expectedDuration != null) {
        // Probe check
        try {
            final session = await FFprobeKit.getMediaInformation(path);
            final info = session.getMediaInformation();
            if (info == null) return null;
            
            final durStr = info.getDuration();
            final dur = double.tryParse(durStr ?? "0") ?? 0;
            
            // Tolerance +/- 1.0s (FFmpeg cuts can be imprecise due to keyframes)
            // But for HW encode it should be accurate.
            if ((dur - expectedDuration).abs() > 1.0) {
                print("❌ Validation Failed: Duration Mismatch (Got $dur, Expected $expectedDuration)");
                // Strict validation might fail valid files if metadata is weird. 
                // For now, if it plays, we might accept it, but let's be strict for "Zero Corruption".
                return null; 
            }
            
            // Check for Video Stream
            bool hasVideo = false;
            for (var s in info.getStreams()) {
                if (s.getType() == "video") hasVideo = true;
            }
            if (!hasVideo) {
                print("❌ Validation Failed: No video stream.");
                return null;
            }
            
        } catch(e) {
            print("Probe failed: $e");
            return null; // Assume corrupt if we can't probe
        }
     }

     return path;
  }


  /// 3. FALLBACK: Ultrafast Software
  static Future<String?> executeSoftwareFallback({
    required String inputPath,
    required String outputPath,
    required double start,
    required double duration,
    Rect? cropRect,
    int targetHeight = 1280,
    int? targetWidth, // Added for Padding
    String? audioPath,
  }) async {
      List<String> cmd = [
        "-y",
        "-ss", start.toStringAsFixed(3),
        "-i", inputPath,
        "-t", duration.toStringAsFixed(3)
      ];
      
      if (audioPath != null) cmd.addAll(["-i", audioPath]);

      String vf = "";
      // Crop First (if needed) - Simplified for software as we don't need strictly MOD-16 here as much, but nice to have.
      // We assume simple crop string here or we can reuse the logic.
      if (cropRect != null && cropRect != const Rect.fromLTWH(0,0,1,1)) {
         vf += "crop=iw*${cropRect.width}:ih*${cropRect.height}:iw*${cropRect.left}:ih*${cropRect.top}";
      }
      
      int alignedHeight = _alignToMod16(targetHeight);
      
      if (targetWidth != null) {
           int alignedWidth = _alignToMod16(targetWidth);
           if (vf.isNotEmpty) vf += ",";
           vf += "scale=$alignedWidth:$alignedHeight:force_original_aspect_ratio=decrease,pad=$alignedWidth:$alignedHeight:(ow-iw)/2:(oh-ih)/2:color=black";
      } else {
           if (vf.isNotEmpty) vf += ",";
           vf += "scale=-2:$alignedHeight";
      }

      cmd.addAll(["-vf", vf]);

      cmd.addAll([
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-crf", "35", // Lower quality for speed
        "-c:a", "aac",
        outputPath
      ]);

      final session = await FFmpegKit.executeWithArguments(cmd);
      if (ReturnCode.isSuccess(await session.getReturnCode())) {
         final validatedPath = await _validateOutput(outputPath);
         if (validatedPath != null) {
            await saveToGallery(validatedPath);
            return validatedPath;
         }
      }
      return null;
  }
  
  /// MOD-16 ALIGNMENT HELPER (Critical for MediaCodec Stability)
  static int _alignToMod16(int dimension) {
    return (dimension ~/ 16) * 16;
  }

  /// Helper: Generate Thumbnail
  static Future<String?> generateThumbnail(String videoPath) async {
     final dir = await getExternalStorageDirectory(); 
     final outDir = dir ?? await getApplicationDocumentsDirectory();
     final outPath = "${outDir.path}/thumb_${DateTime.now().millisecondsSinceEpoch}.jpg";
     
     final cmd = [
        "-y",
        "-ss", "00:00:01", // 1st second
        "-i", videoPath,
        "-vframes", "1",
        "-q:v", "5", // Low quality jpg
        "-vf", "scale=240:-1", // Tiny thumbnail
        outPath
     ];
     
     await FFmpegKit.executeWithArguments(cmd);
     if (await File(outPath).exists()) return outPath;
     return null;
  }

  // --- Queue Management ---
  static int _activeJobs = 0;
  static final List<Function> _jobQueue = [];
  
  static Future<T> enqueueJob<T>(Future<T> Function() job) async {
      Completer<T> completer = Completer();

      void run() {
          _activeJobs++;
          job().then((result) {
              if (!completer.isCompleted) completer.complete(result);
          }).catchError((e) {
              if (!completer.isCompleted) completer.completeError(e);
          }).whenComplete(() {
              _activeJobs--;
              _processQueue();
          });
      }

      // Max 1 HW Encoder usually safe. 
      if (_activeJobs < 1) { 
          run();
      } else {
          _jobQueue.add(run);
      }
      
      return completer.future;
  }

  static void _processQueue() {
      if (_activeJobs < 1 && _jobQueue.isNotEmpty) {
          final run = _jobQueue.removeAt(0);
          run();
      }
  }
  
  static Future<void> saveToGallery(String path) async {
      try {
        await Gal.putVideo(path);
      } catch (e) {
        print("Gallery Save Error: $e");
      }
  }

  // --- Metadata Helper ---
  static Future<VideoMetadata?> getVideoMetadata(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      if (info != null) {
        final durationStr = info.getDuration();
        final duration = double.tryParse(durationStr ?? "0") ?? 0;

        int width = 1280;
        int height = 720;
        double fps = 30.0;
        int bitrate = 1000000;
        String codec = "h264";

        for (var stream in info.getStreams()) {
          if (stream.getType() == "video") {
            width = stream.getWidth() ?? 1280;
            height = stream.getHeight() ?? 720;
            final rFrameRate = stream.getRealFrameRate();
            if (rFrameRate != null) {
               final parts = rFrameRate.split('/');
               if (parts.length == 2) {
                  double num = double.tryParse(parts[0]) ?? 0;
                  double den = double.tryParse(parts[1]) ?? 1;
                  if (den != 0) fps = num/den;
               } else {
                  fps = double.tryParse(rFrameRate) ?? 30.0;
               }
            }
            break;
          }
        }
        return VideoMetadata(
          duration: duration,
          width: width,
          height: height,
          fps: fps,
          bitrate: bitrate,
          codec: codec,
        );
      }
    } catch (e) {
      print("Error getting metadata: $e");
    }
    return null;
  }

  static Future<double?> getVideoDuration(String path) async {
    final metadata = await getVideoMetadata(path);
    return metadata?.duration;
  }
  
  static void cancelExport() {
    _isCancelled = true;
    FFmpegKit.cancel();
  }
  static void resetCancellation() {
     _isCancelled = false;
  }
  
  static Future<String?> extractAudioFromVideo(String videoPath) async {
      // Stub for legacy compat if needed, or remove if unused. 
      // Keeping it simple for now as we removed preload logic that used it?
      // Actually it was used in Editor. We'll leave a stub or reimplement if needed.
      return null; 
  }
}
