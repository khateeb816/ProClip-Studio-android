package com.proclipstudio.pro_clip_studio

import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.widget.Toast
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * SOCIAL SHARE MANAGER (Pro Gallery Level)
 *
 * Implements robust MediaStore integration:
 * 1. Checks Cache -> Scans -> Inserts (if needed).
 * 2. Uses IS_PENDING for atomic writes.
 * 3. Prevents duplicate inserts.
 * 4. Delays launch to allow MediaScanner indexing.
 */
class SocialShareManager(private val context: Context) {

    companion object {
        private const val TAG = "SocialShareManager"
        private const val PKG_TIKTOK = "com.zhiliaoapp.musically"
        private const val PKG_TIKTOK_GLOBAL = "com.ss.android.ugc.trill"
        private const val PKG_INSTAGRAM = "com.instagram.android"
        private const val MIME_VIDEO = "video/mp4"
        private const val ALBUM_NAME = "ProClipStudio"
        
        // Cache to prevent duplicate inserts for the same session
        private val uriCache = ConcurrentHashMap<String, Uri>()
    }

    /**
     * Share to TikTok
     * FIX: Removed Deep Link (snssdk) which fails to attach video. 
     * Uses strict Package Intent + ClipData for permissions.
     */
    fun shareToTikTok(filePath: String, title: String = "") {
        resolveContentUri(filePath) { uri ->
            if (uri == null) {
                showError("Failed to prepare video for TikTok")
                return@resolveContentUri
            }
            Log.d(TAG, "Launching TikTok with URI: $uri")
            
            // 300ms Delay to mimic Gallery behavior (allows scanner to settle)
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                launchTikTok(uri, title)
            }, 300)
        }
    }

    private fun launchTikTok(uri: Uri, title: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "video/*" // Use broader mime type
            putExtra(Intent.EXTRA_STREAM, uri)
            if (title.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, title)
            clipData = ClipData.newRawUri("Video", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        // Find the specific activity in TikTok that handles ACTION_SEND
        var targetPkg = PKG_TIKTOK
        var bestActivityStr: String? = null
        
        fun findBestComponent(pkg: String): String? {
             intent.setPackage(pkg)
             val matches = context.packageManager.queryIntentActivities(intent, 0)
             if (matches.isEmpty()) return null
             
             // Log all candidates
             matches.forEach { 
                 Log.d(TAG, "TikTok Candidate: ${it.activityInfo.name}") 
             }

             // Strategy:
             // 1. Look for 'Publish' or 'Record' (Deepest)
             val publishActivity = matches.find { 
                 it.activityInfo.name.contains("Publish", ignoreCase = true) ||
                 it.activityInfo.name.contains("Record", ignoreCase = true)
             }
             if (publishActivity != null) return publishActivity.activityInfo.name

             // 2. Look for 'ShareActivity' (Often the direct share)
             val shareActivity = matches.find {
                  it.activityInfo.name.contains("ShareActivity", ignoreCase = true) &&
                  !it.activityInfo.name.contains("SystemShare", ignoreCase = true)
             }
             if (shareActivity != null) return shareActivity.activityInfo.name

             // 3. Look for 'SystemShareActivity' (The gateway)
             val systemShare = matches.find { 
                 it.activityInfo.name.contains("SystemShareActivity", ignoreCase = true) 
             }
             if (systemShare != null) return systemShare.activityInfo.name

             // 4. Avoid IM/Messenger
             val nonImMatches = matches.filter { 
                 val name = it.activityInfo.name.lowercase()
                 !name.contains(".im.") && !name.contains("messenger") && !name.contains("dm")
             }
             
             if (nonImMatches.isNotEmpty()) {
                 return nonImMatches[0].activityInfo.name
             }
             
             // Fallback to first match
             return matches[0].activityInfo.name
        }

        val activityName = findBestComponent(PKG_TIKTOK) ?: findBestComponent(PKG_TIKTOK_GLOBAL)
        
        if (activityName != null) {
            // Simplified package resolution
            val finalPkg = if (findBestComponent(PKG_TIKTOK) != null) PKG_TIKTOK else PKG_TIKTOK_GLOBAL
            
            Log.d(TAG, "Targeting TikTok Activity: $activityName")
            
            intent.setPackage(finalPkg)
            intent.setClassName(finalPkg, activityName)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            
            try {
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.e(TAG, "TikTok explicit launch failed: ${e.message}")
                // Fallback to generic package intent
                val fallback = Intent(Intent.ACTION_SEND).apply {
                    type = "video/*"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    if (title.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, title)
                    clipData = ClipData.newRawUri("Video", uri)
                    setPackage(finalPkg)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(fallback)
            }
        } else {
            Log.w(TAG, "TikTok specific share activity not found. Fallback to System.")
            shareToSystemUri(uri, title)
        }
    }

    /**
     * Share to Instagram
     */
    fun shareToInstagram(filePath: String, title: String = "") {
        resolveContentUri(filePath) { uri ->
            if (uri == null) {
                showError("Failed to prepare video for Instagram")
                return@resolveContentUri
            }
             Log.d(TAG, "Launching Instagram with URI: $uri")

            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                launchInstagram(uri, title)
            }, 300)
        }
    }

    private fun launchInstagram(uri: Uri, title: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = MIME_VIDEO
            putExtra(Intent.EXTRA_STREAM, uri)
            if (title.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, title)
            
            clipData = ClipData.newRawUri("Video", uri) // Safety
            
            setPackage(PKG_INSTAGRAM)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            if (isValidIntent(intent)) {
                context.startActivity(intent)
            } else {
                shareToSystemUri(uri, title)
            }
        } catch (e: Exception) {
            shareToSystemUri(uri, title)
        }
    }

    /**
     * Share to YouTube
     */
    fun shareToYouTube(filePath: String, title: String = "") {
        resolveContentUri(filePath) { uri ->
            if (uri == null) {
                showError("Failed to prepare video for YouTube")
                return@resolveContentUri
            }
            Log.d(TAG, "Launching YouTube with URI: $uri")

            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                launchYouTube(uri, title)
            }, 300)
        }
    }

    private fun launchYouTube(uri: Uri, title: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = MIME_VIDEO
            putExtra(Intent.EXTRA_STREAM, uri)
            
            // YouTube uses SUBJECT for Title, TEXT for Description
            if (title.isNotEmpty()) {
                putExtra(Intent.EXTRA_SUBJECT, title)
                putExtra(Intent.EXTRA_TEXT, title)
            }
            
            clipData = ClipData.newRawUri("Video", uri)
            setPackage("com.google.android.youtube")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            if (isValidIntent(intent)) {
                context.startActivity(intent)
            } else {
                Log.w(TAG, "YouTube app not found.")
                shareToSystemUri(uri, title)
            }
        } catch (e: Exception) {
            Log.e(TAG, "YouTube launch error: ${e.message}")
            shareToSystemUri(uri, title)
        }
    }

    /**
     * System Share
     */
    fun shareToSystem(filePath: String, title: String = "Share Video") {
        resolveContentUri(filePath) { uri ->
            if (uri == null) {
                showError("Failed to prepare video")
                return@resolveContentUri
            }
            
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                shareToSystemUri(uri, title)
            }, 300)
        }
    }

    private fun shareToSystemUri(uri: Uri, title: String) {
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = MIME_VIDEO
                putExtra(Intent.EXTRA_STREAM, uri)
                if (title.isNotEmpty() && title != "Share Video") {
                    putExtra(Intent.EXTRA_TEXT, title)
                    putExtra(Intent.EXTRA_TITLE, title)
                }
                clipData = ClipData.newRawUri("Video", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, title).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(chooser)
        } catch (e: Exception) {
            showError("Share failed: ${e.message}")
        }
    }

    // ============================================================================================
    // MEDIA STORE PIPELINE
    // ============================================================================================

    private fun resolveContentUri(filePath: String, callback: (Uri?) -> Unit) {
        // 1. Check Cache
        if (uriCache.containsKey(filePath)) {
            callback(uriCache[filePath])
            return
        }

        val file = File(filePath)
        if (!file.exists()) {
            callback(null)
            return
        }

        // 2. Try Scanner First (Zero Copy if possible)
        MediaScannerConnection.scanFile(context, arrayOf(filePath), null) { _, uri ->
             // If scanner found valid public URI, use it
             if (uri != null && "content" == uri.scheme) {
                 Log.d(TAG, "Scanner found existing URI: $uri")
                 uriCache[filePath] = uri
                 runOnUiThread { callback(uri) }
             } else {
                 // 3. Manual Insert (if scanner failed or returned file://)
                 Log.d(TAG, "Scanner returned null/file, performing manual insert...")
                 runOnUiThread {
                     val newUri = insertToMediaStore(file)
                     if (newUri != null) {
                         uriCache[filePath] = newUri
                         callback(newUri)
                     } else {
                         callback(null)
                     }
                 }
             }
        }
    }

    private fun insertToMediaStore(sourceFile: File): Uri? {
        val contentValues = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, "Clip_${System.currentTimeMillis()}.mp4") // Unique name
            put(MediaStore.Video.Media.MIME_TYPE, MIME_VIDEO)
            put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis() / 1000)
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/$ALBUM_NAME")
                put(MediaStore.Video.Media.IS_PENDING, 1) // Critical for atomic write
            }
        }

        val resolver = context.contentResolver
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }

        var uri: Uri? = null
        try {
            uri = resolver.insert(collection, contentValues)
            if (uri == null) {
                Log.e(TAG, "Failed to insert MediaStore row")
                return null
            }

            // Stream Copy
            resolver.openOutputStream(uri)?.use { os ->
                FileInputStream(sourceFile).use { fis ->
                    fis.copyTo(os)
                }
            }

            // Finish Pending State
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentValues.clear()
                contentValues.put(MediaStore.Video.Media.IS_PENDING, 0)
                resolver.update(uri, contentValues, null, null)
            }
            
            Log.d(TAG, "Inserted to MediaStore: $uri")
            return uri

        } catch (e: Exception) {
            Log.e(TAG, "Insert Failed: ${e.message}")
            // Consider cleanup if handy, but usually fine
            return null
        }
    }

    private fun runOnUiThread(action: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(action)
    }

    private fun isValidIntent(intent: Intent): Boolean {
        val activities = context.packageManager.queryIntentActivities(intent, 0)
        return activities.isNotEmpty()
    }

    private fun showError(msg: String) {
        Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
    }
}
