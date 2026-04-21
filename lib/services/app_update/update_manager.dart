import 'dart:async';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';

import 'update_models.dart';
import 'update_repository.dart';
import 'update_ui.dart';

class UpdateManager {
  static final UpdateManager instance = UpdateManager();

  final UpdateRepository _repository;
  final UpdateUI _ui;

  bool _promptShownThisSession = false;

  UpdateManager({
    UpdateRepository? repository,
    UpdateUI? ui,
  })  : _repository = repository ?? UpdateRepository(),
        _ui = ui ?? UpdateUI();

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

    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersionName = packageInfo.version;

    final AndroidAppConfig? config =
        await _repository.fetchAndroidConfig(ensureIfMissing: true);
    if (config == null) return true; // Skip silently on failures.

    // Prefer comparing semantic version names (e.g. 1.2.2 -> 1.2.3)
    final cmp = _compareSemver(config.versionName, currentVersionName);
    final hasNewerByName = cmp != null && cmp > 0;
    if (!hasNewerByName) return true;

    final proceed = await _ui.showUpdateDialog(
      context: context,
      changelog: config.changelog,
      forceUpdate: config.forceUpdate,
      externalUrl: config.apkUrl,
      onUpdateNow: () {
        // No longer used.
      },
    );

    // For force updates, block navigation.
    if (config.forceUpdate) return false;
    return proceed;
  }
}

void unawaited(Future<void> future) {}

