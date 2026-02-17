
import 'package:flutter/services.dart';
import 'dart:async';

class TitaniumService {
  static const MethodChannel _channel = MethodChannel('com.clipper.titanium/engine');
  static const EventChannel _eventChannel = EventChannel('com.clipper.titanium/events');
  
  static final StreamController<double> _progressController = StreamController<double>.broadcast();
  static Stream<double> get onProgress => _progressController.stream;

  static void initEvents() {
    _eventChannel.receiveBroadcastStream().listen((event) {
        if (event is Map) {
           if (event['event'] == 'progress') {
               final val = event['value'];
               if (val is double) _progressController.add(val);
               if (val is int) _progressController.add(val.toDouble());
           }
        }
    });
  }

  /// Initialize the Titanium Engine (EGL Context, Shader compilation)
  static Future<void> init() async {
    try {
      await _channel.invokeMethod('init');
      initEvents();
    } catch (e) {
      print("Native Engine Init Failed: $e");
    }
  }

  /// Exports a video using the Titanium Render Graph.
  /// Returns a Job ID.
  static Future<String?> export({
    required String sourcePath,
    required String destPath,
    Map<String, dynamic>? config,
  }) async {
    try {
      final String? jobId = await _channel.invokeMethod('export', {
        'source': sourcePath,
        'dest': destPath,
        'config': config ?? {},
      });
      return jobId;
    } catch (e) {
      print("Titanium Export Failed: $e");
      return null;
    }
  }

  /// Pre-warms the decoder for a specific video file.
  static Future<void> warmup(String sourcePath) async {
      await _channel.invokeMethod('warmup', {'source': sourcePath});
  }

  static Future<void> dispose() async {
      await _channel.invokeMethod('dispose');
  }
}
