import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import '../services/ffmpeg_service.dart'; // Restore FFMpegService
import '../services/metadata_service.dart'; // Restore MetadataService
 
import 'export_screen.dart';
import '../models/video_settings.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

class EditorScreen extends StatefulWidget {
  final List<File> videoFiles;
  const EditorScreen({super.key, required this.videoFiles});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  VideoPlayerController? _videoController;
  int _currentVideoIndex = 0;
  // Caching
  final Map<int, VideoPlayerController> _controllerCache = {};
  
  List<File> get _videos => widget.videoFiles;

  // Per-Video Settings
  late List<VideoSettings> _videoSettings;

  // Global State (applies to all)
  String? _audioPath;
  double _clipDuration = 30.0;
  String _aspectRatio = "9:16";
  String _audioMode = "mix"; // mix, background, original
  bool _isExporting = false;
  double _exportProgress = 0.0;
  Size _viewportSize = Size.zero; // For centering calculations

  // Zoom Logic
  final TransformationController _transformController = TransformationController();
  
  // ignore: unused_field
  String _fitMode = 'none'; // 'none', 'width', 'height'
  String? _videoError; // To store video initialization errors

  // Tabs
  // Export Settings
  int _exportHeight = 720;
  int _exportFps = 30; // Default 30 FPS for 720p 30fps recording
  
  // Tabs
  int _selectedTabIndex = 0; // 0: Edit, 1: Audio, 2: Ratio

  // Clip Count
  bool _isAutoClipCount = true;
  int _customClipCount = 1;
  
  // Text Controllers for inputs
  late TextEditingController _clipDurationController;
  late TextEditingController _clipCountController;

  @override
  void initState() {
    super.initState();
    if (_videos.isEmpty) {
      Navigator.pop(context);
      return;
    }
    
    // Initialize text controllers
    _clipDurationController = TextEditingController(text: _clipDuration.toInt().toString());
    _clipCountController = TextEditingController(text: _customClipCount.toString());
    
    // Initialize empty settings first
    _videoSettings = _videos.map((file) => VideoSettings(videoPath: file.path)).toList();
    
    // Load metadata for all and init player for first
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    // Optimization: Do NOT load metadata for all videos upfront.
    // Just initialize the first player.
    _initPlayer();
    
    // Optional: Pre-warm decoder if needed
    // VideoPlayerController.networkUrl(Uri.parse("about:blank")).initialize();
  }

