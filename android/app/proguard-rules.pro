# Proguard rules for ProClip Studio

# Keep the native Titanium engine classes
-keep class com.proclipstudio.pro_clip_studio.video.** { *; }

# Keep FFmpeg Kit classes
-keep class com.arthenica.ffmpegkit.** { *; }

# Photo Manager (Essential for Media Picker in Release)
-keep class com.fluttercandies.photo_manager.** { *; }

# Gal (Saving to gallery)
-keep class i.am.taking.free.time.gal.** { *; }

# Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }

# Keep Flutter and plugin classes (usually handled by Flutter Gradle plugin, but being safe)
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }

# Prevent stripping of JNI methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Ignore Play Core warnings (common in Flutter release builds)
-dontwarn com.google.android.play.core.**

# Permission Handler
-keep class com.baseflow.permissionhandler.** { *; }
-keep interface com.baseflow.permissionhandler.** { *; }
-dontwarn com.baseflow.permissionhandler.**

# Device Info Plus
-keep class dev.fluttercommunity.plus.device_info.** { *; }
-keep interface dev.fluttercommunity.plus.device_info.** { *; }
-dontwarn dev.fluttercommunity.plus.device_info.**
