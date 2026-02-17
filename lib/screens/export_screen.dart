import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/ffmpeg_service.dart';
import '../services/notification_service.dart';
import '../models/video_settings.dart';

class ExportScreen extends StatefulWidget {
  final List<File> videoFiles;
  final List<VideoSettings> videoSettings;
  
  // Global Settings
  final double clipDuration;
  final String? audioPath;
  final String audioMode;
  final int exportHeight;
  final int exportFps;
  final String aspectRatio;
  final int clipCount;
  final String fitMode;
  final bool isAutoClipCount;

  const ExportScreen({
    super.key,
    required this.videoFiles,
    required this.videoSettings,
    required this.clipDuration,
    required this.audioPath,
    required this.audioMode,
    required this.exportHeight,
    required this.exportFps,
    required this.aspectRatio,
    required this.clipCount,
    required this.fitMode,
    required this.isAutoClipCount,
  });

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  int _currentVideoIndex = 0;
  int _currentClipIndex = 0;
  int _totalClipsForCurrentVideo = 0;
  double _currentVideoProgress = 0.0;
  double _currentClipProgress = 0.0;
  bool _isComplete = false;
  
  // Replaced VideoPlayer with Thumbnail File
  File? _currentThumbnail;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    FFMpegService.resetCancellation();
    _startBatchPipeline();
  }
  
  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }


  void _cancelExport() {
    FFMpegService.cancelExport();
    // CRITICAL: Cancel notification multiple times to ensure dismissal
    NotificationService.cancelAll();
    Future.delayed(const Duration(milliseconds: 50), () {
      NotificationService.cancelAll();
    });
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        Navigator.pop(context);
      }
    });
  }

  Future<void> _startBatchPipeline() async {
    // 1. Setup Directories
    String? customPath;
    try {
      final prefs = await SharedPreferences.getInstance();
      customPath = prefs.getString('custom_output_path');
    } catch (_) {}
    
    // ALWAYS use app internal directory for FFmpeg generation (Safe from Scoped Storage)
    final tempDir = await getTemporaryDirectory();
    final workBaseDir = tempDir.path;

    print("🚀 Starting Zero Copy Pipeline for ${widget.videoFiles.length} videos");
    print("📂 Work Dir: $workBaseDir");
    print("📂 Target Custom Dir: $customPath");
    
    int failCount = 0;

    for (int i = 0; i < widget.videoFiles.length; i++) {
        if (!mounted) break;
        
        final file = widget.videoFiles[i];
        final settings = widget.videoSettings[i];
        
        setState(() {
          _currentVideoIndex = i;
          _currentVideoProgress = 0.0;
          _currentClipIndex = 0;
          _currentThumbnail = null;
        });

        // 1. Generate Thumbnail (Fast, no player)
        FFMpegService.generateThumbnail(file.path).then((path) {
           if (mounted && path != null) {
              setState(() => _currentThumbnail = File(path));
           }
        });

        // 2. Metadata Scan
        double duration = settings.metadata?.duration ?? 0;
        if (duration == 0) {
           final meta = await FFMpegService.getVideoMetadata(file.path);
           duration = meta?.duration ?? 0;
        }

        if (duration <= 0) {
           print("⚠️ Skipping invalid duration: ${file.path}");
           failCount++; 
           continue; 
        }

        // 3. Generate Plan
        final plan = FFMpegService.generateClipPlan(
           totalDuration: duration,
           clipDuration: widget.clipDuration,
           count: widget.isAutoClipCount ? null : widget.clipCount
        );
        
        setState(() => _totalClipsForCurrentVideo = plan.length);

        // 4. Sequential Pipeline (Robust & Optimized)
        for (int c = 0; c < plan.length; c++) {
            if (!mounted || FFMpegService.isCancelled) break;
            
            final clip = plan[c];
            final start = clip['start']!;
            final end = clip['end']!;
            final duration = end - start;
            
            final timestamp = DateTime.now().millisecondsSinceEpoch;
            // Generate to TEMP first
            final outFileName = "clip_${i}_${c}_$timestamp.mp4";
            final tempOutPath = "$workBaseDir/$outFileName";
            
            setState(() {
               _currentClipIndex = c + 1;
               _currentClipProgress = 0.0;
            });
            
            NotificationService.showProgress(
               (_currentVideoProgress * 100).toInt(), 
               message: "V${i+1}: Clip ${c+1}/${plan.length}"
            );

            // Execute via Queue (Sequential)
            final resultPath = await FFMpegService.enqueueJob(() async {
                String? resultPath;
                
                // Calculate Output Resolution (Unified for both Engines)
                int outHeight = widget.exportHeight;
                double ratio = 9/16; // Default to 9:16
                bool hasCustomRatio = false;
                
                try {
                   if (widget.aspectRatio != "Original") {
                       final parts = widget.aspectRatio.split(":");
                       if (parts.length == 2) {
                          ratio = double.parse(parts[0]) / double.parse(parts[1]);
                          hasCustomRatio = true;
                       }
                   }
                } catch(_) {}
                
                int? outWidth;
                if (hasCustomRatio) {
                     outWidth = (outHeight * ratio).round();
                     // Ensure Mod-2 (or Mod-16 in service)
                     if (outWidth % 2 != 0) outWidth--;
                } else if (widget.aspectRatio == "Original") {
                     // If original, we might deduce from source or just let FFmpeg handle it?
                     // If we strictly want to match input aspect ratio, we leave outWidth null
                     // and let executeSmartExport derive it or just scale height.
                }

                // FFmpeg Software Export
                print("🔧 Using FFmpeg Software Encoding (libx264)");
                
                bool exportComplete = false;
                final progressTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
                  if (!mounted || exportComplete) {
                    timer.cancel();
                    return;
                  }
                  final elapsed = timer.tick * 200; 
                  final estimatedDuration = duration * 1500; 
                  final simulatedProgress = (elapsed / estimatedDuration).clamp(0.0, 0.95);
                  
                  setState(() {
                    _currentClipProgress = simulatedProgress;
                  });
                  
                  final currentClipProportion = (c + simulatedProgress) / plan.length;
                  final overallProgressPercent = ((_currentVideoIndex + currentClipProportion) / widget.videoFiles.length * 100).toInt();
                  
                  NotificationService.showProgress(
                    overallProgressPercent,
                    message: "V${_currentVideoIndex + 1}: Clip $_currentClipIndex/$_totalClipsForCurrentVideo (${(simulatedProgress * 100).toInt()}%)"
                  );
                });
                
                resultPath = await FFMpegService.executeSmartExport(
                   inputPath: file.path, 
                   outputPath: tempOutPath, 
                   start: start, 
                   duration: duration, 
                   settings: settings, 
                   outputHeight: widget.exportHeight,
                   outputWidth: outWidth, // PASSING TARGET WIDTH TRIGGERS PADDING
                );
                
                exportComplete = true;
                progressTimer.cancel();
                return resultPath;
            });

            if (mounted && resultPath != null) {
               // SUCCESSFUL GENERATION
               // NOTE: FFMpegService already saved to gallery internally
               // We only need to copy to custom path if specified
               
               // Copy to Custom Path (Best Effort)
               if (customPath != null) {
                 try {
                   final targetFile = File("$customPath/$outFileName");
                   // Ensure parent exists (unlikely to help with scoped storage but good practice)
                   if (!await targetFile.parent.exists()) {
                      // Try to create? Usually fails if no permission
                   }
                   await File(resultPath).copy(targetFile.path);
                   print("✅ Copied to custom path: ${targetFile.path}");
                 } catch (e) {
                   print("⚠️ Could not copy to custom path (Scoped Storage check): $e");
                   // Do NOT fail the export. Gallery save is enough.
                 }
               }
            
               setState(() {
                  _currentClipProgress = 1.0;
                  _currentVideoProgress = (c + 1) / plan.length;
               });
               
               final currentVideoActualProgress = (c + 1.0) / plan.length;
               final overallProgressPercent = ((_currentVideoIndex + currentVideoActualProgress) / widget.videoFiles.length * 100).toInt();
               NotificationService.showProgress(
                 overallProgressPercent,
                 message: "V${_currentVideoIndex + 1}: Clip $_currentClipIndex/$_totalClipsForCurrentVideo (100%)"
               );
            } else {
               print("❌ Clip Export Failed: Video $i Clip $c");
               failCount++;
            }
        }

        // STABILIZATION DELAY
        if (mounted) {
           await Future.delayed(const Duration(milliseconds: 500));
        }

        if (i % 5 == 0) {
           await FFMpegService.freeResources();
        }
    }

    if (mounted) {
      setState(() {
        _isComplete = true;
      });
      
      String msg = "Export Complete";
      if (failCount > 0) {
        msg = "Completed with $failCount errors";
        NotificationService.showDone(msg);
      } else {
        NotificationService.showDone("Success");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isComplete) {
       return Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: Center(
           child: Column(
             mainAxisAlignment: MainAxisAlignment.center,
             children: [
                const Icon(Icons.check_circle, color: Colors.greenAccent, size: 80),
                const SizedBox(height: 20),
                const Text("Export Complete!", style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 40),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.cyanAccent,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                  child: const Text("Done", style: TextStyle(fontWeight: FontWeight.bold)),
                )
             ],
           ),
        ),
       );
    }

    // Circular Progress Value (Overall)
    // Proportional progress within current video
    double currentVideoProportion = 0.0;
    if (_totalClipsForCurrentVideo > 0) {
      currentVideoProportion = (_currentClipIndex - 1 + _currentClipProgress) / _totalClipsForCurrentVideo;
    }
    
    // Total progress across all videos
    final double overallProgress = (_currentVideoIndex + currentVideoProportion) / widget.videoFiles.length;

    return WillPopScope(
      onWillPop: () async => false, // Prevent back button during export
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Circular Progress with Thumbnail center
                SizedBox(
                  width: 240,
                  height: 240,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Outer Progress Ring
                      SizedBox(
                        width: 240,
                        height: 240,
                        child: CircularProgressIndicator(
                          value: overallProgress,
                          strokeWidth: 10,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                        ),
                      ),
                      
                      // Inner Thumbnail
                      Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white24, width: 2),
                          color: Colors.black,
                        ),
                        child: ClipOval(
                          child: _currentThumbnail != null 
                              ? Image.file(_currentThumbnail!, fit: BoxFit.cover)
                              : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      ),
                      
                      // Percentage Overlay
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          "${(overallProgress * 100).toInt()}%",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 48),
                
                Text(
                  "Processing Video ${_currentVideoIndex + 1} of ${widget.videoFiles.length}",
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  "Clip $_currentClipIndex of $_totalClipsForCurrentVideo",
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                
                const SizedBox(height: 60),
                
                ElevatedButton.icon(
                  onPressed: _cancelExport,
                  icon: const Icon(Icons.close),
                  label: const Text("Cancel Export"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent),
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }
}
