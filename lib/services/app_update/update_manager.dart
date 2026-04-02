import 'dart:async';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';

import 'apk_downloader.dart';
import 'update_models.dart';
import 'update_repository.dart';
import 'update_ui.dart';

class UpdateManager {
  static final UpdateManager instance = UpdateManager();

  final UpdateRepository _repository;
  final UpdateUI _ui;
  final ApkDownloader _downloader;

  bool _promptShownThisSession = false;
  bool _updateFlowRunning = false;

  static const _prefUpdateInProgress = 'update_in_progress';
  static const _prefUpdateVersionName = 'update_version_name';
  static const _prefUpdateDownloadId = 'update_download_id';
  static const _prefUpdateFilePath = 'update_file_path';

  UpdateManager({
    UpdateRepository? repository,
    UpdateUI? ui,
    ApkDownloader? downloader,
  })  : _repository = repository ?? UpdateRepository(),
        _ui = ui ?? UpdateUI(),
        _downloader = downloader ?? ApkDownloader();

  /// Compares `a` and `b` as `major.minor.patch`.
  /// Returns >0 if `a` is newer than `b`, 0 if equal, <0 if older.
  /// Returns null if either can't be parsed.
  int? _compareSemver(String a, String b) {
    List<int>? parse(String s) {
      final raw = s.trim();
      if (raw.isEmpty) return null;
      final parts = raw.split('.');
      if (parts.length < 2) return null;
      final nums = <int>[];
      for (final p in parts) {
        final cleaned = p.replaceAll(RegExp(r'[^0-9]'), '');
        final n = int.tryParse(cleaned);
        if (n == null) return null;
        nums.add(n);
      }
      while (nums.length < 3) {
        nums.add(0);
      }
      return nums.take(3).toList();
    }

    final av = parse(a);
    final bv = parse(b);
    if (av == null || bv == null) return null;
    for (var i = 0; i < 3; i++) {
      final d = av[i].compareTo(bv[i]);
      if (d != 0) return d;
    }
    return 0;
  }

  Future<bool> checkForUpdatesOnLaunch(BuildContext context) async {
    if (!Platform.isAndroid) return true;
    if (_promptShownThisSession) return true;
    _promptShownThisSession = true;

    final prefs = await SharedPreferences.getInstance();

    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersionName = packageInfo.version;

    final AndroidAppConfig? config =
        await _repository.fetchAndroidConfig(ensureIfMissing: true);
    if (config == null) return true; // Skip silently on failures.

    // Prefer comparing semantic version names (e.g. 1.2.2 -> 1.2.3) since many
    // release workflows only bump `versionName` and keep the build number.
    final cmp = _compareSemver(config.versionName, currentVersionName);
    final hasNewerByName = cmp != null && cmp > 0;
    if (!hasNewerByName) return true;

    // If an update download is already running (DownloadManager continues in background),
    // show a "please wait" UX and resume the flow instead of attempting to install a partial APK.
    final inProgress = prefs.getBool(_prefUpdateInProgress) ?? false;
    final inProgressVersionName = prefs.getString(_prefUpdateVersionName);
    if (inProgress && inProgressVersionName == config.versionName) {
      final decision = UpdateDecision(
        config: config,
        shouldForce: config.forceUpdate,
      );
      unawaited(_runUpdateFlow(context, decision, resumeIfPossible: true));
      // For optional updates: let the user continue using the app while the download
      // continues in the background. For force updates: block navigation.
      return !decision.shouldForce;
    }

    final decision = UpdateDecision(
      config: config,
      shouldForce: config.forceUpdate,
    );

    final proceed = await _ui.showUpdateDialog(
      context: context,
      changelog: config.changelog,
      forceUpdate: decision.shouldForce,
      externalUrl: config.apkUrl,
      onUpdateNow: () {
        // Start async update flow (dialog already popped false/blocked).
        unawaited(_runUpdateFlow(context, decision));
      },
    );

    // For force updates, or when the user pressed "Update Now", block navigation.
    if (decision.shouldForce) return false;
    return proceed;
  }

