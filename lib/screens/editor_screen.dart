import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import '../services/ffmpeg_service.dart';
import '../services/metadata_service.dart';
import 'package:audioplayers/audioplayers.dart';
 
import 'export_screen.dart';
import 'audio_picker_screen.dart';
import 'video_audio_picker_screen.dart';
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
  Size _viewportSize = Size.zero;
  bool _isMuted = true; // Default to muted
  
  // Audio Player for Background Music
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isAudioLoaded = false;

  // Zoom Logic (Global)
  final TransformationController _transformController = TransformationController();
  
  String _fitMode = 'none'; 
  double? _draggedSliderValue; // For smooth slider dragging; 
  String? _videoError; 

  // Export Settings (Global)
  int _exportHeight = 720;
  int _exportFps = 30; 
  
  // Tabs (4 Sections)
  int _selectedTabIndex = 0; // 0: Video, 1: Clips, 2: Audio, 3: Ratio
  
  // Clip Count (Global)
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
    
    // Setup Audio Player Listeners
    _setupAudioPlayer();

    // Load metadata for all and init player for first
    _loadInitialData();
  }

  void _setupAudioPlayer() {
    // Configure AudioContext to mix with other audio sources (like video_player)
    // and not duck others.
    final AudioContext audioContext = AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: {
          AVAudioSessionOptions.mixWithOthers,
        },
      ),
      android: AudioContextAndroid(
        isSpeakerphoneOn: true,
        stayAwake: true,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none, // Do not request focus, prevents pausing video
      ),
    );
    AudioPlayer.global.setAudioContext(audioContext);

    _audioPlayer.onPlayerStateChanged.listen((state) {
       // Sync state if needed, but mostly we drive audio FROM video
    });
  }


  Future<void> _loadInitialData() async {
    // 1. Initialize First Player (Paused by default)
    _initPlayer(index: 0, autoPlay: false);
    
    // 2. Generate Thumbnails for all videos for the selector
    _generateThumbnails();
  }

  Future<void> _generateThumbnails() async {
    for (int i = 0; i < _videoSettings.length; i++) {
        if (!mounted) break;
      final path = await FFMpegService.generateThumbnail(_videoSettings[i].videoPath);
      if (mounted && path != null) {
        setState(() {
          _videoSettings[i].thumbnailPath = path;
        });
      }
    }
  }

  Future<void> _initPlayer({int index = 0, bool autoPlay = true}) async {
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
      var controller = VideoPlayerController.file(
        previewFile,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
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
      if (autoPlay) {
        controller.play();
      }
      
      // Initialize Audio if selected
      await _initAudio();
      
      // Sync Audio with Video
      _syncAudioWithVideo();
      
      // Global Volume control
      // controller.setVolume(_isMuted ? 0.0 : 1.0); // Moved to _updateAudioMix
      _updateAudioMix();

      // Note: Transform controller is global, so it persists across videos

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
      
      // Listener for syncing
     controller.addListener(_videoListener);

    } catch (e) {
      debugPrint("Error initializing video: $e");
      if (mounted) {
        setState(() {
          _videoError = "Failed to load video.";
        });
      }
    }
  }

  void _videoListener() {
      if (_videoController == null || !_videoController!.value.isInitialized) return;
      
      final isPlaying = _videoController!.value.isPlaying;
      final position = _videoController!.value.position;
      final duration = _videoController!.value.duration;
      
      // Loop check
      if (position >= duration) {
           _audioPlayer.seek(Duration.zero);
           if (isPlaying) _audioPlayer.resume();
      }
      
      // Sync Play/Pause
      if (isPlaying && _audioPlayer.state != PlayerState.playing && _isAudioLoaded && _audioMode != 'original') {
          _audioPlayer.resume();
      } else if (!isPlaying && _audioPlayer.state == PlayerState.playing) {
          _audioPlayer.pause();
      }
      
      // Sync Seek (Optional, but good for precision)
      // We don't want to seek constantly as it causes audio glitching, 
      // but if the drift is large (> 200ms), we sync.
      // leaving out for now to avoid stutter, relied on play/pause sync
  }

  Future<void> _initAudio() async {
      if (_audioPath == null) {
          await _audioPlayer.stop();
          _isAudioLoaded = false;
          return;
      }
      
      try {
          await _audioPlayer.setSourceDeviceFile(_audioPath!);
          await _audioPlayer.setReleaseMode(ReleaseMode.loop); // Loop audio
          _isAudioLoaded = true;
      } catch (e) {
          debugPrint("Error loading audio: $e");
          _isAudioLoaded = false;
      }
  }

  void _syncAudioWithVideo() {
     if (_videoController == null) return;
     
     if (_videoController!.value.isPlaying) {
         if (_isAudioLoaded && _audioMode != 'original') _audioPlayer.resume();
     } else {
         _audioPlayer.pause();
     }
  }
  
  void _updateAudioMix() {
      if (_videoController == null) return;

      double videoVol = 1.0;
      double audioVol = 1.0;
      
      if (_isMuted) {
          videoVol = 0.0;
          audioVol = 0.0;
      } else {
          switch (_audioMode) {
              case 'mix':
                  videoVol = 1.0;
                  audioVol = 1.0;
                  // Smart Fallback: if no audio, mix is just original
                  break;
              case 'background':
                  videoVol = 0.0;
                  audioVol = 1.0;
                  break;
              case 'original':
                  videoVol = 1.0;
                  audioVol = 0.0;
                  break;
          }
      }
      
      _videoController!.setVolume(videoVol);
      _audioPlayer.setVolume(audioVol);
      
      if (audioVol == 0.0) {
          _audioPlayer.pause();
      } else if (_videoController!.value.isPlaying && _isAudioLoaded && _audioPlayer.state != PlayerState.playing) {
          _audioPlayer.resume();
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
      oldController.removeListener(_videoListener); // Remove listener
      await oldController.dispose();
    }
    
    _videoController = null; // Prevent usage of disposed controller

    setState(() {
      _currentVideoIndex = index;
      _videoError = null; // Clear any previous error
    });
    
    // Initialize the new video
    await _initPlayer(index: index, autoPlay: true);
  }



  void _saveCurrentVideoState() {
     for (var setting in _videoSettings) {
        setting.transform = _transformController.value;
        setting.cropRect = _getPreciseCropRect();
        setting.viewportSize = _viewportSize;
        setting.audioPath = _audioPath;
        setting.audioMode = _audioMode;
        setting.isMuted = _isMuted;
     }
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
    _audioPlayer.pause();

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
    
    _audioPlayer.dispose();
    _clipDurationController.dispose();
    _clipCountController.dispose();
    super.dispose();
  }

  Future<void> _pickAudio() async {
    // Pause players before opening modal/screen
    _videoController?.pause();
    _audioPlayer.pause();
    setState(() {});
    
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
                  final res = await Navigator.push(
                    context, 
                    MaterialPageRoute(builder: (c) => const AudioPickerScreen())
                  );
                  if (res != null && res is String) {
                    setState(() {
                      _audioPath = res;
                    });
                    await _initAudio();
                    _updateAudioMix();
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library, color: Colors.cyanAccent),
                title: const Text("Extract from Video", style: TextStyle(color: Colors.white)),
                subtitle: const Text("Use audio from another video", style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () async {
                  Navigator.pop(modalContext);
                  final res = await Navigator.push(
                    context, 
                    MaterialPageRoute(builder: (c) => const VideoAudioPickerScreen())
                  );
                  if (res != null && res is String) {
                    setState(() {
                      _audioPath = res;
                    });
                    await _initAudio();
                    _updateAudioMix();
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

              // 4. Bottom Toolbar (4 Sections)
              _buildBottomToolbar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomToolbar() {
    return Container(
      color: Colors.black,
      height: 240, // Reduced height as requested
      child: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _selectedTabIndex,
              children: [
                _buildVideoSelectionSection(),
                _buildClipSettingsSection(),
                _buildAudioSettingsSection(),
                _buildRatioSection(),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildTabItem(0, Icons.video_collection, "Videos"),
              _buildTabItem(1, Icons.slow_motion_video, "Clips"),
              _buildTabItem(2, Icons.music_note, "Audio"),
              _buildTabItem(3, Icons.aspect_ratio, "Ratio"),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildVideoSelectionSection() {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(16),
      itemCount: _videos.length,
      itemBuilder: (context, index) {
        final isSelected = index == _currentVideoIndex;
        return GestureDetector(
          onTap: () => _changeVideo(index),
          child: Container(
            width: 80,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              border: Border.all(color: isSelected ? Colors.cyanAccent : Colors.white24, width: 2),
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey[900],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                   if (_videoSettings[index].thumbnailPath != null)
                     Image.file(File(_videoSettings[index].thumbnailPath!), fit: BoxFit.cover)
                   else
                     Center(child: Text("${index + 1}", style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white))),
                   
                   if (isSelected) Container(color: Colors.cyanAccent.withValues(alpha: 0.3)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildClipSettingsSection() {
    return _buildEditControls(); // Reusing existing style
  }



  Widget _buildRatioSection() {
    return _buildRatioControls(); // Reusing existing style withFit Width/Height
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5)),
      ),
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
                  _audioPlayer.pause();
                } else {
                  _videoController!.play();
                   if (_isAudioLoaded && _audioMode != 'original' && !_isMuted) {
                       _audioPlayer.resume();
                   }
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
              value: _draggedSliderValue ?? position.inMilliseconds.toDouble().clamp(0.0, duration.inMilliseconds.toDouble()),
              min: 0.0,
              max: duration.inMilliseconds.toDouble(),
              onChanged: (v) {
                setState(() {
                  _draggedSliderValue = v;
                });
              },
              onChangeEnd: (v) async {
                  final newTime = Duration(milliseconds: v.toInt());
                  await _videoController?.seekTo(newTime);
                  
                  if (_isAudioLoaded && _audioMode != 'original') {
                      final audioDur = await _audioPlayer.getDuration();
                      if (audioDur != null && audioDur.inMilliseconds > 0) {
                          final audioPos = Duration(milliseconds: newTime.inMilliseconds % audioDur.inMilliseconds);
                          await _audioPlayer.seek(audioPos);
                          if (_videoController!.value.isPlaying) {
                              await _audioPlayer.resume();
                          }
                      }
                  }
                  
                  setState(() {
                    _draggedSliderValue = null;
                  });
              },
            ),
          ),
          Text(
            _formatDuration(duration),
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 12),
          const SizedBox(width: 12),
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

  Widget _buildAudioSettingsSection() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. Audio Selection
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               const Text("Background Music", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
               const SizedBox(height: 12),
               Row(
                 children: [
                   Expanded(
                     child: GestureDetector(
                       onTap: _pickAudio,
                       child: Container(
                         padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                         decoration: BoxDecoration(
                           color: Colors.grey[800],
                           borderRadius: BorderRadius.circular(8),
                         ),
                         child: Row(
                           children: [
                             const Icon(Icons.music_note, color: Colors.cyanAccent, size: 20),
                             const SizedBox(width: 8),
                             Expanded(
                               child: Text(
                                 _audioPath == null ? "Select Music" : _audioPath!.split('/').last,
                                 style: const TextStyle(color: Colors.white, fontSize: 13),
                                 overflow: TextOverflow.ellipsis,
                               ),
                             ),
                             if (_audioPath != null)
                                GestureDetector(
                                  onTap: () {
                                     setState(() {
                                        _audioPath = null;
                                        _isAudioLoaded = false;
                                     });
                                     _audioPlayer.stop();
                                     _updateAudioMix();
                                  },
                                  child: const Icon(Icons.close, color: Colors.grey, size: 18),
                                ),
                           ],
                         ),
                       ),
                     ),
                   ),
                 ],
               ),
            ],
          ),
        ),
        
        const SizedBox(height: 20),
        
        // 2. Audio Mode Buttons (Grid Layout)
        const Text("Audio Mode", style: TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 10),
        
        Column(
          children: [
            Row(
              children: [
                Expanded(child: _buildAudioModeButton("Mix Both", "mix", Icons.merge_type)),
                const SizedBox(width: 12),
                Expanded(child: _buildAudioModeButton("Music Only", "background", Icons.music_note)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildAudioModeButton("Video Only", "original", Icons.videocam)),
                const SizedBox(width: 12),
                Expanded(child: _buildAudioModeButton("Muted", "mute_all", Icons.volume_off)),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAudioModeButton(String label, String value, IconData icon) {
    bool isSelected;
    if (value == 'mute_all') {
      isSelected = _isMuted;
    } else {
      isSelected = !_isMuted && _audioMode == value;
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          if (value == 'mute_all') {
            _isMuted = true;
          } else {
            _isMuted = false;
            _audioMode = value;
          }
           _updateAudioMix();
        });
      },
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          color: isSelected ? Colors.cyanAccent : Colors.grey[800],
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? Colors.black : Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(
              label, 
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ],
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
