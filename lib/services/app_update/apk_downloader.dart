import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class DownloadManagerStatus {
  final int status;
  final int reason;

  const DownloadManagerStatus({
    required this.status,
    required this.reason,
  });
}

class ApkDownloadResult {
  final String filePath;
  final int? downloadId;

  const ApkDownloadResult({
    required this.filePath,
    required this.downloadId,
  });
}

class ApkDownloader {
  static const MethodChannel _channel =
      MethodChannel('com.proclipstudio/app_update');

  // Android DownloadManager status constants
  static const int statusPending = 1;
  static const int statusRunning = 2;
  static const int statusPaused = 4;
  static const int statusSuccessful = 8;
  static const int statusFailed = 16;

  Future<DownloadManagerStatus?> getDownloadStatus(int downloadId) async {
    if (downloadId <= 0) return null;
    try {
      final Map<dynamic, dynamic> res =
          await _channel.invokeMethod('getDownloadStatus', <String, dynamic>{
        'downloadId': downloadId,
      });
      final status = res['status'] is int ? res['status'] as int : 0;
      final reason = res['reason'] is int ? res['reason'] as int : 0;
      return DownloadManagerStatus(status: status, reason: reason);
    } catch (_) {
      return null;
    }
  }

  Future<String?> getExpectedDownloadPath(String fileName) => _getExpectedDownloadPath(fileName);

  Future<bool> waitForDownloadComplete({
    required int downloadId,
    required String filePath,
    Duration pollInterval = const Duration(seconds: 1),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = await getDownloadStatus(downloadId);
      if (status != null) {
        if (status.status == statusSuccessful) {
          final f = File(filePath);
          return await f.exists() && await f.length() > 0;
        }
        if (status.status == statusFailed) {
          return false;
        }
        // pending/running/paused => keep waiting
      }
      await Future.delayed(pollInterval);
    }
    return false;
  }

  /// Enqueue a download in Android DownloadManager and return immediately.
  /// Use [waitForDownloadComplete] to await completion.
  Future<ApkDownloadResult?> downloadApk({
    required String url,
    required String fileName,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isAbsolute || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    // Kick off DownloadManager download on native side.
    final Map<dynamic, dynamic> res = await _channel
        .invokeMethod('downloadApk', <String, dynamic>{
          'url': url,
          'fileName': fileName,
        })
        .timeout(timeout);

    final path = res['filePath']?.toString();
    final downloadId = res['downloadId'] is int ? res['downloadId'] as int : null;
    if (path == null || path.isEmpty) return null;

    return ApkDownloadResult(filePath: path, downloadId: downloadId);
  }

  /// Request native code to compute the expected path so we can avoid duplicates.
  Future<String?> _getExpectedDownloadPath(String fileName) async {
    try {
      final res = await _channel.invokeMethod<String?>(
        'getExpectedDownloadPath',
        <String, dynamic>{'fileName': fileName},
      );
      return res;
    } catch (_) {
      return null;
    }
  }

  Future<bool> installApk(String filePath) async {
    if (filePath.isEmpty) return false;
    try {
      final res = await _channel.invokeMethod<bool>(
        'installApk',
        <String, dynamic>{'filePath': filePath},
      );
      return res == true;
    } catch (_) {
      return false;
    }
  }
}

