import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ClipRepository {
  static const _key = 'clip_upload_statuses';

  // Map<FileName, Map<Platform, bool>>
  static Map<String, Map<String, bool>> _statuses = {};
  
  static const _keyHidden = 'clip_hidden_statuses';
  static Set<String> _hiddenClips = {}; // Set of filenames

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load Upload Statuses
    final String? data = prefs.getString(_key);
    if (data != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(data);
        _statuses = decoded.map((key, value) {
          return MapEntry(key, Map<String, bool>.from(value));
        });
      } catch (e) {
        print("Error loading clip status: $e");
      }
    }

    // Load Hidden Statuses
    final List<String>? hiddenData = prefs.getStringList(_keyHidden);
    if (hiddenData != null) {
      _hiddenClips = hiddenData.toSet();
    }
  }

  static Future<void> markUploaded(String fileName, String platform) async {
    if (!_statuses.containsKey(fileName)) {
      _statuses[fileName] = {};
    }
    _statuses[fileName]![platform] = true;
    await _save();
  }

  static Future<void> markNotUploaded(String fileName, String platform) async {
    if (_statuses.containsKey(fileName)) {
      _statuses[fileName]![platform] = false;
      await _save();
    }
  }

  static Future<void> removeStatus(String fileName) async {
    bool changed = false;
    if (_statuses.containsKey(fileName)) {
      _statuses.remove(fileName);
      changed = true;
    }
    if (_hiddenClips.contains(fileName)) {
      _hiddenClips.remove(fileName);
      changed = true;
    }
    
    if (changed) await _save();
  }

  static Future<void> prune(Set<String> activeFilenames) async {
    bool changed = false;
    
    // Convert to list to avoid concurrent modification during iteration
    final statusKeys = _statuses.keys.toList();
    for (final key in statusKeys) {
      if (!activeFilenames.contains(key)) {
        _statuses.remove(key);
        changed = true;
      }
    }
    
    final hiddenKeys = _hiddenClips.toList();
    for (final key in hiddenKeys) {
      if (!activeFilenames.contains(key)) {
        _hiddenClips.remove(key);
        changed = true;
      }
    }
    
    if (changed) {
      print("Pruned orphaned data.");
      await _save();
    }
  }

  static bool isUploaded(String fileName, String platform) {
    return _statuses[fileName]?[platform] ?? false;
  }
  
  static bool isfullyUploaded(String fileName) {
    final status = _statuses[fileName];
    if (status == null) return false;
    return (status['instagram'] == true) && 
           (status['tiktok'] == true) && 
           (status['youtube'] == true);
  }
  
  static bool isPartiallyUploaded(String fileName) {
     final status = _statuses[fileName];
     if (status == null) return false;
     return status.values.any((v) => v == true);
  }

  // --- Hidden / Archive Logic ---
  static bool isHidden(String fileName) {
    return _hiddenClips.contains(fileName);
  }

  static Future<void> setHidden(String fileName, bool hidden) async {
    if (hidden) {
      _hiddenClips.add(fileName);
    } else {
      _hiddenClips.remove(fileName);
    }
    await _save();
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_statuses));
    await prefs.setStringList(_keyHidden, _hiddenClips.toList());
  }
}