  Future<void> _initPlayer({int index = 0}) async {
    try {
      final file = widget.videoFiles[index]; // Changed _videos to widget.videoFiles

      // 1. Check Cache
      if (_controllerCache.containsKey(index)) {
        _videoController = _controllerCache[index];
        setState(() {}); // Refresh UI
        return;
      }

      // 2. ENSURE PROXY (Stability Fix + Optimization)
      // Check if proxy exists or is generating. Wait for it to avoid HEVC crash.
      
      // Proxy check removed

      
      File previewFile;
      if (_videoSettings[index].proxyStatus == ProxyStatus.ready && _videoSettings[index].proxyPath != null) {
          previewFile = File(_videoSettings[index].proxyPath!);
      } else {
          // Fallback to original if proxy failed
          print("### Proxy not ready, falling back to original");
          previewFile = file;
          
          if (mounted) setState(() => _videoError = null); // Clear "Optimizing..." if it was set
      }
          
      // 4. Initialize Controller Async (Non-blocking) with Retry
      // Sometimes the file system or codec isn't immediately ready
      var controller = VideoPlayerController.file(previewFile);
      _videoController = controller;
      
      // Cache it
      _controllerCache[index] = controller;

      bool initialized = false;
      int retryCount = 0;
      const maxRetries = 3;

      while (!initialized && retryCount < maxRetries) {
        try {
           await controller.initialize();
           initialized = true;
        } catch (e) {
           retryCount++;
           print("### Video Initialization attempt $retryCount failed: $e");

           // HEVC / Hardware Decoder Fallback Check
           // 1. Detect if codec is HEVC or if we have persistent failure
           if (!initialized && (retryCount >= 1)) {
              // Try to get metadata to confirm codec
              var meta = _videoSettings[index].metadata;
              if (meta == null) {
                  try {
                    meta = await MetadataService.getMetadata(file.path);
                    if (mounted && meta != null) {
                        setState(() => _videoSettings[index].metadata = meta);
                    }
                  } catch (_) {}
              }

              final codec = meta?.codec.toLowerCase() ?? "";
              final isHevc = codec.contains("hevc") || codec.contains("h265");

              // 2. If HEVC or 2nd failure, Force Proxy
              if (isHevc || retryCount >= 2) {
                  print("### HEVC/Decoder Failure Detection (Codec: $codec). Enforcing PROXY.");
                  
                  // Force generation/wating for proxy
                  if (_videoSettings[index].proxyStatus != ProxyStatus.ready) {
                     setState(() => _videoError = "Optimizing HEVC Video...");
                     
                     // Proxy step removed

                     
                     // Poll for readiness
                     int waitAttempts = 0;
                     while (_videoSettings[index].proxyStatus != ProxyStatus.ready && waitAttempts < 30) {
                        await Future.delayed(const Duration(milliseconds: 500));
                        if (_videoSettings[index].proxyPath != null && await File(_videoSettings[index].proxyPath!).exists()) {
                            _videoSettings[index].proxyStatus = ProxyStatus.ready;
                        }
                        waitAttempts++;
                     }
                  }

                  // 3. Switch to Proxy
                  if (_videoSettings[index].proxyStatus == ProxyStatus.ready && _videoSettings[index].proxyPath != null) {
                     print("### Fallback: Switching to Proxy for successful playback.");
                     previewFile = File(_videoSettings[index].proxyPath!);
                     
                     // Dispose broken controller
                     try {
                       await controller.dispose();
                     } catch (_) {}
                     
                     // Create new one with proxy
                     var newController = VideoPlayerController.file(previewFile);
                     _videoController = newController;
                     _controllerCache[index] = newController;
                     
                     // Reset loop to try initializing the proxy
                     controller = newController;
                     retryCount = 0; 
                     // IMPORTANT: The loop continues and tries initialzing `controller` (which is now newController)
                     continue; 
                  }
              }
           }

           if (retryCount >= maxRetries) {
             // If ultimate failure, ensure we don't leave a broken controller
             rethrow;
           }
           // Wait a bit before retrying
           await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      
      if (!mounted) return;
      
      setState(() {
        _videoError = null;
      });
      
      controller.setLooping(true);
      controller.play();
      
      // Restore transform
      if (_videoSettings[index].transform != null) {
        _transformController.value = _videoSettings[index].transform!;
      } else {
        _transformController.value = Matrix4.identity();
      }

      // 5. Load Metadata AFTER preview starts (Lazy Load)
      if (_videoSettings[index].metadata == null) {
        MetadataService.getMetadata(file.path).then((meta) {
          if (mounted && meta != null) {
            setState(() {
              _videoSettings[index].metadata = meta;
            });
          }
        });
      }

    } catch (e) {
      debugPrint("Error initializing video: $e");
      if (mounted) {
        setState(() {
          _videoError = "Failed to load video.";
        });
      }
    }
  }

  Future<void> _changeVideo(int index) async {
    if (index == _currentVideoIndex) return;
    
    // Save current state of the *active* video before switching
    _saveCurrentVideoState();

    // CRITICAL FIX: Dispose the old controller to release hardware decoders.
    // Keeping multiple video controllers active (especially 4K/high-res) exhaust
    // the max number of hardware instances, causing "Failed to load video".
    final oldController = _videoController;
    
    // Remove from cache immediately
    _controllerCache.remove(_currentVideoIndex);

    if (oldController != null) {
      await oldController.dispose();
    }
    
    _videoController = null; // Prevent usage of disposed controller

    setState(() {
      _currentVideoIndex = index;
      _videoError = null; // Clear any previous error
    });
    
    // Initialize the new video
    await _initPlayer(index: index);
  }



  void _saveCurrentVideoState() {
     _videoSettings[_currentVideoIndex].transform = _transformController.value;
     _videoSettings[_currentVideoIndex].cropRect = _getPreciseCropRect();
     _videoSettings[_currentVideoIndex].viewportSize = _viewportSize;
  }

  // ... (existing methods)

  void _showExportSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Export Settings",
                    style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  
                  // Resolution
                  const Text("Resolution", style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [480, 720, 1080, 1440, 2160].map((h) {
                      final isSelected = _exportHeight == h;
                      String label = h == 1440 ? "2K" : h == 2160 ? "4K" : "${h}p";
                      return GestureDetector(
                        onTap: () {
                          setModalState(() => _exportHeight = h);
                          setState(() => _exportHeight = h);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.cyanAccent : Colors.grey[800],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // FPS
                  const Text("Frame Rate", style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [24, 30, 60].map((fps) {
                      final isSelected = _exportFps == fps;
                      return GestureDetector(
                        onTap: () {
                          setModalState(() => _exportFps = fps);
                          setState(() => _exportFps = fps);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.cyanAccent : Colors.grey[800],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            "$fps FPS",
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  
                  const SizedBox(height: 32),
                  
                  // Export Button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _startExport();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.all(16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Start Export", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ),
                ],
              ),
            );
          }
        );
      },
    );
  }

  Rect _getPreciseCropRect() {
    if (_videoController == null || !_videoController!.value.isInitialized) return const Rect.fromLTWH(0, 0, 1, 1);

    final Matrix4 transform = _transformController.value;
    final Matrix4 inverse = Matrix4.copy(transform)..invert();

    final double viewportW = _viewportSize.width;
    final double viewportH = _viewportSize.height;

    if (viewportW <= 0 || viewportH <= 0) return const Rect.fromLTWH(0, 0, 1, 1);

    // Viewport corners in child space
    final Vector3 tl = inverse.transform3(Vector3(0, 0, 0));
    final Vector3 br = inverse.transform3(Vector3(viewportW, viewportH, 0));

    final Rect visibleInChildSpace = Rect.fromLTRB(tl.x, tl.y, br.x, br.y);

    // Find video position in child space (initially centered)
    final double videoAR = _videoController!.value.aspectRatio;
    
    // The child of InteractiveViewer is a Center widget
    // InteractiveViewer matches the Viewport size
    double videoW, videoH;
    if (viewportW / viewportH > videoAR) {
      videoH = viewportH;
      videoW = videoH * videoAR;
    } else {
      videoW = viewportW;
      videoH = videoW / videoAR;
    }

    final double offsetX = (viewportW - videoW) / 2;
    final double offsetY = (viewportH - videoH) / 2;
    final Rect initialVideoRect = Rect.fromLTWH(offsetX, offsetY, videoW, videoH);

    // Intersection
    final Rect visibleVideoArea = visibleInChildSpace.intersect(initialVideoRect);

    // Normalize
    final double normLeft = (visibleVideoArea.left - offsetX) / videoW;
    final double normTop = (visibleVideoArea.top - offsetY) / videoH;
    final double normWidth = visibleVideoArea.width / videoW;
    final double normHeight = visibleVideoArea.height / videoH;

    return Rect.fromLTWH(
      normLeft.clamp(0.0, 1.0),
      normTop.clamp(0.0, 1.0),
      normWidth.clamp(0.0, 1.0),
      normHeight.clamp(0.0, 1.0),
    );
  }

  void _startExport() {
    // Save state of current video before exporting
    _saveCurrentVideoState();
    
    // Pause video to prevent audio leak during export
    _videoController?.pause();

    // Navigate to Export Screen with all data
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ExportScreen(
          videoFiles: _videos,
          videoSettings: _videoSettings, // Pass per-video settings
          // Global settings
          clipDuration: _clipDuration,
          audioPath: _audioPath,
          audioMode: _audioMode,
          exportHeight: _exportHeight,
          exportFps: _exportFps,
          aspectRatio: _aspectRatio,
          clipCount: _isAutoClipCount 
              ? ((_videoController?.value.duration.inSeconds ?? 0) / _clipDuration).ceil() 
              : _customClipCount,
           fitMode: _fitMode,
           isAutoClipCount: _isAutoClipCount,
        ),
      ),
    );
  }



  @override
  void dispose() {
    // Dispose all cached controllers
    for (var controller in _controllerCache.values) {
      controller.dispose();
    }
    _controllerCache.clear();
    
    _clipDurationController.dispose();
    _clipCountController.dispose();
    super.dispose();
  }

  Future<void> _pickAudio() async {
    // Capture the parent context to use after the modal is closed
    final parentContext = context;
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (modalContext) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Select Audio Source",
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.audio_file, color: Colors.cyanAccent),
                title: const Text("Pick Audio File", style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(modalContext);
                  FilePickerResult? result = await FilePicker.platform.pickFiles(
                    type: FileType.audio,
                  );
                  if (result != null) {
                    final path = result.files.single.path!;
                    final ext = path.split('.').last.toLowerCase();
                    final validAudioExt = ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'];
                    
                    if (!validAudioExt.contains(ext)) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(content: Text("Error: Please select a valid audio file.")),
                      );
                      return;
                    }

                    setState(() {
                      _audioPath = path;
                    });
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library, color: Colors.cyanAccent),
                title: const Text("Extract from Video", style: TextStyle(color: Colors.white)),
                subtitle: const Text("Use audio from another video", style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () async {
                  Navigator.pop(modalContext);
                  FilePickerResult? result = await FilePicker.platform.pickFiles(
                    type: FileType.video,
                  );
                  if (result != null) {
                    final videoPath = result.files.single.path!;
                    final ext = videoPath.split('.').last.toLowerCase();
                    final validVideoExt = ['mp4', 'mov', 'avi', 'mkv', 'webm'];
                    
                    if (!validVideoExt.contains(ext)) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(parentContext).showSnackBar(
                        const SnackBar(content: Text("Error: Please select a valid video file.")),
                      );
                      return;
                    }
                    
                    // Show loading on parent context
                    if (mounted) {
                       ScaffoldMessenger.of(parentContext).showSnackBar(
                         const SnackBar(content: Text("Extracting audio...")),
                       );
                    }
                    
                    final audioPath = await FFMpegService.extractAudioFromVideo(videoPath);
                    
                    if (mounted) {
                      if (audioPath != null) {
                        setState(() {
                          _audioPath = audioPath;
                        });
                        ScaffoldMessenger.of(parentContext).hideCurrentSnackBar();
                      } else {
                        ScaffoldMessenger.of(parentContext).showSnackBar(
                          const SnackBar(content: Text("Failed to extract audio")),
                        );
                      }
                    }
                  }
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }



  @override
  Widget build(BuildContext context) {
    // Dark Theme for Professional Look
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.cyanAccent,
        sliderTheme: SliderThemeData(
          activeTrackColor: Colors.cyanAccent,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.cyanAccent,
          trackHeight: 2.0,
        ),
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              // 1. Top Bar (Back & Export)
              _buildTopBar(),

              // 2. Video Preview Area
              Expanded(
                child: _buildVideoPreview(),
              ),

              // 3. Timeline / Seek Bar
              if (_videoController != null && _videoController!.value.isInitialized)
                _buildTimeline(),

              // 3.5 Video Selector (Batch Mode)
              if (_videos.length > 1)
                _buildVideoSelector(),

              // 4. Bottom Toolbar (Controls)
              _buildBottomToolbar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSelector() {
    return Container(
      height: 60,
      color: Colors.black,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _videos.length,
        itemBuilder: (context, index) {
          final isSelected = index == _currentVideoIndex;
          final file = _videos[index];
          final fileName = file.path.split('/').last;
          
          return GestureDetector(
            onTap: () => _changeVideo(index),
            child: Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isSelected ? Colors.cyanAccent : Colors.grey[800],
                borderRadius: BorderRadius.circular(20),
                border: isSelected ? Border.all(color: Colors.white, width: 2) : null,
              ),
              alignment: Alignment.center,
              child: Text(
                fileName.length > 15 ? "...${fileName.substring(fileName.length - 15)}" : fileName,
                style: TextStyle(
                  color: isSelected ? Colors.black : Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          if (_isExporting)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(
                      value: _exportProgress,
                      backgroundColor: Colors.grey[800],
                      color: Colors.cyanAccent,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Exporting ${(_exportProgress * 100).toInt()}%",
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          ElevatedButton(
            onPressed: _showExportSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text("Export", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPreview() {
    if (_videoError != null) {
      return Container(
        color: Colors.black,
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
              const SizedBox(height: 16),
              const Text(
                "Video Error",
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _videoError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () => _initPlayer(),
                icon: const Icon(Icons.refresh),
                label: const Text("Retry"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white10,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final metadata = _videoSettings[_currentVideoIndex].metadata;
    final isInitialized = _videoController?.value.isInitialized ?? false;

    if (!isInitialized && metadata == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final videoAspectRatio = isInitialized 
        ? _videoController!.value.aspectRatio 
        : (metadata!.width / metadata.height);

    return Container(
      color: Colors.grey[900],
      child: Center(
        child: AspectRatio(
          aspectRatio: _getArValue(_aspectRatio) ?? videoAspectRatio,
          child: Container(
            color: Colors.black, // Inner clipped area can stay black or match
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: InteractiveViewer(
                          transformationController: _transformController,
                          minScale: 0.1,
                          maxScale: 10.0,
                          boundaryMargin: const EdgeInsets.all(double.infinity),
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: videoAspectRatio,
                              child: GestureDetector(
                                onDoubleTap: _resetZoom,
                                child: isInitialized 
                                  ? VideoPlayer(_videoController!)
                                  : Container(color: Colors.black), // Placeholder while loading
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimeline() {
    if (_videoController == null) return const SizedBox.shrink();
    final duration = _videoController!.value.duration;
    final position = _videoController!.value.position;

    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _videoController!.value.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            onPressed: () {
              setState(() {
                if (_videoController!.value.isPlaying) {
                  _videoController!.pause();
                } else {
                  _videoController!.play();
                }
              });
            },
          ),
          const SizedBox(width: 4),
          Text(
            _formatDuration(position),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: position.inMilliseconds.toDouble(),
              min: 0.0,
              max: duration.inMilliseconds.toDouble(),
              onChanged: (v) {
                _videoController?.seekTo(Duration(milliseconds: v.toInt()));
              },
            ),
          ),
          Text(
            _formatDuration(duration),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          IconButton(
            icon: Icon(
              (_videoController?.value.volume ?? 0) > 0 ? Icons.volume_up : Icons.volume_off,
              color: Colors.white,
              size: 20,
            ),
            onPressed: () {
              bool isMuted = _videoController?.value.volume == 0;
              _videoController?.setVolume(isMuted ? 1.0 : 0.0).then((_) {
                setState(() {});
              });
            },
          ),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildBottomToolbar() {
    return Container(
      color: const Color(0xFF000000),
      height: 280, // Increased height for controls
      child: Column(
        children: [
          // Toolbar Actions Area
          Expanded(
            child: _selectedTabIndex == 0 
                ? _buildEditControls()
                : _selectedTabIndex == 1 
                    ? _buildAudioControls()
                    : _buildRatioControls(),
          ),
          
          const Divider(height: 1, color: Colors.white12),
          
          // Bottom Navigation Tabs
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTabItem(0, Icons.cut, "Edit"),
              _buildTabItem(1, Icons.music_note, "Audio"),
              _buildTabItem(2, Icons.aspect_ratio, "Ratio"),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
  
  Widget _buildTabItem(int index, IconData icon, String label) {
    final isSelected = _selectedTabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedTabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon, 
              color: isSelected ? Colors.cyanAccent : Colors.grey,
              size: 24,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.cyanAccent : Colors.grey,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditControls() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      children: [
        const SizedBox(height: 10),
        const Text("Clip Duration (sec)", style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        TextField(
          controller: _clipDurationController,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          decoration: InputDecoration(
            hintText: "Enter duration (e.g., 30)",
            hintStyle: const TextStyle(color: Colors.white24),
            suffixText: "sec",
            suffixStyle: const TextStyle(color: Colors.cyanAccent),
            filled: true,
            fillColor: Colors.grey[900],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          onChanged: (v) {
            double? val = double.tryParse(v);
            if (val != null && val >= 1) {
              setState(() => _clipDuration = val);
            }
          },
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Clip Count", style: TextStyle(color: Colors.grey, fontSize: 12)),
            Row(
              children: [
                const Text("Auto", style: TextStyle(color: Colors.white70, fontSize: 12)),
                Switch(
                  value: !_isAutoClipCount,
                  onChanged: (v) => setState(() => _isAutoClipCount = !v),
                  activeColor: Colors.cyanAccent,
                ),
                const Text("Custom", style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ],
        ),
        if (!_isAutoClipCount)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _clipCountController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  hintText: "Enter number of clips",
                  hintStyle: const TextStyle(color: Colors.white24),
                  suffixText: "clips",
                  suffixStyle: const TextStyle(color: Colors.cyanAccent),
                  filled: true,
                  fillColor: Colors.grey[900],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                onChanged: (v) {
                  int? val = int.tryParse(v);
                  if (val != null && val >= 1) {
                    setState(() => _customClipCount = val);
                  }
                },
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildAudioControls() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey[800], borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.music_note, color: Colors.white),
          ),
          title: Text(
            _audioPath == null ? "Tap to Select Music" : _audioPath!.split('/').last,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: Text(_audioPath == null ? "No background audio" : "Audio selected", style: const TextStyle(color: Colors.grey)),
          onTap: _pickAudio,
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        ),
        const Divider(color: Colors.white12),
        const Text("Mix Mode", style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            _buildMixModeBtn("Mix", "mix"),
            const SizedBox(width: 10),
            _buildMixModeBtn("BG Only", "background"),
            const SizedBox(width: 10),
            _buildMixModeBtn("Original", "original"),
          ],
        ),
      ],
    );
  }

  Widget _buildMixModeBtn(String label, String value) {
    final isSelected = _audioMode == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _audioMode = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.cyanAccent.withValues(alpha: 0.2) : Colors.grey[800],
            border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label, 
            style: TextStyle(
              color: isSelected ? Colors.cyanAccent : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRatioControls() {
    final ratios = ["9:16", "16:9", "1:1", "4:5"]; // "Free" removed
    return Column(
      children: [
         const SizedBox(height: 10),
         SizedBox(
           height: 80,
           child: Row(
             mainAxisAlignment: MainAxisAlignment.spaceEvenly,
             children: ratios.map((r) {
               final isSelected = _aspectRatio == r;
               return GestureDetector(
                 onTap: () => setState(() => _aspectRatio = r),
                 child: Column(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     Container(
                       width: 40,
                       height: 40,
                       decoration: BoxDecoration(
                         border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.grey),
                         shape: BoxShape.circle,
                         color: isSelected ? Colors.cyanAccent.withValues(alpha: 0.2) : Colors.transparent,
                       ),
                       child: Center(
                         child: Text(
                           r.substring(0,1), 
                           style: TextStyle(color: isSelected ? Colors.cyanAccent : Colors.grey),
                         ),
                       ),
                     ),
                     const SizedBox(height: 4),
                     Text(
                       r,
                       style: TextStyle(
                         color: isSelected ? Colors.cyanAccent : Colors.grey,
                         fontSize: 12,
                       ),
                     ),
                   ],
                 ),
               );
             }).toList(),
           ),
         ),
         const Divider(color: Colors.white12),
         Padding(
           padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
           child: Row(
             children: [
               Expanded(
                 child: ElevatedButton.icon(
                   icon: const Icon(Icons.fit_screen, size: 16),
                   label: const Text("Fit Width"),
                   style: ElevatedButton.styleFrom(
                     backgroundColor: Colors.grey[800],
                     foregroundColor: Colors.white,
                     padding: const EdgeInsets.symmetric(vertical: 12),
                   ),
                   onPressed: () => _applyFitMode('width'),
                 ),
               ),
               const SizedBox(width: 12),
               Expanded(
                 child: ElevatedButton.icon(
                   icon: const Icon(Icons.fit_screen_outlined, size: 16),
                   label: const Text("Fit Height"),
                   style: ElevatedButton.styleFrom(
                     backgroundColor: Colors.grey[800],
                     foregroundColor: Colors.white,
                     padding: const EdgeInsets.symmetric(vertical: 12),
                   ),
                   onPressed: () => _applyFitMode('height'),
                 ),
               ),
             ],
           ),
         ),
      ],
    );
  }
  
  // ignore: unused_element
  Widget _buildActionButton(IconData icon, String label, VoidCallback? onTap) {
      return OutlinedButton.icon(
        icon: Icon(icon, size: 16, color: Colors.white),
        label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey[700]!),
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: onTap,
      );
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  double? _getArValue(String ar) {
    // if (ar == "Free") return null; // Logic removed
    final parts = ar.split(":");
    return double.parse(parts[0]) / double.parse(parts[1]);
  }

  void _applyFitMode(String mode) {
    if (_videoController == null || !_videoController!.value.isInitialized) return;
    
    final videoAR = _videoController!.value.aspectRatio;
    final viewportAR = _getArValue(_aspectRatio) ?? videoAR;
    
    double scale = 1.0;
    
    if (mode == 'width') {
       // Fit Width: ensure scale makes child width >= viewport width
       scale = (viewportAR > videoAR) ? (viewportAR / videoAR) : 1.0;
    } else if (mode == 'height') {
       // Fit Height: ensure scale makes child height >= viewport height
       scale = (viewportAR < videoAR) ? (videoAR / viewportAR) : 1.0;
    }
    
    // Center the content when zooming
    // Translate = (ViewportSize / 2) * (1 - Scale)
    final tx = (_viewportSize.width / 2) * (1 - scale);
    final ty = (_viewportSize.height / 2) * (1 - scale);

    // Apply transformation
    _transformController.value = Matrix4.identity()
      ..translate(tx, ty)
      ..scale(scale);

    // Save fit mode for export
    setState(() => _fitMode = mode);
  }
  
  void _resetZoom() {
    _transformController.value = Matrix4.identity();
    setState(() => _fitMode = 'none');
  }
}