  Future<void> _runUpdateFlow(
    BuildContext context,
    UpdateDecision decision,
    {bool resumeIfPossible = false}
  ) async {
    if (_updateFlowRunning) return;
    _updateFlowRunning = true;
    try {
      final config = decision.config;
      final prefs = await SharedPreferences.getInstance();

      // Guard invalid URL early.
      final url = config.apkUrl;
      if (url.isEmpty || !(url.startsWith('https://') || url.startsWith('http://'))) {
        await _showErrorDialog(
          context,
          'Invalid APK URL',
          'The server provided an invalid download URL.',
          retry: true,
          force: decision.shouldForce,
        );
        return;
      }

      // Permission handling (REQUEST_INSTALL_PACKAGES).
      final installPerm = await Permission.requestInstallPackages.request();
      if (!installPerm.isGranted) {
        final retry = await _showErrorDialog(
          context,
          'Installation permission required',
          'Enable the installation permission to update this app.',
          retry: true,
          force: decision.shouldForce,
        );
        if (!retry) return;

        // Guide the user to enable the permission in system settings (best-effort).
        await openAppSettings();

        final retryPerm = await Permission.requestInstallPackages.request();
        if (!retryPerm.isGranted) return;
      }

      const fileName = 'app-update.apk';
      var resume = resumeIfPossible;

      while (true) {
        // If we already started a download in a previous session, wait for it to complete.
        if (resume) {
          final savedId = prefs.getInt(_prefUpdateDownloadId);
          final savedPath = prefs.getString(_prefUpdateFilePath);
          if (savedId == null || savedId <= 0 || savedPath == null || savedPath.isEmpty) {
            // We lost state (or app was killed) — clear and continue.
            await _clearUpdateState(prefs);
            resume = false;
          } else {
            final status = await _downloader.getDownloadStatus(savedId);

            // If we can't query status, avoid trapping the user; clear state and retry if forced.
            if (status == null) {
              await _clearUpdateState(prefs);
              if (!decision.shouldForce) return;
              resume = false;
            } else if (status.status == ApkDownloader.statusFailed) {
              // Internet lost / removed / quota / etc.
              await _clearUpdateState(prefs);
              if (!decision.shouldForce) return;
              final retry = await _showErrorDialog(
                context,
                'Download interrupted',
                'Update download failed or was interrupted. Please check your internet and try again.',
                retry: true,
                force: true,
              );
              if (!retry) return;
              resume = false;
            } else if (status.status == ApkDownloader.statusSuccessful) {
              // Download finished while app was closed/restarted.
              final installed = await _downloader.installApk(savedPath);
              if (installed) {
                await _clearUpdateState(prefs);
                return;
              }

              // File missing/corrupt/permission — clear and retry (forced) or stop (optional).
              await _clearUpdateState(prefs);
              if (!decision.shouldForce) return;
              resume = false;
            } else {
              // Pending/running/paused.
              if (!decision.shouldForce) {
                // Optional update: keep downloading in background without blocking UI,
                // and install automatically once download completes.
                final ok = await _downloader.waitForDownloadComplete(
                  downloadId: savedId,
                  filePath: savedPath,
                  timeout: const Duration(minutes: 15),
                );
                if (!ok) {
                  await _clearUpdateState(prefs);
                  return;
                }

                final installed = await _downloader.installApk(savedPath);
                if (installed) {
                  await _clearUpdateState(prefs);
                }
                return;
              }

              final dialogFuture =
                  _ui.showUpdatingDialog(context: context, externalUrl: config.apkUrl);
              final ok = await _downloader.waitForDownloadComplete(
                downloadId: savedId,
                filePath: savedPath,
                timeout: const Duration(minutes: 15),
              );
              if (Navigator.of(context, rootNavigator: true).canPop()) {
                Navigator.of(context, rootNavigator: true).pop();
              }
              await dialogFuture.catchError((_) {});

              if (!ok) {
                await _clearUpdateState(prefs);
                final retry = await _showErrorDialog(
                  context,
                  'Update not completed',
                  'The update is taking too long or the internet was lost. Please try again.',
                  retry: true,
                  force: true,
                );
                if (!retry) return;
                resume = false;
                continue;
              }

              final installed = await _downloader.installApk(savedPath);
              if (installed) {
                await _clearUpdateState(prefs);
                return;
              }

              await _clearUpdateState(prefs);
              final retry = await _showErrorDialog(
                context,
                'Installation failed',
                'Could not install the update. Please try again.',
                retry: true,
                force: true,
              );
              if (!retry) return;
              resume = false;
            }
          }
        }

        // Enqueue a new download and persist state immediately (so relaunch can resume).
        final expectedPath = await _downloader.getExpectedDownloadPath(fileName);
        final download = await _downloader.downloadApk(
          url: url,
          fileName: fileName,
        );

        if (download == null || download.downloadId == null) {
          await _clearUpdateState(prefs);
          final retry = await _showErrorDialog(
            context,
            'Download failed',
            'Could not start downloading the update. Check your internet connection and try again.',
            retry: true,
            force: decision.shouldForce,
          );
          if (!retry) return;
          continue;
        }

        await prefs.setBool(_prefUpdateInProgress, true);
        await prefs.setString(_prefUpdateVersionName, config.versionName);
        await prefs.setInt(_prefUpdateDownloadId, download.downloadId!);
        await prefs.setString(
          _prefUpdateFilePath,
          download.filePath.isNotEmpty ? download.filePath : (expectedPath ?? ''),
        );

        final dialogFuture = decision.shouldForce
            ? _ui.showUpdatingDialog(context: context, externalUrl: config.apkUrl)
            : Future<void>.value();
        final ok = await _downloader.waitForDownloadComplete(
          downloadId: download.downloadId!,
          filePath: download.filePath,
          timeout: const Duration(minutes: 15),
        );
        if (decision.shouldForce && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        await dialogFuture.catchError((_) {});

        if (!ok) {
          await _clearUpdateState(prefs);
          if (!decision.shouldForce) {
            // Optional update: don't trap the user.
            return;
          }
          final retry = await _showErrorDialog(
            context,
            'Download interrupted',
            'Internet may be lost or the phone was restarted. Please try downloading the update again.',
            retry: true,
            force: true,
          );
          if (!retry) return;
          continue;
        }

        final installed = await _downloader.installApk(download.filePath);
        if (installed) {
          await _clearUpdateState(prefs);
          return;
        }

        await _clearUpdateState(prefs);
        final retry = await _showErrorDialog(
          context,
          'Installation failed',
          'Your device did not allow installing from this source. Enable unknown app installation and try again.',
          retry: true,
          force: decision.shouldForce,
        );
        if (!retry) return;
      }
    } finally {
      _updateFlowRunning = false;
    }
  }

  Future<void> _clearUpdateState(SharedPreferences prefs) async {
    await prefs.remove(_prefUpdateInProgress);
    await prefs.remove(_prefUpdateVersionName);
    await prefs.remove(_prefUpdateDownloadId);
    await prefs.remove(_prefUpdateFilePath);
  }

  Future<bool> _showErrorDialog(
    BuildContext context,
    String title,
    String message, {
    required bool retry,
    required bool force,
  }) async {
    // If non-forced, allow Cancel for optional updates.
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: force ? false : true,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          if (!force)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retry'),
          ),
        ],
      ),
    );

    final popped = result ?? false;
    // If retry=false is ever needed later, respect it.
    return retry && popped;
  }
}

void unawaited(Future<void> future) {}

