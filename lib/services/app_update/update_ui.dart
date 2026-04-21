import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateUI {
  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> showUpdatingDialog({
    required BuildContext context,
    String message = 'App is updating, please wait…',
    String? externalUrl,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Updating'),
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(message)),
            ],
          ),
          actions: [
            if (externalUrl != null && externalUrl.isNotEmpty)
              TextButton(
                onPressed: () => _openExternal(externalUrl),
                child: const Text('Update'),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> showUpdateDialog({
    required BuildContext context,
    required String changelog,
    required bool forceUpdate,
    required VoidCallback onUpdateNow,
    String? externalUrl,
  }) async {
    if (forceUpdate) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Update Available'),
          content: Text(changelog.isEmpty ? 'A new update is available.' : changelog),
          actions: [
            if (externalUrl != null && externalUrl.isNotEmpty)
              TextButton(
                onPressed: () => _openExternal(externalUrl),
                child: const Text('Update'),
              ),
          ],
        ),
      );
      // Force flow doesn't let user continue.
      return false;
    }

    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Available'),
        content: Text(changelog.isEmpty ? 'A new update is available.' : changelog),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true), // Later
            child: const Text('Later'),
          ),
          if (externalUrl != null && externalUrl.isNotEmpty)
            TextButton(
              onPressed: () => _openExternal(externalUrl),
              child: const Text('Update'),
            ),
        ],
      ),
    );

    return proceed ?? true;
  }
}

