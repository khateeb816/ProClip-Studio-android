import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'update_models.dart';

class UpdateRepository {
  final FirebaseFirestore _firestore;

  UpdateRepository({
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  // Default template used if `app_config/android` is missing.
  // Update these values to match your real release APK.
  static const AndroidAppConfig _defaultAndroidTemplate = AndroidAppConfig(
    versionCode: 1,
    versionName: '1.2.0',
    apkUrl:
        'https://github.com/khateeb816/ProClip-Studio/releases/download/v1.2.0/app-release.apk',
    forceUpdate: false,
    changelog: 'Bug fixes and performance improvements',
  );

  Future<AndroidAppConfig?> fetchAndroidConfig({
    Duration timeout = const Duration(seconds: 3),
    bool ensureIfMissing = true,
  }) async {
    try {
      final docRef = _firestore.collection('app_config').doc('android');

      final snapshot = await docRef.get().timeout(timeout);
      if (snapshot.exists) {
        return AndroidAppConfig.fromFirestore(snapshot.data()!);
      }

      if (!ensureIfMissing) return null;

      // Client_create: create the document using Firestore security rules.
      // This intentionally does not block app startup if the write fails.
      await docRef
          .set(
            {
              'version_code': _defaultAndroidTemplate.versionCode,
              'version_name': _defaultAndroidTemplate.versionName,
              'apk_url': _defaultAndroidTemplate.apkUrl,
              'force_update': _defaultAndroidTemplate.forceUpdate,
              'changelog': _defaultAndroidTemplate.changelog,
            },
            SetOptions(merge: true),
          )
          .timeout(timeout);

      final afterSnap = await docRef.get().timeout(timeout);
      if (!afterSnap.exists || afterSnap.data() == null) return null;

      return AndroidAppConfig.fromFirestore(afterSnap.data()!);
    } on TimeoutException {
      return null; // Do not block startup.
    } catch (_) {
      // No internet / Firestore failure: skip silently.
      return null;
    }
  }
}

