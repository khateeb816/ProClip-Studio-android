import 'package:photo_manager/photo_manager.dart';

class VideoCacheManager {
  static final VideoCacheManager _instance = VideoCacheManager._internal();
  factory VideoCacheManager() => _instance;
  VideoCacheManager._internal();

  List<AssetEntity> _videos = [];
  bool _initialized = false;

  // ✅ OLD COMPATIBILITY
  List<AssetEntity> get cachedAssets => _videos;
  bool get isInitialized => _initialized;

  // ✅ INIT (load videos)
  Future<void> init({Function(double progress)? onProgress}) async {
    await clear();

    final permission = await PhotoManager.requestPermissionExtend();

    if (!permission.isAuth) {
      await PhotoManager.openSetting();
      return;
    }

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );

    if (paths.isEmpty) return;

    final total = await paths.first.assetCountAsync;

    int loaded = 0;
    int page = 0;
    const int pageSize = 100;

    while (loaded < total) {
      final items = await paths.first.getAssetListPaged(
        page: page,
        size: pageSize,
      );

      if (items.isEmpty) break;

      _videos.addAll(items);
      loaded += items.length;
      page++;

      if (onProgress != null) {
        onProgress(loaded / total);
      }
    }

    _initialized = true;
  }

  // ✅ REFRESH (reload videos)
  Future<void> refresh() async {
    _initialized = false;
    await init();
  }

  // ✅ STORE (used by splash if needed)
  Future<void> storeVideos(List<AssetEntity> list) async {
    _videos = list;
    _initialized = true;
  }

  // ✅ CLEAR CACHE
  Future<void> clear() async {
    _videos.clear();
    await PhotoManager.clearFileCache();
  }

  // ✅ GET VIDEOS
  List<AssetEntity> getVideos() {
    return _videos;
  }
}