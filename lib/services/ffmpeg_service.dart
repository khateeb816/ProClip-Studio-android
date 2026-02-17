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

  static Future<void> init() async {
    // Disable logs for speed
    FFmpegKitConfig.enableLogCallback((log) {}); 
    FFmpegKitConfig.setLogLevel(Level.avLogError); 
    
    // Clear previous sessions to free memory
    await FFmpegKit.cancel();
  }
  
  /// Cancel all running FFmpeg jobs
  static Future<void> cancelAllJobs() async {
    _isCancelled = true;
    await FFmpegKit.cancel();
  }
  
  /// Reset cancellation flag
  static void resetCancellation() {
    _isCancelled = false;
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
  
  /// Extract audio from video file
  static Future<String?> extractAudioFromVideo(String videoPath) async {
    try {
      final dir = await getExternalStorageDirectory();
      final outDir = dir ?? await getApplicationDocumentsDirectory();
      final outPath = "${outDir.path}/extracted_${DateTime.now().millisecondsSinceEpoch}.aac";

      final cmd = [
        "-y",
        "-i", videoPath,
        "-vn", // No video
        "-acodec", "copy", // Try to copy stream first
        outPath
      ];

      print("🚀 Extracting Audio (Copy): ${cmd.join(' ')}");
      final session = await FFmpegKit.executeWithArguments(cmd);
      if (ReturnCode.isSuccess(await session.getReturnCode())) {
        return outPath;
      }

      // Fallback to re-encoding if copy fails
      final retryCmd = [
        "-y",
        "-i", videoPath,
        "-vn",
        "-ac", "2",
        "-ar", "44100",
        "-ab", "128k",
        "-acodec", "aac",
        outPath
      ];
      print("🚀 Extracting Audio (Encode): ${retryCmd.join(' ')}");
      final retrySession = await FFmpegKit.executeWithArguments(retryCmd);
      if (ReturnCode.isSuccess(await retrySession.getReturnCode())) {
        return outPath;
      }
    } catch (e) {
      print("❌ Audio Extraction Failed: $e");
    }
    return null;
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
  
  /// 2. SMART SEQUENTIAL EXPORT (Software Encoding)
  static Future<String?> executeSmartExport({
      required String inputPath,
      required String outputPath,
      required double start,
      required double duration,
      required VideoSettings settings,
      required int outputHeight,
      int? outputWidth,
  }) async {
      // 1. Capability & Metadata Check
      final meta = settings.metadata ?? await getVideoMetadata(inputPath);
      final int srcHeight = meta?.height ?? 720;
      
      // 2. Stream Copy Check (Fast Path)
      // Only possible if NO modifications needed
      final bool isSimpleCut = (settings.cropRect == null || settings.cropRect == const Rect.fromLTWH(0,0,1,1)) &&
                               (settings.audioPath == null) && 
                               (settings.transform == null) &&
                               (outputWidth == null);

      // Stream copy ONLY if starting from 0.0 for keyframe alignment
      if (isSimpleCut && start == 0.0) {
          final result = await executeStreamCopy(
             inputPath: inputPath, 
             start: start, 
             duration: duration, 
             outputPath: outputPath
          );
          if (result != null) return result;
      }
      
      // 3. Software Re-Encode (libx264)
      int targetH = outputHeight;
      if (srcHeight < targetH) targetH = srcHeight;
      
      // MOD-16 ALIGNMENT for encoder stability
      targetH = _alignToMod16(targetH);

      return await executeSoftwareFallback(
          inputPath: inputPath,
          outputPath: outputPath,
          start: start,
          duration: duration,
          cropRect: settings.cropRect,
          targetHeight: targetH,
          targetWidth: outputWidth,
          audioPath: settings.audioPath,
          audioMode: settings.audioMode,
          // CRITICAL FIX: Respect the explicit isMuted flag from settings
          // If settings.isMuted is true, we MUST mute.
          // Otherwise, fall back to auto-detection (if no audio mode/path).
          isMuted: settings.isMuted || (settings.audioMode == null && settings.audioPath == null),
      );
  }

  /// 3. SOFTWARE ENCODER (libx264)

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


  static Future<String?> executeSoftwareFallback({
    required String inputPath,
    required String outputPath,
    required double start,
    required double duration,
    Rect? cropRect,
    int targetHeight = 1280,
    int? targetWidth,
    String? audioPath,
    String? audioMode, // mix, background, original
    bool isMuted = false,
  }) async {
      List<String> cmd = [
        "-y",
        "-ss", start.toStringAsFixed(3),
        "-i", inputPath,
      ];

      if (audioPath != null) {
        cmd.addAll(["-i", audioPath]);
      }

      cmd.addAll(["-t", duration.toStringAsFixed(3)]);

      String vf = "";
      // Resolve Input Dimensions for detailed crop calculation
      int iw = 1280; // Default fallback
      int ih = 720;
      try {
        final meta = await getVideoMetadata(inputPath);
        if (meta != null) {
          iw = meta.width;
          ih = meta.height;
        }
      } catch (e) {
        print("⚠️ Failed to get metadata for crop calc: $e");
      }

      // Crop First (if needed)
      bool needsCrop = false;
      String cropFilter = "";
      
      if (cropRect != null) {
         // Tolerance check (allow 1% margin of error for "full screen")
         if (cropRect.width < 0.99 || cropRect.height < 0.99 || cropRect.left > 0.01 || cropRect.top > 0.01) {
            needsCrop = true;
            
            // Calculate Absolute Pixels
            int cw = (cropRect.width * iw).round();
            int ch = (cropRect.height * ih).round();
            int cx = (cropRect.left * iw).round();
            int cy = (cropRect.top * ih).round();
            
            // Safety Clamps (Ensure we don't go out of bounds)
            cw = cw.clamp(16, iw); // Min 16px width
            ch = ch.clamp(16, ih); // Min 16px height
            cx = cx.clamp(0, iw - cw);
            cy = cy.clamp(0, ih - ch);
            
            // Ensure even numbers for some codecs (though crop usually handles odd, good practice)
            cw = (cw ~/ 2) * 2;
            ch = (ch ~/ 2) * 2;
            cx = (cx ~/ 2) * 2;
            cy = (cy ~/ 2) * 2;

            cropFilter = "crop=$cw:$ch:$cx:$cy";
         }
      }

      if (needsCrop) {
         vf += cropFilter;
         print("✂️ Applying Crop (Absolute): $cropFilter (Source: ${iw}x${ih})");
      } else {
         print("ℹ️ Skipping Crop (Full Screen)");
      }
      
      int alignedHeight = _alignToMod16(targetHeight);
      
      if (targetWidth != null) {
           int alignedWidth = _alignToMod16(targetWidth);
           if (vf.isNotEmpty) vf += ",";
           
           // If we have applied a custom crop (Zoom), we likely want to FILL the target
           // preventing black bars due to slight viewport AR mismatches.
           if (vf.contains("crop=")) {
              // ASPECT FILL (Cover)
              vf += "scale=$alignedWidth:$alignedHeight:force_original_aspect_ratio=increase,crop=$alignedWidth:$alignedHeight";
           } else {
              // ASPECT FIT (Pad) - Default behavior for full videos
              vf += "scale=$alignedWidth:$alignedHeight:force_original_aspect_ratio=decrease,pad=$alignedWidth:$alignedHeight:(ow-iw)/2:(oh-ih)/2:color=black";
           }
      } else {
           if (vf.isNotEmpty) vf += ",";
           vf += "scale=-2:$alignedHeight";
      }

      cmd.addAll(["-vf", vf]);

      // Audio Logic
      if (isMuted || (audioMode == "background" && audioPath == null)) {
         cmd.addAll(["-an"]); 
      } else {
         if (audioPath != null && (audioMode == "mix" || audioMode == "background")) {
             if (audioMode == "mix") {
                cmd.addAll([
                  "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first[a]",
                  "-map", "0:v",
                  "-map", "[a]"
                ]);
             } else {
                cmd.addAll([
                  "-map", "0:v",
                  "-map", "1:a",
                  "-shortest"
                ]);
             }
         } else {
             cmd.addAll(["-map", "0:v", "-map", "0:a"]);
         }
      }

      // SOFTWARE ENCODER (libx264)
      cmd.addAll([
        "-c:v", "libx264",
        "-preset", "faster",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "128k",
        "-movflags", "+faststart",
        outputPath
      ]);

      print("🔧 Software Encode (libx264): ${cmd.join(' ')}");

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
  
  /// MOD-16 ALIGNMENT HELPER (Critical for Encoder Stability)
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
}
