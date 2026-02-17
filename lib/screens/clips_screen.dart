import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../services/clip_repository.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'player_screen.dart';
import '../services/auth_service.dart';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({super.key});

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

enum FilterState { all, uploaded, notUploaded }

class _ClipsScreenState extends State<ClipsScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _authService = AuthService();
  List<AssetEntity> _sourceClips = []; // Master list from Gallery
  List<AssetEntity> _clips = [];      // Filtered list for Display
  bool _isLoading = true;
  bool _showingArchived = false; // Toggle between active and archived clips
  String? _pendingUploadFile;
  String? _pendingUploadPlatform;
  int _statTikTok = 0;
  int _statInsta = 0;
  int _statYouTube = 0;
  
  // Filters
  FilterState _filterTikTok = FilterState.all;
  FilterState _filterInsta = FilterState.all;
  FilterState _filterYouTube = FilterState.all;
  
  // Platform Settings
  bool _platformInstagram = true;
  bool _platformYouTube = true;
  bool _platformTikTok = true;
  
  // Track if we're returning from a share action

  // Selection Mode
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {}; // Using IDs or Filenames
  
  final Map<String, String> _thumbnailCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPendingUpload();
    _loadPlatformSettings();
    _loadClips();
  }

  Future<void> _loadPlatformSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _platformInstagram = prefs.getBool('platform_instagram') ?? true;
      _platformYouTube = prefs.getBool('platform_youtube') ?? true;
      _platformTikTok = prefs.getBool('platform_tiktok') ?? true;
    });
  }

  Future<void> _loadPendingUpload() async {
    final prefs = await SharedPreferences.getInstance();
    _pendingUploadFile = prefs.getString('pending_upload_file');
    _pendingUploadPlatform = prefs.getString('pending_upload_platform');
  }

  Future<void> _savePendingUpload(String? file, String? platform) async {
    final prefs = await SharedPreferences.getInstance();
    if (file != null && platform != null) {
      await prefs.setString('pending_upload_file', file);
      await prefs.setString('pending_upload_platform', platform);
    } else {
      await prefs.remove('pending_upload_file');
      await prefs.remove('pending_upload_platform');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Check for app return to mark upload as complete
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // When app goes to background, check if we're sharing
      // If not sharing, we might be switching apps for other reasons
      // Don't set any flags here, just track the pause
    } else if (state == AppLifecycleState.resumed) {
      // Stop background service when app returns to foreground
      FlutterBackgroundService().invoke("stopService");

      // When app returns to foreground
      if (_pendingUploadFile != null && _pendingUploadPlatform != null) {
        // Mark as uploaded and clear pending state
        _markAsUploaded(_pendingUploadFile!, _pendingUploadPlatform!);
        _pendingUploadFile = null;
        _pendingUploadPlatform = null;
        _savePendingUpload(null, null);
      }
      
      // Always reset the share flag on resume

      // We DO NOT call _loadClips() here anymore. 
      // User wants manual refresh by swiping down.
    }
  }

  Future<void> _loadClips() async {
    setState(() => _isLoading = true);
    try {
      // PERMISSION CHECK
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.isAuth) {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text("Please grant gallery permissions in Settings")),
           );
           setState(() => _isLoading = false);
        }
        return;
      }

      // Load ALL videos from gallery (Single Source of Truth)
      final List<AssetPathEntity> albums = await PhotoManager.getAssetPathList(
        type: RequestType.video,
        filterOption: FilterOptionGroup(
          videoOption: const FilterOption(
            durationConstraint: DurationConstraint(
              min: Duration(seconds: 1), 
            ),
          ),
        ),
      );

      List<AssetEntity> allVideos = [];
      if (albums.isNotEmpty) {
        final recentAlbum = albums.first;
        allVideos = await recentAlbum.getAssetListRange(start: 0, end: 1000);
      }

      _sourceClips = allVideos; // Store Raw Data
      
      // OPTIMIZATION: Prune orphaned data (videos deleted externally)
      // This keeps the database clean.
      if (allVideos.isNotEmpty) {
         // Create a Set of existing filenames for fast lookup
         // Note: Accessing title might trigger async if not loaded, but typically AssetEntity has basic info.
         // Warning: accessing .title on 1000 items might be slow if not cached by PhotoManager.
         // However, PhotoManager usually caches basic properties.
         final Set<String> activeNames = {};
         for (final asset in allVideos) {
            final t = asset.title;
            if (t != null && t.isNotEmpty) activeNames.add(t);
         }
         
         // Run prune in background to not block UI
         ClipRepository.prune(activeNames);
      }
      
      _applyFilters();          // Filter Data for Display

    } catch (e) {
      debugPrint("Error loading clips: $e");
      _sourceClips = [];
      _clips = [];
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilters() {
      // Start with Source
      // Filter based on Archive Mode & Platform Filters
      // Note: "title" is used as the key for status.
      
      _clips = _sourceClips.where((asset) {
         final name = asset.title ?? "";
         final isHidden = ClipRepository.isHidden(name);
         
         // 1. Archive Filter
         if (_showingArchived) {
           if (!isHidden) return false; // Show only hidden
         } else {
           if (isHidden) return false;  // Show only visible
         }

         // 2. Platform Filters
         if (!_checkFilter(_filterTikTok, name, 'tiktok')) return false;
         if (!_checkFilter(_filterInsta, name, 'instagram')) return false;
         if (!_checkFilter(_filterYouTube, name, 'youtube')) return false;

         return true;
      }).toList();
      
      // Update Stats based on CURRENT VIEW (or Source? User wants filters to filter the view. Stats usually reflect view).
      // If I filter "Not Uploaded", chance are I want to see how many are "Not Uploaded".
      _calculateStats();
  }

  bool _checkFilter(FilterState state, String name, String platform) {
     if (state == FilterState.all) return true;
     final isUploaded = ClipRepository.isUploaded(name, platform);
     if (state == FilterState.uploaded && !isUploaded) return false;
     if (state == FilterState.notUploaded && isUploaded) return false;
     return true;
  }

  Future<void> _calculateStats() async {
     int tiktok = 0;
     int insta = 0;
     int youtube = 0;
     
     // Calculate stats for the VISIBLE clips or ALL clips?
     // Typically dashboards show stats for *everything* (Active).
     // Passing filters shouldn't hide the "Total Uploaded" count, unless the user wants to see "Count of filtered items".
     // Let's stick to calculating stats on `_clips` (the filtered list). 
     // This way if I filter "Pending", I see how many are pending. 
     // Wait, if I filter "Pending", `isUploaded` is false. So `tiktok` count will be 0.
     // That might be confusing. "TikTok: 0".
     // Maybe stats should ALWAYS be based on the ACTVIE (non-archived) list, ignoring platform filters?
     // User requirement: "user can filter out the video...". 
     // If I filter, the list changes. The stats cards are "Total", "TikTok", "Insta".
     // If I filter "Not Uploaded", "Total" becomes count of not uploaded.
     // "TikTok" becomes 0 (because all are not uploaded). 
     // This seems correct for a "Dashboard of current view".
     
     for (final asset in _clips) {
        final name = asset.title ?? "Video";
        if (ClipRepository.isUploaded(name, 'tiktok')) tiktok++;
        if (ClipRepository.isUploaded(name, 'instagram')) insta++;
        if (ClipRepository.isUploaded(name, 'youtube')) youtube++;
     }
     
     if (mounted) {
       setState(() {
          _statTikTok = tiktok;
          _statInsta = insta;
          _statYouTube = youtube;
       });
     }
  }

  Future<void> _markAsUploaded(String path, String platform) async {
    final fileName = path.split('/').last;
    await ClipRepository.markUploaded(fileName, platform);
    
    // Increment stats in Firestore
    _authService.incrementClipStats(isUpload: true);
    
    _calculateStats();
    if (mounted) setState(() {}); // Refresh UI
  }



  void _confirmResetStatus(String path, String platform) {
    final fileName = path.split('/').last;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Reset Status?"),
        content: const Text("Mark this as not uploaded?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
              child: const Text("Reset"),
              onPressed: () async {
                await ClipRepository.markNotUploaded(fileName, platform);
                _applyFilters(); // Re-apply filters
                if (mounted) {
                  setState(() {});
                  Navigator.of(context).pop();
                }
              }
          ),
        ],
      ),
    );
  }



  Future<void> _deleteAllClips() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Clear Clips List?"),
        content: const Text("This will remove these clips from the app view but keep the files in an 'archived' folder on your device."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(context, true), 
            child: const Text("Clear List"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (mounted) setState(() => _isLoading = true);
      
      try {
        // For gallery assets, we can't move them to archive
        // Instead, just clear the list (they remain in gallery)
        // Note: Archive functionality only works for exported clips in custom directory
        debugPrint("Archive not supported for gallery videos");
      } catch (e) {
        debugPrint("Archive error: $e");
      }
      
      // Clear cache
      _thumbnailCache.clear();
      
      await _loadClips(); // Refresh
    }
  }

  Future<void> _shareToPlatform(String path, String platform) async {
    // Start background service to keep app alive
    await FlutterBackgroundService().startService();
    
    // Set flag to prevent reload when returning from share

    // Save pending upload to SharedPreferences for persistence across app restarts
    _pendingUploadFile = path;
    _pendingUploadPlatform = platform;
    await _savePendingUpload(path, platform);
    
    // Trigger UI update to show orange highlight for current video
    if (mounted) setState(() {});

    final File videoFile = File(path);
    if (!await videoFile.exists()) {
      await _savePendingUpload(null, null); // Clear if file doesn't exist
      return;
    }

    String method;
    if (platform == 'instagram') {
      method = 'share_instagram';
    } else if (platform == 'tiktok') {
      method = 'share_tiktok';
    } else if (platform == 'youtube') {
      method = 'share_youtube'; 
    } else {
      await _savePendingUpload(null, null); // Clear for invalid platform
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final title = prefs.getString('default_video_title') ?? "";
      
      const platformChannel = MethodChannel('com.proclipstudio/share');
      // Delegate completely to Native SocialShareManager
      await platformChannel.invokeMethod(method, {
        'filePath': path,
        'title': title,
      });
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Could not launch $platform: $e")),
        );
      }
      // Clear pending upload on error
      _pendingUploadFile = null;
      _pendingUploadPlatform = null;
      await _savePendingUpload(null, null);
    }
  }

  void _toggleSelection(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _isSelectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _clips.length) {
        _selectedIds.clear();
        _isSelectionMode = false;
      } else {
        for (final asset in _clips) {
          _selectedIds.add(asset.id);
        }
        _isSelectionMode = true;
      }
    });
  }

  Future<void> _hideSelected(bool hide) async {
     if (_selectedIds.isEmpty) return;
     
     for (final id in _selectedIds) {
        // Find filename from ID (we need to map ID back to filename, or just rely on ID if we used ID)
        // Actually, we store "title" in repository. We need to find the asset with this ID.
        // Optimization: We could store AssetEntity in selection, but ID is safer for state.
        try {
           final asset = _clips.firstWhere((a) => a.id == id);
           final name = asset.title ?? "";
           if (name.isNotEmpty) await ClipRepository.setHidden(name, hide);
        } catch (_) {}
     }
     
     setState(() {
       _selectedIds.clear();
       _isSelectionMode = false;
       _isLoading = true;
     });
     // _loadClips(); // Reload to refresh list -> Changing to applyFilters for speed
     // Make sure UI updates to remove the now-hidden clips
     _applyFilters();
     if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _deleteClips(List<String> ids) async {
      if (ids.isEmpty) return;
      
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Delete Clips?"),
          content: Text("Are you sure you want to delete ${ids.length} clips? This cannot be undone."),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false), 
              child: const Text("Cancel")
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true), 
              child: const Text("Delete", style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      
      if (confirmed == true) {
         try {
           // Delete from Gallery
           await PhotoManager.editor.deleteWithIds(ids);
           
           // Clean up local state
           for (final id in ids) {
              // Find and remove hidden status & upload status
              try {
                  // We need the filename to clean up the repository
                  // We can try to find it in the current list (_clips) or _sourceClips
                  // Note: _clips might be filtered, check _sourceClips
                  final asset = _sourceClips.firstWhere((a) => a.id == id, orElse: () => _clips.firstWhere((a) => a.id == id));
                  final name = asset.title ?? "";
                  if (name.isNotEmpty) {
                    await ClipRepository.removeStatus(name);
                  }
              } catch (_) {
                // If we can't find the asset (weird), we might need to rely on ID mapping if we had it. 
                // But usually we delete what we see.
              }
           }
           
           setState(() {
              _selectedIds.clear();
              _isSelectionMode = false;
              _isLoading = true;
           });
           _loadClips(); // Refresh
           
         } catch (e) {
           debugPrint("Error deleting clips: $e");
           if (mounted) {
             ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(content: Text("Error deleting clips: $e")),
             );
           }
         }
      }
  }

  void _showOptionsForClip(AssetEntity asset) {
      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E1E1E),
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(_showingArchived ? Icons.unarchive : Icons.archive, color: Colors.amber),
              title: Text(_showingArchived ? "Unhide Clip" : "Hide Clip", style: const TextStyle(color: Colors.white)),
              onTap: () async {
                 Navigator.pop(ctx);
                 final name = asset.title ?? "";
                 if (name.isNotEmpty) {
                    await ClipRepository.setHidden(name, !_showingArchived);
                    _applyFilters();
                    setState(() {});
                 }
              },
            ),
             ListTile(
              leading: const Icon(Icons.check_circle_outline, color: Colors.blue),
              title: const Text("Select", style: TextStyle(color: Colors.white)),
              onTap: () {
                 Navigator.pop(ctx);
                 setState(() {
                   _isSelectionMode = true;
                   _selectedIds.add(asset.id);
                 });
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_forever, color: Colors.red),
              title: const Text("Delete", style: TextStyle(color: Colors.red)),
              onTap: () {
                 Navigator.pop(ctx);
                 _deleteClips([asset.id]);
              },
            ),
          ],
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    // Calculate Stats
    int total = _clips.length;
    // Upload tracking works via filename from asset.title
    // We calculate this asynchronously in _calculateStats using internal state variables

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. STATS DASHBOARD
        Container(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 16),
          color: Colors.black54,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_selectedIds.isEmpty)
                    Text(
                      _showingArchived ? "Archived Clips" : "Dashboard", 
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)
                    ),
                  Row(
                    children: [
                      // SELECTION MODE CONTROLS
                      if (_isSelectionMode) ...[
                          TextButton(
                            onPressed: _toggleSelectAll,
                            child: Text(
                              _selectedIds.length == _clips.length ? "Deselect All" : "Select All",
                              style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                            ),
                          ),
                          TextButton.icon(
                            icon: Icon(_showingArchived ? Icons.unarchive : Icons.archive, color: Colors.amber),
                            label: Text(_showingArchived ? "Unhide (${_selectedIds.length})" : "Hide (${_selectedIds.length})"),
                            onPressed: () => _hideSelected(!_showingArchived),
                          ),
                          IconButton(
                             icon: const Icon(Icons.delete_forever, color: Colors.red),
                             tooltip: "Delete Selected",
                             onPressed: () => _deleteClips(_selectedIds.toList()),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () {
                              setState(() {
                                _isSelectionMode = false;
                                _selectedIds.clear();
                              });
                            },
                          ),
                      ] else ...[
                          // Normal Controls
                          TextButton(
                             onPressed: () {
                               setState(() => _isSelectionMode = true);
                             },
                             child: const Text("Select", style: TextStyle(color: Colors.cyanAccent)),
                          ),
                          // Archive Toggle
                          IconButton(
                            icon: Icon(
                              _showingArchived ? Icons.unarchive : Icons.archive,
                              color: _showingArchived ? Colors.orangeAccent : Colors.white70,
                            ),
                            onPressed: () {
                              setState(() {
                                _showingArchived = !_showingArchived;
                                // Reset filters when switching views? Maybe not.
                                // But re-apply is needed.
                                _applyFilters(); 
                              });
                            },
                            tooltip: _showingArchived ? "Show Active Clips" : "Show Archived Clips",
                          ),
                          // Clear List
                          IconButton(
                            icon: const Icon(Icons.delete_sweep, color: Colors.white70), 
                            onPressed: _deleteAllClips,
                            tooltip: "Clear List",
                          ),
                      ],
                    ],
                  ),

                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _buildStatCard("Total", "$total", Colors.blueAccent),
                  if (_platformTikTok) _buildStatCard("TikTok", "$_statTikTok", Colors.white),
                  if (_platformInstagram) _buildStatCard("Insta", "$_statInsta", Colors.pinkAccent),
                  if (_platformYouTube) _buildStatCard("YouTube", "$_statYouTube", Colors.redAccent),
                ],
              ),
              const SizedBox(height: 16),
              // FILTER CHIPS
              _buildFilterChips(),
            ],
          ),
        ),

        // 2. CLIPS LIST
        Expanded(
          child: _clips.isEmpty 
          ? const Center(child: Text("No clips found", style: TextStyle(color: Colors.grey)))
          : RefreshIndicator(
              onRefresh: _loadClips,
              color: Colors.cyanAccent,
              backgroundColor: const Color(0xFF1E1E1E),
              child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  physics: const AlwaysScrollableScrollPhysics(), // Important for RefreshIndicator with short lists
                  itemCount: _clips.length,
                  itemBuilder: (context, index) {
                    final asset = _clips[index];
                    final fileName = asset.title ?? "Video ${index + 1}";
                    final isSelected = _selectedIds.contains(asset.id);
                    
                    // Sync Status Check (Best Effort using asset.title)
                    bool isFullyUploaded = true;
                    if (_platformTikTok && !ClipRepository.isUploaded(fileName, 'tiktok')) isFullyUploaded = false;
                    if (_platformInstagram && !ClipRepository.isUploaded(fileName, 'instagram')) isFullyUploaded = false;
                    if (_platformYouTube && !ClipRepository.isUploaded(fileName, 'youtube')) isFullyUploaded = false;
                    
                    final isCurrentlyUploading = (_pendingUploadFile != null && asset.title != null && _pendingUploadFile!.contains(asset.title!));
                    
                    return ClipTile(
                      key: ValueKey(asset.id),
                      asset: asset,
                      index: index,
                      isSelected: isSelected,
                      isSelectionMode: _isSelectionMode,
                      isFullyUploaded: isFullyUploaded,
                      isCurrentlyUploading: isCurrentlyUploading,
                      showTikTok: _platformTikTok,
                      showInsta: _platformInstagram,
                      showYouTube: _platformYouTube,
                      onTap: () {
                         if (_isSelectionMode) {
                            _toggleSelection(asset.id);
                         }
                      },
                      onLongPress: () {
                         if (_isSelectionMode) {
                            _toggleSelection(asset.id);
                         } else {
                            _showOptionsForClip(asset);
                         }
                      },
                      onToggleSelection: () => _toggleSelection(asset.id),
                      onShowOptions: _showOptionsForClip,
                      onShare: _shareToPlatform,
                      onConfirmReset: _confirmResetStatus,
                    );
                  },
              ),
            ),
        ),
      ],
    );
  }


  Widget _buildStatCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          border: Border.all(color: color.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
            Text(label, style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 10)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          if (_platformTikTok) ..._buildPlatformFilterChips('TikTok', _filterTikTok, Colors.white, (state) {
            setState(() {
              _filterTikTok = state;
              _applyFilters();
            });
          }),
          if (_platformInstagram) ..._buildPlatformFilterChips('Insta', _filterInsta, Colors.pinkAccent, (state) {
            setState(() {
              _filterInsta = state;
              _applyFilters();
            });
          }),
          if (_platformYouTube) ..._buildPlatformFilterChips('YouTube', _filterYouTube, Colors.redAccent, (state) {
            setState(() {
              _filterYouTube = state;
              _applyFilters();
            });
          }),
        ],
      ),
    );
  }

  List<Widget> _buildPlatformFilterChips(String label, FilterState currentState, Color color, Function(FilterState) onChanged) {
    return [
      _buildFilterChip('$label: All', currentState == FilterState.all, color.withValues(alpha: 0.3), () => onChanged(FilterState.all)),
      const SizedBox(width: 6),
      _buildFilterChip('✓', currentState == FilterState.uploaded, color, () => onChanged(FilterState.uploaded)),
      const SizedBox(width: 6),
      _buildFilterChip('✗', currentState == FilterState.notUploaded, Colors.grey[700]!, () => onChanged(FilterState.notUploaded)),
      const SizedBox(width: 12),
    ];
  }

  Widget _buildFilterChip(String label, bool isSelected, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.transparent,
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : color,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class ClipTile extends StatefulWidget {
  final AssetEntity asset;
  final int index;
  final bool isSelected;
  final bool isSelectionMode;
  final bool isFullyUploaded;
  final bool isCurrentlyUploading;
  final bool showTikTok;
  final bool showInsta;
  final bool showYouTube;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleSelection;
  final Function(AssetEntity) onShowOptions;
  final Function(String, String) onShare;
  final Function(String, String) onConfirmReset;

  const ClipTile({
    super.key,
    required this.asset,
    required this.index,
    required this.isSelected,
    required this.isSelectionMode,
    required this.isFullyUploaded,
    required this.isCurrentlyUploading,
    required this.showTikTok,
    required this.showInsta,
    required this.showYouTube,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleSelection,
    required this.onShowOptions,
    required this.onShare,
    required this.onConfirmReset,
  });

  @override
  State<ClipTile> createState() => _ClipTileState();
}

class _ClipTileState extends State<ClipTile> with AutomaticKeepAliveClientMixin {
  late Future<Uint8List?> _thumbnailFuture;
  late Future<File?> _fileFuture;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _thumbnailFuture = widget.asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
    _fileFuture = widget.asset.file;
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return "$hours:${twoDigits(minutes)}:${twoDigits(seconds)}";
    }
    return "${twoDigits(minutes)}:${twoDigits(seconds)}";
  }

  Widget _buildMiniUploadBtn(String platform, IconData iconData, Color color, String path, String fileName) {
    if (platform == 'instagram' && !widget.showInsta) return const SizedBox.shrink();
    if (platform == 'youtube' && !widget.showYouTube) return const SizedBox.shrink();
    if (platform == 'tiktok' && !widget.showTikTok) return const SizedBox.shrink();
    
    final isUploaded = ClipRepository.isUploaded(fileName, platform);
    return InkWell(
      onTap: isUploaded 
          ? () => widget.onConfirmReset(path, platform) 
          : () => widget.onShare(path, platform),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Icon(
          iconData,
          color: isUploaded ? color : Colors.grey[700],
          size: 20,
          shadows: isUploaded ? [
              BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 8,
                spreadRadius: 2,
              )
          ] : [],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final fileName = widget.asset.title ?? "Video ${widget.index + 1}";
    final duration = widget.asset.videoDuration;

    // Determine card color and border
    Color cardColor;
    if (widget.isSelected) {
      cardColor = Colors.blue.withValues(alpha: 0.2);
    } else if (widget.isCurrentlyUploading) {
      cardColor = Colors.orange.withValues(alpha: 0.15);
    } else if (widget.isFullyUploaded) {
      cardColor = Colors.green.withValues(alpha: 0.1);
    } else {
      cardColor = Colors.grey[900]!;
    }
    
    BorderSide? borderSide;
    if (widget.isSelected) {
      borderSide = const BorderSide(color: Colors.blue, width: 2);
    } else if (widget.isCurrentlyUploading) {
      borderSide = const BorderSide(color: Colors.orange, width: 2);
    } else if (widget.isFullyUploaded) {
      borderSide = BorderSide(color: Colors.green.withValues(alpha: 0.3), width: 1.5);
    }

    return InkWell(
      onLongPress: () {
         if (widget.isSelectionMode) {
            widget.onToggleSelection();
         } else {
            widget.onShowOptions(widget.asset);
         }
      },
      onTap: () {
         if (widget.isSelectionMode) {
            widget.onToggleSelection();
         }
      },
      child: Card(
        color: cardColor,
        shape: borderSide != null
            ? RoundedRectangleBorder(side: borderSide, borderRadius: BorderRadius.circular(12))
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          height: 90,
          child: Row(
            children: [
              // CHECKBOX
              if (widget.isSelectionMode)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(
                    widget.isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                    color: widget.isSelected ? Colors.blue : Colors.grey,
                  ),
                ),

              // SERIAL NUMBER
                Container(
                  width: 32,
                  alignment: Alignment.center,
                  child: Text(
                    "${widget.index + 1}",
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
              
              // THUMBNAIL
              GestureDetector(
                onTap: () async {
                  if (widget.isSelectionMode) {
                     widget.onToggleSelection();
                  } else {
                    final file = await _fileFuture;
                    if (file != null && context.mounted) {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(videoPath: file.path)));
                    }
                  }
                },
                child: SizedBox(
                  width: 90,
                  height: 90,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FutureBuilder<Uint8List?>(
                        future: _thumbnailFuture,
                        builder: (context, snapshot) {
                          if (snapshot.hasData && snapshot.data != null) {
                            return Image.memory(
                              snapshot.data!,
                              fit: BoxFit.cover,
                            );
                          }
                          return Container(
                            color: Colors.black,
                            child: const Icon(Icons.play_circle_outline, color: Colors.white),
                          );
                        },
                      ),
                      if (duration.inSeconds > 0)
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              _formatDuration(duration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              
              // INFO
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
              
              // ACTIONS
              if (!widget.isSelectionMode)
                FutureBuilder<File?>(
                  future: _fileFuture,
                  builder: (context, fileSnapshot) {
                    if (!fileSnapshot.hasData || fileSnapshot.data == null) {
                      return const SizedBox(width: 100);
                    }
                    final filePath = fileSnapshot.data!.path;
                    final fileNameForTracking = filePath.split('/').last;
                    
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildMiniUploadBtn("tiktok", FontAwesomeIcons.tiktok, Colors.white, filePath, fileNameForTracking),
                        _buildMiniUploadBtn("instagram", FontAwesomeIcons.instagram, Colors.pinkAccent, filePath, fileNameForTracking),
                        _buildMiniUploadBtn("youtube", FontAwesomeIcons.youtube, Colors.redAccent, filePath, fileNameForTracking),
                        const SizedBox(width: 16), // Added padding as requested
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
