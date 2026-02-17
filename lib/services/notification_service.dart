import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  
  static Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: androidSettings);
    
    await _notifications.initialize(settings);
    
    // Create channel
    const channel = AndroidNotificationChannel(
      'export_channel',
      'Export Progress',
      description: 'Shows video export progress',
      importance: Importance.low, // Low = no sound/vibration for progress updates
    );
    
    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> showProgress(int progress, {String? message}) async {
    try {
      await _notifications.show(
         1,
         'Exporting Video',
         message ?? '$progress%',
         NotificationDetails(
           android: AndroidNotificationDetails(
             'export_channel',
             'Export Progress',
             channelDescription: 'Shows video export progress',
             importance: Importance.low,
             priority: Priority.low,
             showProgress: true,
             maxProgress: 100,
             progress: progress,
             onlyAlertOnce: true,
             ongoing: true, // User cannot dismiss while running
             icon: '@mipmap/ic_launcher',
             largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
           ),
         ),
      );
    } catch (e) {
      print("⚠️ Notification Error: $e");
      // Fallback: Try without largeIcon if that was the issue, or just ignore.
      // We don't want to crash the export.
    }
  }
  
  static Future<void> showDone(String? path) async {
    try {
      await _notifications.show(
         1,
         path != null ? 'Video Clip exported' : 'Export Failed',
         path != null ? 'Your video is ready' : 'An error occurred',
         const NotificationDetails(
           android: AndroidNotificationDetails(
             'export_channel',
             'Export Progress',
             importance: Importance.high, 
             priority: Priority.high,
             showProgress: false,
             ongoing: false,
             icon: '@mipmap/ic_launcher',
             largeIcon: DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
           ),
         ),
      );
    } catch (e) {
       print("⚠️ Notification Error: $e");
    }
  }

  static Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }
}
