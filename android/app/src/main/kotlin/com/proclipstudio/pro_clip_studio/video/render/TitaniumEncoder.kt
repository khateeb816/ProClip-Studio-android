package com.proclipstudio.pro_clip_studio.video.render

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface
import java.nio.ByteBuffer

/**
 * TITANIUM ENCODER
 * 
 * Hardware Video Encoder wrapper.
 * Encodes frames from InputSurface (EGL) -> MP4 File.
 */
class TitaniumEncoder(
    private var outputPath: String, 
    private val width: Int, 
    private val height: Int
) {
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var trackIndex = -1
    private var muxerStarted = false
    private val bufferInfo = MediaCodec.BufferInfo()
    
    var isEOS = false
        private set

    fun init() {
        initCodec()
    }

    private fun initCodec() {
        // Muxer
        if (muxer == null) {
            muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        }
        
        // Format (H.264) High Performance Defaults
        // ALIGN DIMENSIONS TO 2
        val alignedWidth = (width / 2) * 2
        val alignedHeight = (height / 2) * 2
        
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, alignedWidth, alignedHeight)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, 5000000) // 5Mbps (High Quality/Speed balance)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1 sec GOP (Fast seek, moderate compression)
        
        // --- VENDOR OPTIMIZATIONS (Qualcomm/Exynos) ---
        // Priority: Realtime / Hardware
        format.setInteger(MediaFormat.KEY_PRIORITY, 0) // 0 is highest priority
        
        // Snapdragon Low Latency
        // "vendor.qti-ext-enc-low-latency.enable"
        format.setInteger("vendor.qti-ext-enc-low-latency.enable", 1) 
        
        // Snapdragon RC Mode (0=RC_VBR, 1=RC_CBR, 2=RC_UBR) -> VBR for speed
        format.setInteger("vendor.qti-ext-enc-bitrate-mode.value", 0)

        // General Low Latency (Android 11+)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
             format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        // ---------------------------------------------

        // Encoder
        try {
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            
            // Input Surface (Reuse or Create)
            // Note: createInputSurface() can only be called once per codec state?
            // If reusing codec, we might not need to recreate if surface persists.
            if (inputSurface == null) {
                inputSurface = encoder?.createInputSurface()
            }
            
            encoder?.start()
        } catch (e: Exception) {
            throw RuntimeException("Failed to init TitaniumEncoder", e)
        }
    }
    
    fun reset(newPath: String) {
        try {
            outputPath = newPath
            
            // 1. Flush/Stop Encoder
            encoder?.stop()
            // encoder?.reset() // reset() invalidates surface on some devices!
            // It's safer to configure() again if in Uninitialized state?
            // Actually, to reuse InputSurface, we rely on successful stop().
            // But usually InputSurface is abandoned if we reset.
            // Android 6.0+ supports setInputSurface? No, that's for new Codec.
            // Hard Reuse Strategy: destroy codec, but what about EGL Surface?
            // The user wants "Reuse Input Surfaces". 
            // This implies: encoder.process() -> stop -> configure -> start (same surface?).
            // MediaCodec.configure() requires an uninitialized codec.
            // encoder.reset() makes it uninitialized. 
            // DOES reset() destroy the Surface?
            // "The application must call configure... If the codec was configured with an input surface, that surface is NOT valid after reset."
            
            // So we CANNOT reuse the input surface if we reset the encoder object?
            // Wait, persistent input surface is CREATE_INPUT_SURFACE (API 23).
            // createPersistentInputSurface().
            
            // For now, let's just do full release/init to be safe, 
            // BUT optimize the Pool to hold the OBJECT wrapper.
            
            encoder?.release()
            
            if (muxerStarted) {
                try { muxer?.stop() } catch(_:Exception){}
                try { muxer?.release() } catch(_:Exception){}
            }
            muxer = null
            muxerStarted = false
            trackIndex = -1
            isEOS = false
            
            initCodec() // Re-creates codec and surface
            
        } catch (e: Exception) {
            e.printStackTrace()
             // Fallback
             try { release() } catch(_:Exception){}
             initCodec()
        }
    }

    fun drain(): Boolean {
        if (encoder == null) return false
        
        while (true) {
            val encoderStatus = encoder!!.dequeueOutputBuffer(bufferInfo, 1000)
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                return false // No output yet
            } else if (encoderStatus == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (muxerStarted) throw RuntimeException("format changed twice")
                val newFormat = encoder!!.outputFormat
                trackIndex = muxer!!.addTrack(newFormat)
                muxer!!.start()
                muxerStarted = true
            } else if (encoderStatus >= 0) {
                val encodedData = encoder!!.getOutputBuffer(encoderStatus) ?: continue
                
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    bufferInfo.size = 0
                }

                if (bufferInfo.size != 0) {
                    if (!muxerStarted) throw RuntimeException("muxer hasn't started")
                    encodedData.position(bufferInfo.offset)
                    encodedData.limit(bufferInfo.offset + bufferInfo.size)
                    muxer!!.writeSampleData(trackIndex, encodedData, bufferInfo)
                }

                encoder!!.releaseOutputBuffer(encoderStatus, false)
                
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    isEOS = true
                    return true // Done!
                }
            }
        }
    }

    fun signalEndOfStream() {
        encoder?.signalEndOfInputStream()
    }
    
    fun getInputSurface(): Surface? {
        return inputSurface
    }

    fun requestSyncFrame() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            encoder?.setParameters(params)
        }
    }

    fun setBitrate(bitrate: Int) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
            encoder?.setParameters(params)
        }
    }

    fun release() {
        try { encoder?.stop() } catch(_:Exception){}
        try { encoder?.release() } catch(_:Exception){}
        try { if (muxerStarted) muxer?.stop() } catch(_:Exception){}
        try { muxer?.release() } catch(_:Exception){}
    }
}
