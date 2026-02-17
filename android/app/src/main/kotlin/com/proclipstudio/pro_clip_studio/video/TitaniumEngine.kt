package com.proclipstudio.pro_clip_studio.video

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.nio.ByteBuffer

/**
 * TITANIUM VIDEO ENGINE
 * 
 * The Core Controller for the Hybrid Multi-GPU Pipeline.
 * Manages:
 * 1. MethodChannel Bridge
 * 2. RenderGraph Scheduler
 * 3. EGL Context Persistence
 */
class TitaniumEngine(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val CHANNEL = "com.clipper.titanium/engine"
        const val EVENTS = "com.clipper.titanium/events"
        private val executor = Executors.newSingleThreadExecutor() 
    }

    private var eventSink: EventChannel.EventSink? = null

    // Engine State
    private var isInitialized = false
    
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> {
                initEngine()
                result.success(true)
            }
            "export" -> {
                val source = call.argument<String>("source")
                val dest = call.argument<String>("dest")
                val config = call.argument<Map<String, Any>>("config")
                
                if (source != null && dest != null) {
                    executeExport(source, dest, config, result)
                } else {
                    result.error("INVALID_ARGS", "Source or Dest missing", null)
                }
            } 
            "multi_export" -> {
                val source = call.argument<String>("source")
                val configs = call.argument<List<Map<String, Any>>>("configs")
                if (source != null && configs != null) {
                    executeMultiExport(source, configs, result)
                } else {
                    result.error("INVALID_ARGS", "Source or Configs missing", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun initEngine() {
        if (isInitialized) return
        isInitialized = true
    }

    private fun executeExport(source: String, dest: String, config: Map<String, Any>?, result: MethodChannel.Result) {
        val singleConfig = (config?.toMutableMap() ?: mutableMapOf()).apply {
            put("dest", dest)
        }
        executeMultiExport(source, listOf(singleConfig), result)
    }

    private fun executeMultiExport(source: String, configs: List<Map<String, Any>>, result: MethodChannel.Result) {
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        
        executor.submit {
            var graph: com.proclipstudio.pro_clip_studio.video.render.RenderGraph? = null
            var ctxManager: com.proclipstudio.pro_clip_studio.video.render.TitaniumGLContextManager? = null
            var decoderRef: com.proclipstudio.pro_clip_studio.video.render.TitaniumDecoder? = null
            
            try {
                // 1. Init Persistent Context
                ctxManager = com.proclipstudio.pro_clip_studio.video.render.TitaniumGLContextManager()
                
                for ((index, config) in configs.withIndex()) {
                    val dest = config["dest"] as String
                    val startTime = (config["startTime"] as? Number)?.toLong() ?: 0L 
                    val duration = (config["duration"] as? Number)?.toLong() ?: -1L
                    val endTime = if (duration > 0) startTime + duration else -1L
                    
                    val cropW = (config["cropW"] as? Number)?.toDouble() ?: 1.0
                    val cropH = (config["cropH"] as? Number)?.toDouble() ?: 1.0
                    val cropX = (config["cropX"] as? Number)?.toDouble() ?: 0.0
                    val cropY = (config["cropY"] as? Number)?.toDouble() ?: 0.0
                    val hasMusic = config["audioPath"] != null
                    
                    val reportBatchProgress: (Float) -> Unit = { clipProgress ->
                        val totalProgress = (index + clipProgress) / configs.size
                        mainHandler.post {
                            eventSink?.success(mapOf("event" to "progress", "value" to totalProgress))
                        }
                    }

                    // TIER DECISION
                    val isCrop = cropW < 0.99 || cropH < 0.99 || cropX > 0.01 || cropY > 0.01
                    val isTransform = false 
                    
                    if (!isCrop && !isTransform && !hasMusic) {
                        // TIER 1: Stream Copy
                        fastStreamCopy(source, dest, startTime * 1000, endTime * 1000) { p ->
                            reportBatchProgress(p)
                        }
                        continue
                    }
                    
                    // TIER 2: GPU TRANSFORM
                    val configWidth = (config["width"] as? Int) ?: 720
                    val configHeight = (config["height"] as? Int) ?: 1280
                    
                    graph = com.proclipstudio.pro_clip_studio.video.render.RenderGraph(ctxManager, configWidth, configHeight)
                    graph?.setup(
                        source, 
                        dest,
                        cropX.toFloat(),
                        cropY.toFloat(),
                        cropW.toFloat(),
                        cropH.toFloat(),
                        decoderRef 
                    )
                    
                    graph?.execute { progress ->
                         reportBatchProgress(progress)
                    }
                    
                    graph?.release()
                    graph = null
                }
                
                mainHandler.post {
                    eventSink?.success(mapOf("event" to "progress", "value" to 1.0))
                    result.success(configs.last()["dest"])
                }
                
            } catch (e: Exception) {
                e.printStackTrace()
                mainHandler.post {
                    result.error("EXPORT_FAILED", e.message, null)
                }
            } finally {
                ctxManager?.release()
                // SNAPDRAGON MEMORY OPTIMIZATION
                // Explicit GC to clear DirectByteBuffers used by MediaCodec/Extractor
                // forcing native memory release.
                System.gc() 
            }
        }
    }

    private fun fastStreamCopy(source: String, dest: String, startUs: Long, endUs: Long, onProgress: (Float) -> Unit) {
        val extractor = MediaExtractor()
        val muxer = MediaMuxer(dest, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        
        try {
            extractor.setDataSource(source)
            
            val trackMap = HashMap<Int, Int>()
            var videoTrackIndex = -1
            var fileDurationUs = 0L
            
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME)
                
                if (mime?.startsWith("video/") == true) {
                    videoTrackIndex = i
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                         fileDurationUs = format.getLong(MediaFormat.KEY_DURATION)
                    }
                }
                
                extractor.selectTrack(i)
                trackMap[i] = muxer.addTrack(format)
            }
            
            if (startUs > 0) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            
            var globalStartOffsetUs = -1L
            val buffer = ByteBuffer.allocate(2 * 1024 * 1024) // 2MB buffer
            val bufferInfo = MediaCodec.BufferInfo()
            
            var muxerStarted = false
            try {
                 muxer.start()
                 muxerStarted = true
            } catch (e: Exception) {
                 android.util.Log.e("TitaniumEngine", "Muxer Start Failed: ${e.message}")
                 return
            }
            
            val targetDuration = if (endUs > 0) endUs - startUs else fileDurationUs - startUs
            var lastProgress = 0L
            var framesWritten = 0
            
            while (true) {
                val trackIndex = extractor.sampleTrackIndex
                if (trackIndex < 0) break
                
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                
                val time = extractor.sampleTime
                if (endUs > 0 && time > endUs && framesWritten > 0) break // Ensure at least 1 frame
                
                if (globalStartOffsetUs == -1L) globalStartOffsetUs = time 
                
                val muxerTrackIndex = trackMap[trackIndex]
                if (muxerTrackIndex != null) {
                    bufferInfo.offset = 0
                    bufferInfo.size = size
                    bufferInfo.flags = extractor.sampleFlags
                    bufferInfo.presentationTimeUs = time - globalStartOffsetUs
                    if (bufferInfo.presentationTimeUs < 0) bufferInfo.presentationTimeUs = 0
                    
                    muxer.writeSampleData(muxerTrackIndex, buffer, bufferInfo)
                    framesWritten++
                    
                    if (trackIndex == videoTrackIndex && targetDuration > 0) {
                         val currentProg = time - startUs
                         if (currentProg > 0 && System.currentTimeMillis() - lastProgress > 50) {
                             val p = (currentProg.toDouble() / targetDuration.toDouble()).toFloat().coerceIn(0f, 1f)
                             onProgress(p)
                             lastProgress = System.currentTimeMillis()
                         }
                    }
                }
                
                extractor.advance()
            }
            
            if (muxerStarted) {
                try {
                    muxer.stop()
                } catch (e: Exception) {
                    android.util.Log.e("TitaniumEngine", "Muxer Stop Failed (Frames: $framesWritten): ${e.message}")
                }
            }
            
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            try {
                muxer.release()
            } catch (e: Exception) {}
            extractor.release()
        }
    }

    private fun warmupDecoder(path: String?) {
        // Implementation omitted for brevity/unused in current flow
    }

    fun dispose() {
        isInitialized = false
    }
}
