package com.proclipstudio.pro_clip_studio.video.render

import android.graphics.SurfaceTexture
import android.opengl.GLES20
import android.util.Log

/**
 * EXECUTION ENGINE (The Brain)
 * Orchestrates the Zero-Copy Data Flow.
 * 
 * Thread Safety:
 * - All critical properties (decoder, encoder, renderer) are accessed via local immutable shadows.
 * - SurfaceTexture synchronization is handled via frameSyncObject.
 */
class RenderGraph(
    private val ctxManager: TitaniumGLContextManager,
    private val width: Int, 
    private val height: Int
) : SurfaceTexture.OnFrameAvailableListener {

    // Nullable mutable properties (Main State)
    private var decoder: TitaniumDecoder? = null
    private var encoder: TitaniumEncoder? = null
    
    // Renderer guaranteed by lifecycle or throws
    // Renderer guaranteed by lifecycle or throws
    private lateinit var renderer: TextureRenderer
    
    // Perceptual Analyzer
    private val analyzer = com.proclipstudio.pro_clip_studio.video.analysis.TitaniumAnalyzer()
    
    // Surface State
    private var surfaceTexture: SurfaceTexture? = null
    private var textureId = 0
    private var encoderEglSurface: android.opengl.EGLSurface? = null
    
    // Synchronization
    private val frameSyncObject = Object()
    private var frameAvailable = false

    private var ownsDecoder = true

    private var cropX = 0f
    private var cropY = 0f
    private var cropW = 1f
    private var cropH = 1f

    fun setup(source: String, dest: String, cropX: Float, cropY: Float, cropW: Float, cropH: Float, existingDecoder: TitaniumDecoder? = null) {
        this.cropX = cropX
        this.cropY = cropY
        this.cropW = cropW
        this.cropH = cropH
        
        // 1. Encoder (Sink) - FROM POOL
        encoder = TitaniumEncoderPool.acquire(dest, width, height)
        // encoder init called inside acquire
        
        // 2. Bind Encoder Surface to EGL
        val inputSurface = encoder!!.getInputSurface() 
            ?: throw RuntimeException("Encoder input surface is null")
            
        encoderEglSurface = ctxManager.createWindowSurface(inputSurface)
        ctxManager.makeCurrent(encoderEglSurface!!, encoderEglSurface!!)
        
        // 3. Renderer (Shader Node)
        if (!::renderer.isInitialized) {
            renderer = TextureRenderer()
            renderer.surfaceCreated()
        }
        
        // 4. Decoder (Source)
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        
        // OES Texture -> SurfaceTexture
        val newSurfaceTexture = SurfaceTexture(textureId)
        newSurfaceTexture.setOnFrameAvailableListener(this)
        surfaceTexture = newSurfaceTexture
        
        val decoderSurface = android.view.Surface(newSurfaceTexture)
        
        if (existingDecoder != null) {
            // REUSE EXISTING CACHED DECODER
            // We must update its surface?! 
            // MediaCodec cannot easily change output surface on the fly without configuration?
            // "setOutputSurface" exists in API 23+.
            // If using shared decoder, we must ensure it outputs to OUR surface.
            
            // Check API Level
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                try {
                     // We need access to the inner MediaCodec to call setOutputSurface
                     // But TitaniumDecoder encapsulates it.
                     // We need to add setOutputSurface to TitaniumDecoder.
                     existingDecoder.updateOutputSurface(decoderSurface)
                     decoder = existingDecoder
                     ownsDecoder = false
                } catch (e: Exception) {
                     Log.e("Titanium", "Failed to reuse decoder surface: ${e.message}")
                     // Fallback to new decoder
                     val newDecoder = TitaniumDecoder(source, decoderSurface)
                     newDecoder.init()
                     decoder = newDecoder
                     ownsDecoder = true
                }
            } else {
                 // Fallback for old API
                 val newDecoder = TitaniumDecoder(source, decoderSurface)
                 newDecoder.init()
                 decoder = newDecoder
                 ownsDecoder = true
            }
        } else {
            val newDecoder = TitaniumDecoder(source, decoderSurface)
            newDecoder.init()
            decoder = newDecoder
            ownsDecoder = true
        }
    }
    
    override fun onFrameAvailable(surfaceTexture: SurfaceTexture?) {
        synchronized(frameSyncObject) {
            frameAvailable = true
            frameSyncObject.notifyAll()
        }
    }

    fun execute(onProgress: (Float) -> Unit) {
        var running = true
        var outputDone = false
        var signaledEOS = false
        
        val localDecoder = decoder ?: throw RuntimeException("Decoder not initialized")
        val localEncoder = encoder ?: throw RuntimeException("Encoder not initialized")
        
        // Progress Tracking
        val durationUs = localDecoder.durationUs
        var lastProgressTime = 0L
        
        // PARALLEL PIPELINE:
        // Thread 1 (Main/Current): Decodes frames loops.
        // Thread 2 (Virtual): Encoder runs asynchronously on HW.
        // We just need to ensure we don't block Decoder while waiting for Encoder, 
        // BUT we are using Surface-to-Surface.
        // Surface mode automatically handles some queuing.
        
        // Optimization: Run Decoder loop aggressively.
        // The bottleneck is onFrameAvailable wait.
        
        // FAST MODE LOOP
        while (running) {
            var workDone = false
            
            // A. Drain Encoder (Non-blocking check)
            if (localEncoder.drain()) {
                outputDone = true
                running = false
                workDone = true
            }
            
            // B. Decoder -> Render Pipeline
            if (!outputDone) {
                // Try to process MULTIPLE frames if available?
                // No, OES texture is single buffered for GL.
                
                val renderedToSurface = localDecoder.process()
                
                if (renderedToSurface) {
                     // Wait for OES (Blocking but optimized)
                     // If we are stuck waiting for OES, it means GL Consumer hasn't released previous?
                     // Or Decoder hasn't produced? 
                     // renderedToSurface=true means Decoder output a buffer.
                     // onFrameAvailable should fire immediately.
                     
                    synchronized(frameSyncObject) {
                        var waitCount = 0
                        while (!frameAvailable) {
                            try {
                                frameSyncObject.wait(10) // Ultra fast check
                                waitCount++
                                if (waitCount > 100) { // 1 sec timeout
                                    Log.e("Titanium", "Frame Wait Timeout")
                                    break 
                                }
                            } catch (e: InterruptedException) { break }
                        }
                        frameAvailable = false
                    }
                    
                    try {
                        surfaceTexture?.updateTexImage()
                        
                        // C. Shader Draw (Zero Copy)
                        // 1. Get OES Transform (Handles rotation/orientation)
                        val oesMatrix = FloatArray(16)
                        surfaceTexture?.getTransformMatrix(oesMatrix)
                        
                        // ANALYZER STEP
                        // Run real analysis
                        val isInteresting = analyzer.analyze(textureId)
                        val score = analyzer.motionScore
                        
                        if (isInteresting) {
                            // ADAPTIVE BITRATE
                            // Proportional to motion
                            val baseBitrate = 5000000 // 5 Mbps
                            val targetBitrate = when {
                                score < 0.05f -> 2000000 // Low motion -> 2Mbps
                                score > 0.3f -> 8000000  // High motion -> 8Mbps
                                else -> baseBitrate
                            }
                            // Only update if significantly different to avoid spamming
                            // (Implementation detail for TitaniumEncoder to handle caching)
                            localEncoder.setBitrate(targetBitrate)
                            
                            // SMART GOP / SCENE CUT
                            if (score > 0.5f) {
                                localEncoder.requestSyncFrame()
                            }
                        
                            // 2. Compute Crop Matrix (Texture Coords)
                            // ... (Matrix Logic preserved) ...
                            val cropMatrix = FloatArray(16)
                            android.opengl.Matrix.setIdentityM(cropMatrix, 0)
                            
                            android.opengl.Matrix.translateM(cropMatrix, 0, cropX, cropY, 0f)
                            android.opengl.Matrix.scaleM(cropMatrix, 0, cropW, cropH, 1f)
                            
                            val finalSTMatrix = FloatArray(16)
                            android.opengl.Matrix.multiplyMM(finalSTMatrix, 0, oesMatrix, 0, cropMatrix, 0)
                            
                            val finalMVPMatrix = FloatArray(16)
                            android.opengl.Matrix.setIdentityM(finalMVPMatrix, 0)
                            
                            renderer.drawFrame(textureId, finalSTMatrix, finalMVPMatrix) 
                            
                            // D. Swap (Submit to Encoder)
                            ctxManager.swapBuffers(encoderEglSurface!!)
                            workDone = true
                        } else {
                            // FRAME SKIPPED (VFR)
                            // We do nothing. The encoder will just receive the NEXT frame later.
                            workDone = true
                        }
                        
                        // Progress
                        val currentTime = System.currentTimeMillis()
                        if (durationUs > 0 && (currentTime - lastProgressTime > 100)) {
                            val currentUs = localDecoder.lastPresentationTimeUs
                            val progress = (currentUs.toDouble() / durationUs.toDouble()).toFloat().coerceIn(0f, 1f)
                            onProgress(progress)
                            lastProgressTime = currentTime
                        }
                        
                    } catch (e: Exception) {
                        Log.e("Titanium", "Render Exception: ${e.message}")
                    }
                } else {
                    if (localDecoder.isOutputDone) {
                        if (!signaledEOS) {
                             localEncoder.signalEndOfStream()
                             signaledEOS = true
                             workDone = true
                        }
                    }
                }
            }
            
            if (!workDone) {
                 // Yield to allow other threads (like EventSink) to breathe, 
                 // but keep it tight for speed.
                 Thread.yield() 
            }
        }
        
        onProgress(1.0f)
    }
    
    fun release() {
        if (ownsDecoder) {
            decoder?.release()
        }
        
        // Return Encoder to Pool instead of destroying
        if (encoder != null) {
            TitaniumEncoderPool.release(encoder!!, width, height)
            encoder = null
        }
        
        surfaceTexture?.release()
        analyzer.release()
    }
}
