package com.proclipstudio.pro_clip_studio.video.render

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.view.Surface
import java.nio.ByteBuffer

/**
 * Hardware Video Encoder
 * Wraps MediaCodec to encode frames from a Surface.
 * Writes to MediaMuxer.
 */
class VideoEncoder(
    private val outputPath: String, 
    private val width: Int, 
    private val height: Int
) {
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var muxer: MediaMuxer? = null
    private var trackIndex = -1
    private var muxerStarted = false
    private val bufferInfo = MediaCodec.BufferInfo()

    fun init() {
        // Muxer
        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        
        // Format (H.264)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, 2500000) // 2.5Mbps (Titanium Spec)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

        // Encoder
        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        
        // Input Surface (OpenGL writes here)
        inputSurface = encoder?.createInputSurface()
        encoder?.start()
    }

    fun drain() {
        if (encoder == null) return
        
        while (true) {
            val encoderStatus = encoder!!.dequeueOutputBuffer(bufferInfo, 1000)
            if (encoderStatus == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break
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
                    break
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

    fun release() {
        encoder?.stop()
        encoder?.release()
        if (muxerStarted) {
            muxer?.stop()
        }
        muxer?.release()
    }
}
