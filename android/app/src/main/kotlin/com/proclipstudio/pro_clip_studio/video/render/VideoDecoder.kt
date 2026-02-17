package com.proclipstudio.pro_clip_studio.video.render

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.view.Surface
import java.io.IOException
import java.nio.ByteBuffer

/**
 * Hardware Video Decoder
 * Wraps MediaCodec in Asynchronous or Synchronous mode.
 * Feeds frames to the Graph's SourceNode.
 */
class VideoDecoder(private val sourcePath: String, private val outputSurface: Surface) {
    
    private var extractor: MediaExtractor? = null
    private var decoder: MediaCodec? = null
    private var videoTrackIndex = -1
    private var inputDone = false
    private var outputDone = false
    
    fun init() {
        extractor = MediaExtractor()
        extractor?.setDataSource(sourcePath)
        
        // Select Video Track
        for (i in 0 until (extractor?.trackCount ?: 0)) {
            val format = extractor?.getTrackFormat(i)
            val mime = format?.getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("video/")) {
                videoTrackIndex = i
                extractor?.selectTrack(i)
                decoder = MediaCodec.createDecoderByType(mime)
                decoder?.configure(format, outputSurface, null, 0)
                break
            }
        }
        
        if (decoder == null) throw IOException("No video track found")
        decoder?.start()
    }
    
    /**
     * Drives the decoder loop.
     * Returns true if a frame was rendered.
     */
    fun process(): Boolean {
        if (outputDone) return false
        
        // 1. Feed Input
        if (!inputDone) {
            val inputIndex = decoder?.dequeueInputBuffer(1000) ?: -1
            if (inputIndex >= 0) {
                val inputBuffer = decoder?.getInputBuffer(inputIndex)
                val sampleSize = extractor?.readSampleData(inputBuffer!!, 0) ?: -1
                
                if (sampleSize < 0) {
                    decoder?.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    inputDone = true
                } else {
                    val presentationTimeUs = extractor?.sampleTime ?: 0
                    decoder?.queueInputBuffer(inputIndex, 0, sampleSize, presentationTimeUs, 0)
                    extractor?.advance()
                }
            }
        }
        
        // 2. Drain Output
        val bufferInfo = MediaCodec.BufferInfo()
        val outputIndex = decoder?.dequeueOutputBuffer(bufferInfo, 1000) ?: -1
        
        if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
            return false // No frame available yet
        } else if (outputIndex >= 0) {
            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                outputDone = true
                return false
            }
            
            val doRender = bufferInfo.size != 0
            // Release output buffer and render to Surface
            decoder?.releaseOutputBuffer(outputIndex, doRender)
            return doRender
        }
        
        return false
    }

    fun release() {
        decoder?.stop()
        decoder?.release()
        extractor?.release()
    }
}
