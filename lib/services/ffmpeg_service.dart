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
    // Enable logs for debugging (reduce to avLogError once export is confirmed working)
    FFmpegKitConfig.enableLogCallback((log) {
      final msg = log.getMessage();
      if (msg != null && msg.isNotEmpty) print('[FFmpeg] $msg');
    });
    FFmpegKitConfig.setLogLevel(Level.avLogWarning);
    
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
      String? audioPathOverride,
  }) async {
      // 1. Capability & Metadata Check
      final meta = settings.metadata ?? await getVideoMetadata(inputPath);
      final int srcHeight = meta?.height ?? 720;
      
      // 2. Stream Copy Check (Fast Path)
      // DISABLED: Enforcing software encoding only as per requirements
      final bool isSimpleCut = (settings.cropRect == null || settings.cropRect == const Rect.fromLTWH(0,0,1,1)) &&
                               (settings.audioPath == null) && 
                               (settings.transform == null) &&
                               (outputWidth == null);

      // if (isSimpleCut && start == 0.0) {
      //     final result = await executeStreamCopy(
      //        inputPath: inputPath, 
      //        start: start, 
      //        duration: duration, 
      //        outputPath: outputPath
      //     );
      //     if (result != null) return result;
      // }
      
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
          settings: settings, // Pass full settings
          targetHeight: targetH,
          targetWidth: outputWidth,
          audioPath: audioPathOverride ?? settings.audioPath,
          audioMode: settings.audioMode,
          isMuted: settings.isMuted,
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
            
            // Tolerance +/- 2.5s — stream copy clips can vary due to keyframe alignment.
            if ((dur - expectedDuration).abs() > 2.5) {
                print("❌ Validation Failed: Duration Mismatch (Got $dur, Expected $expectedDuration)");
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
    required VideoSettings settings, // Use settings directly
    int targetHeight = 1280,
    int? targetWidth,
    String? audioPath,
    String? audioMode, // mix, background, original
    bool isMuted = false,
  }) async {
      final String durStr = duration.toStringAsFixed(3);
      final bool useBgm = audioPath != null && !isMuted && (audioMode == "mix" || audioMode == "background");
      List<String> cmd = [
        "-y",
        "-i", inputPath,
        "-ss", start.toStringAsFixed(3),
      ];

      // Only include BGM as an input when it is actually used.
      if (useBgm) {
        // Deterministic:
        // - explicitly seek BGM to 0:00 for every clip (avoid any option bleed)
        // - loop indefinitely, then trim to the exact clip duration in filters below
        cmd.addAll(["-stream_loop", "-1", "-ss", "0", "-i", audioPath]);
      }

      cmd.addAll(["-t", durStr]);

      // CRITICAL: Use scale=iw:ih as the VERY FIRST filter to absorb HEVC decoder reinit signals.
      //
      // Root cause: This HEVC video (hvc1/yuvj420p) outputs frames with INCONSISTENT
      // color-space metadata (some: csp:gbr range:unknown, others: csp:bt709 range:pc).
      // FFmpeg sends a "reinit" signal through the filter graph when frame properties change.
      //
      // WHY scale WORKS and others don't:
      //   - setparams, format, crop: NOT reinit-safe. They crash or propagate the reinit.
      // Resolve Input Dimensions and Rotation
      int iw = 1280; // Default fallback
      int ih = 720;
      int rotation = 0;
      try {
        final meta = await getVideoMetadata(inputPath);
        if (meta != null) {
          iw = meta.width;
          ih = meta.height;
          rotation = meta.rotation;
        }
      } catch (e) {
        print("⚠️ Failed to get metadata for crop calc: $e");
      }

      double iw_d = iw.toDouble();
      double ih_d = ih.toDouble();
      
      // Calculate output canvas dimensions
      int alignedHeight = _alignToMod16(targetHeight);
      double videoAR = settings.displayAR ?? (iw_d / ih_d);
      
      // If targetWidth is null (e.g. "Original" ratio), calculate it from source to prevent stretching.
      int alignedWidth = targetWidth != null 
          ? _alignToMod16(targetWidth) 
          : _alignToMod16((alignedHeight * videoAR).round());

      // BUILD FILTER CHAIN
      String vf = "";

      if (settings.viewportSize.width > 0 && settings.viewportSize.height > 0) {
        // 1. Calculate UI constants
        double viewportW = settings.viewportSize.width;
        double viewportH = settings.viewportSize.height;
        double viewportAR = viewportW / viewportH;

        double vW_ui, vH_ui;
        if (viewportAR > videoAR) {
          vH_ui = viewportH;
          vW_ui = vH_ui * videoAR;
        } else {
          vW_ui = viewportW;
          vH_ui = vW_ui / videoAR;
        }

        double offX_ui = (viewportW - vW_ui) / 2;
        double offY_ui = (viewportH - vH_ui) / 2;
        double esf = alignedHeight / viewportH;

        // 2. Calculate Final Placement (Output Pixels)
        double s = settings.scale;
        int zoomW = (vW_ui * s * esf).round() & ~1;
        int zoomH = (vH_ui * s * esf).round() & ~1;

        double finalX = ((offX_ui * s) + settings.tx) * esf;
        double finalY = ((offY_ui * s) + settings.ty) * esf;

        // 3. Mapping: If X/Y is negative, we crop. If positive, we pad.
        int cropX = finalX < 0 ? (-finalX).round() & ~1 : 0;
        int cropY = finalY < 0 ? (-finalY).round() & ~1 : 0;
        int padX = finalX > 0 ? (finalX).round() & ~1 : 0;
        int padY = finalY > 0 ? (finalY).round() & ~1 : 0;

        // Dimensions of the visible part of the zoomed video on the output canvas
        int visibleW = (zoomW - cropX).clamp(0, alignedWidth - padX) & ~1;
        int visibleH = (zoomH - cropY).clamp(0, alignedHeight - padY) & ~1;

        // Build the chain: Scale -> Crop (the off-screen parts) -> Pad (to viewport size)
        if (vf.isNotEmpty) vf += ",";
        vf += "scale=$zoomW:$zoomH,crop=$visibleW:$visibleH:$cropX:$cropY,pad=$alignedWidth:$alignedHeight:$padX:$padY:color=black";
      } else {
        if (vf.isNotEmpty) vf += ",";
        vf += "scale=-2:$alignedHeight";
      }

      // 4. Force Square Pixels (SAR 1:1) to prevent stretching in players
      vf += ",setsar=1/1,format=yuv420p";
      cmd.addAll(["-vf", vf]);

      // Audio Logic
      // IMPORTANT: -c:a / audio codec flags must ONLY be added when audio is included.
      // Mixing -an with -c:a causes FFmpeg to fail with a non-zero exit code.
      if (isMuted || (audioMode == "background" && audioPath == null)) {
         // No audio — suppress audio stream entirely
         cmd.addAll(["-an"]);
      } else {
        if (useBgm) {
          // Deterministic BGM: trim to exactly `duration` and reset PTS so every clip starts at 0:00.
          if (audioMode == "mix") {
            cmd.addAll([
              "-filter_complex",
              "[0:a]asetpts=PTS-STARTPTS,atrim=end=$durStr[a0];"
              "[1:a]atrim=end=$durStr,asetpts=PTS-STARTPTS[bgm];"
              // Keep output running for the longer input (usually BGM), avoiding early termination
              "[a0][bgm]amix=inputs=2:duration=longest:dropout_transition=0[a]",
              "-map", "0:v",
              "-map", "[a]"
            ]);
          } else {
            // Background: video only + deterministic BGM segment
            cmd.addAll([
              "-filter_complex",
              "[1:a]atrim=end=$durStr,asetpts=PTS-STARTPTS[bgm]",
              "-map", "0:v",
              "-map", "[bgm]"
            ]);
          }
        } else {
          // Keep original video + audio (no background music)
          cmd.addAll(["-map", "0:v", "-map", "0:a?"]);
        }
         // Audio codec — only when audio is being included
         cmd.addAll(["-c:a", "aac", "-b:a", "128k"]);
      }

      // SOFTWARE ENCODER (libx264)
      cmd.addAll([
        "-c:v", "libx264",
        "-preset", "faster",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
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
        "-vf", "format=yuv420p,scale=240:-2", // Normalize format + tiny thumbnail
        "-update", "1", // Required for single-frame image2 output in newer FFmpeg
        outPath
     ];
     
      await FFmpegKit.executeWithArguments(cmd);
     if (await File(outPath).exists()) return outPath;
     return null;
  }

  /// Generate a deterministic BGM segment of exactly `duration` seconds.
  /// - Always starts from 0:00 of the source audio
  /// - Loops seamlessly if source is shorter
  /// - Trims exactly to `duration` (no trailing silence)
  static Future<String?> generateBgmSegment({
    required String audioPath,
    required double duration,
    required String outputPath,
  }) async {
    final String durStr = duration.toStringAsFixed(3);

    final cmd = [
      "-y",
      "-stream_loop", "-1",
      "-i", audioPath,
      "-t", durStr,
      "-vn",
      "-filter:a", "atrim=end=$durStr,asetpts=PTS-STARTPTS",
      "-c:a", "aac",
      "-b:a", "192k",
      outputPath,
    ];

    print("🎵 Generating BGM Segment: ${cmd.join(' ')}");
    final session = await FFmpegKit.executeWithArguments(cmd);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      final file = File(outputPath);
      if (await file.exists() && (await file.length()) > 1000) {
        return outputPath;
      }
    }

    return null;
  }

  /// Helper: Generate Proxy for HEVC
  static Future<String?> generateHEVCProxy(String videoPath) async {
     try {
       final dir = await getExternalStorageDirectory(); 
       final outDir = dir ?? await getApplicationDocumentsDirectory();
       final outPath = "${outDir.path}/proxy_${DateTime.now().millisecondsSinceEpoch}.mp4";
       
       // Transcode to H.264 at a fast preset and lower resolution for smooth preview
       final cmd = [
          "-y",
          "-i", videoPath,
          "-vf", "scale=-2:720",
          "-c:v", "libx264",
          "-preset", "ultrafast",
          "-crf", "28",
          "-c:a", "copy",
          outPath
       ];
       
       print("🚀 Generating HEVC Proxy: ${cmd.join(' ')}");
       final session = await FFmpegKit.executeWithArguments(cmd);
       if (ReturnCode.isSuccess(await session.getReturnCode())) {
         return outPath;
       }
     } catch (e) {
       print("❌ HEVC Proxy Generation Failed: $e");
     }
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
        String codec = "unknown";
        int rotation = 0;

        for (var stream in info.getStreams()) {
          if (stream.getType() == "video") {
            width = stream.getWidth() ?? 1280;
            height = stream.getHeight() ?? 720;

            try {
              final rotationSession = await FFprobeKit.execute(
                  '-v error -select_streams v:0 -show_entries stream_tags=rotate -of default=noprint_wrappers=1:nokey=1 "$path"');
              final rotationOut = (await rotationSession.getOutput())?.trim();
              rotation = int.tryParse(rotationOut ?? "0") ?? 0;
              if (rotation == 90 || rotation == 270 || rotation == -90 || rotation == -270) {
                final int temp = width;
                width = height;
                height = temp;
                print("🔄 Swapping dimensions due to $rotation degree rotation: ${width}x${height}");
              }
            } catch (_) {}

            final rFrameRate = stream.getRealFrameRate();
            if (rFrameRate != null) {
               final parts = rFrameRate.split('/');
               if (parts.length == 2) {
                  final den = double.tryParse(parts[1]) ?? 1.0;
                  fps = (double.tryParse(parts[0]) ?? 30.0) / den;
               } else {
                  fps = double.tryParse(rFrameRate) ?? 30.0;
               }
            }
            break;
          }
        }

        // Resolve the actual codec name for HEVC/H.265 detection.
        // Note: FFprobeKit's higher-level stream getters vary by version, so we use
        // an explicit ffprobe query to keep this robust across iOS/Android builds.
        try {
          final codecSession = await FFprobeKit.execute(
              '-v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$path"');
          final codecOut = (await codecSession.getOutput())?.trim().toLowerCase();

          if (codecOut != null && codecOut.isNotEmpty) {
            codec = codecOut;
          }

          // Map common HEVC aliases to a consistent string so editor logic can detect it.
          if (codec == "hvc1" || codec == "hev1") {
            codec = "hevc";
          }
        } catch (_) {}

        return VideoMetadata(
          duration: duration,
          width: width,
          height: height,
          fps: fps,
          bitrate: bitrate,
          codec: codec,
          rotation: rotation,
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
