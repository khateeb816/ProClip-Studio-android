class AndroidAppConfig {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final bool forceUpdate;
  final String changelog;

  const AndroidAppConfig({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.forceUpdate,
    required this.changelog,
  });

  factory AndroidAppConfig.fromFirestore(Map<String, dynamic> data) {
    final rawVersionCode = data['version_code'];
    final versionCode = rawVersionCode is int
        ? rawVersionCode
        : int.tryParse(rawVersionCode?.toString() ?? '') ?? 0;

    final rawVersionName = data['version_name'];
    final versionName = rawVersionName?.toString() ?? '';

    final rawApkUrl = data['apk_url'];
    final apkUrl = rawApkUrl?.toString() ?? '';

    final forceUpdate = data['force_update'] == true;
    final changelog = data['changelog']?.toString() ?? '';

    return AndroidAppConfig(
      versionCode: versionCode,
      versionName: versionName,
      apkUrl: apkUrl,
      forceUpdate: forceUpdate,
      changelog: changelog,
    );
  }
}

