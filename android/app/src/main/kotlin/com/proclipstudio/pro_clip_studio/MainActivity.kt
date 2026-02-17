package com.proclipstudio.pro_clip_studio

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import android.net.Uri
import com.proclipstudio.pro_clip_studio.SocialShareManager

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.proclipstudio/share"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        val shareManager = SocialShareManager(this)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            val filePath = call.argument<String>("filePath")
            val title = call.argument<String>("title") ?: ""
            
            when (call.method) {
                "share_tiktok" -> {
                    if (filePath != null) {
                        shareManager.shareToTikTok(filePath, title)
                        result.success(true)
                    } else result.error("NO_PATH", "Path null", null)
                }
                "share_instagram" -> {
                     if (filePath != null) {
                        shareManager.shareToInstagram(filePath, title)
                        result.success(true)
                    } else result.error("NO_PATH", "Path null", null)
                }
                "share_youtube" -> {
                     if (filePath != null) {
                        shareManager.shareToYouTube(filePath, title)
                        result.success(true)
                    } else result.error("NO_PATH", "Path null", null)
                }
                "share_system" -> {
                     if (filePath != null) {
                        shareManager.shareToSystem(filePath, title) // title used as chooser title here mostly
                        result.success(true)
                    } else result.error("NO_PATH", "Path null", null)
                }
                "getUriForFile" -> { // Legacy support
                    if (filePath != null) {
                        try {
                            val file = File(filePath)
                            val uri = FileProvider.getUriForFile(
                                this,
                                "${applicationContext.packageName}.fileprovider",
                                file
                            )
                            result.success(uri.toString())
                        } catch (e: Exception) {
                            result.error("URI_ERROR", e.message, null)
                        }
                    } else result.error("NO_PATH", "Path null", null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
