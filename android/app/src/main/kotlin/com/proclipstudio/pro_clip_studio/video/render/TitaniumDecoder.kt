package com.proclipstudio.pro_clip_studio.video.render

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.view.Surface
import java.io.IOException

/**
 * TITANIUM DECODER
 * 
 * Hardware Video Decoder wrapper.
 * Feeds frames from Movie File -> Surface (SurfaceTexture).
 */
class TitaniumDecoder(private val sourcePath: String, private val outputSurface: Surface) {
    
    private var extractor: MediaExtractor? = null
    private var decoder: MediaCodec? = null
    var isOutputDone = false
        private set
    private var inputDone = false
    
    var durationUs: Long = 0
        private set
    var lastPresentationTimeUs: Long = 0
        private set

    fun init() {
        extractor = MediaExtractor()
        try {
            extractor?.setDataSource(sourcePath)
        } catch (e: IOException) {
            throw RuntimeException("Failed to set data source: $sourcePath", e)
        }
        
        // Select Video Track
        var format: MediaFormat? = null
        var mime = ""
        
        for (i in 0 until (extractor?.trackCount ?: 0)) {
            val trackFormat = extractor?.getTrackFormat(i)
            val trackMime = trackFormat?.getString(MediaFormat.KEY_MIME) ?: ""
            if (trackMime.startsWith("video/")) {
                extractor?.selectTrack(i)
                format = trackFormat
                mime = trackMime
                
                // Get Duration
                durationUs = if (trackFormat != null && trackFormat.containsKey(MediaFormat.KEY_DURATION)) {
                    trackFormat.getLong(MediaFormat.KEY_DURATION)
                } else {
                     0L
                }
                
                break
            }
        }
        
        if (format == null) throw IOException("No video track found in $sourcePath")
        
        try {
            decoder = MediaCodec.createDecoderByType(mime)
            decoder?.configure(format, outputSurface, null, 0)
            decoder?.start()
        } catch (e: Exception) {
            throw RuntimeException("Failed to create/start decoder for mime: $mime", e)
        }
    }
    
    /**
     * Drives the decoder loop.
     * Returns true if a frame was rendered to the Surface.
     */
    fun process(): Boolean {
        if (isOutputDone) return false
        val localDecoder = decoder ?: return false
        val localExtractor = extractor ?: return false
        
        // 1. Feed Input
        if (!inputDone) {
            val inputIndex = localDecoder.dequeueInputBuffer(0) // Non-blocking
            if (inputIndex >= 0) {
                val inputBuffer = localDecoder.getInputBuffer(inputIndex)
                if (inputBuffer != null) {
                    val sampleSize = localExtractor.readSampleData(inputBuffer, 0)
                    
                    if (sampleSize < 0) {
                        localDecoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        val presentationTimeUs = localExtractor.sampleTime
                        localDecoder.queueInputBuffer(inputIndex, 0, sampleSize, presentationTimeUs, 0)
                        localExtractor.advance()
                    }
                }
            }
        }
        
        // 2. Drain Output
        val bufferInfo = MediaCodec.BufferInfo()
        val outputIndex = localDecoder.dequeueOutputBuffer(bufferInfo, 0) // Non-blocking
        
        if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
            return false 
        } else if (outputIndex >= 0) {
            if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                isOutputDone = true
            }
            
            // Capture Timestamp
            if (bufferInfo.size > 0) {
                lastPresentationTimeUs = bufferInfo.presentationTimeUs
            }
            
            // Render to Surface if we have data and it's not just EOS config
            val doRender = bufferInfo.size != 0 && !isOutputDone
            
            localDecoder.releaseOutputBuffer(outputIndex, doRender)
            return doRender
        }
        
        return false
    }

    fun seekTo(timeUs: Long) {
        extractor?.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        inputDone = false
        isOutputDone = false
        decoder?.flush()
    }

    fun updateOutputSurface(newSurface: Surface) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            decoder?.setOutputSurface(newSurface)
        }
    }

    fun release() {
        try { decoder?.stop() } catch(_:Exception){}
        try { decoder?.release() } catch(_:Exception){}
        try { extractor?.release() } catch(_:Exception){}
        decoder = null
        extractor = null
    }
}
