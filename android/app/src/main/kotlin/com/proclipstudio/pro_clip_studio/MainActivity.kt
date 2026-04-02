package com.proclipstudio.pro_clip_studio

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File
import android.net.Uri
import android.app.DownloadManager
import android.os.Environment
import android.content.Intent
import android.content.Context
import com.proclipstudio.pro_clip_studio.SocialShareManager

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.proclipstudio/share"
    private val UPDATE_CHANNEL = "com.proclipstudio/app_update"

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

        // App update download/install via Android DownloadManager + ACTION_VIEW.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getExpectedDownloadPath" -> {
                    try {
                        val fileName = call.argument<String>("fileName") ?: "app-update.apk"
                        val downloadsDir =
                            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        val apkFile = File(downloadsDir, fileName)
                        result.success(apkFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("PATH_ERROR", e.message, null)
                    }
                }

                "getDownloadStatus" -> {
                    try {
                        val downloadId = call.argument<Number>("downloadId")?.toLong()
                        if (downloadId == null || downloadId <= 0L) {
                            result.error("NO_ID", "Download id missing", null)
                            return@setMethodCallHandler
                        }

                        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        val query = DownloadManager.Query().setFilterById(downloadId)
                        val cursor = dm.query(query)
                        cursor.use { c ->
                            if (c == null || !c.moveToFirst()) {
                                result.success(
                                    mapOf(
                                        "status" to DownloadManager.STATUS_FAILED,
                                        "reason" to -1
                                    )
                                )
                                return@setMethodCallHandler
                            }

                            val statusIdx = c.getColumnIndex(DownloadManager.COLUMN_STATUS)
                            val reasonIdx = c.getColumnIndex(DownloadManager.COLUMN_REASON)

                            val status = if (statusIdx >= 0) c.getInt(statusIdx) else DownloadManager.STATUS_FAILED
                            val reason = if (reasonIdx >= 0) c.getInt(reasonIdx) else 0

                            result.success(
                                mapOf(
                                    "status" to status,
                                    "reason" to reason
                                )
                            )
                        }
                    } catch (e: Exception) {
                        result.error("STATUS_ERROR", e.message, null)
                    }
                }

                "downloadApk" -> {
                    try {
                        val url = call.argument<String>("url")
                        val fileName = call.argument<String>("fileName") ?: "app-update.apk"

                        if (url == null || url.isEmpty()) {
                            result.error("NO_URL", "APK URL missing", null)
                            return@setMethodCallHandler
                        }

                        val downloadsDir =
                            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        val apkFile = File(downloadsDir, fileName)

                        // Prevent duplicates by deleting the old file.
                        if (apkFile.exists()) {
                            apkFile.delete()
                        }

                        val request = DownloadManager.Request(Uri.parse(url))
                        request.setTitle("ProClip Studio Update")
                        request.setDescription("Downloading update...")
                        request.setNotificationVisibility(
                            DownloadManager.Request.VISIBILITY_VISIBLE
                        )
                        request.setAllowedOverMetered(true)
                        request.setAllowedOverRoaming(true)
                        request.setDestinationInExternalPublicDir(
                            Environment.DIRECTORY_DOWNLOADS,
                            fileName
                        )

                        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        val downloadId = dm.enqueue(request)

                        result.success(
                            mapOf(
                                "downloadId" to downloadId,
                                "filePath" to apkFile.absolutePath
                            )
                        )
                    } catch (e: Exception) {
                        result.error("DOWNLOAD_ERROR", e.message, null)
                    }
                }

                "installApk" -> {
                    try {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null || filePath.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val apkFile = File(filePath)
                        if (!apkFile.exists()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val contentUri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            apkFile
                        )

                        val intent = Intent(Intent.ACTION_VIEW)
                        intent.setDataAndType(
                            contentUri,
                            "application/vnd.android.package-archive"
                        )
                        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
