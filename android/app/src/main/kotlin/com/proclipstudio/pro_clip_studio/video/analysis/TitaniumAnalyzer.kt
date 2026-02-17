package com.proclipstudio.pro_clip_studio.video.analysis

import android.opengl.GLES20
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * TITANIUM ANALYZER
 * 
 * Performs real-time logic analysis on video frames.
 * Uses lightweight GPU readbacks to estimate motion and complexity.
 */
class TitaniumAnalyzer {

    // Metrics
    var motionScore: Float = 1.0f // 0.0 (Static) -> 1.0 (High Motion)
    var complexityScore: Float = 0.5f // 0.0 (Simple) -> 1.0 (Complex/High Detail)
    
    // Internal State
    private var previousPixels: ByteBuffer? = null
    private val sampleSize = 32 
    private var pixelBuffer: ByteBuffer
    
    // GPU State
    private var fboId = 0
    private var fboTexId = 0
    private var programId = 0
    private var maPositionHandle = 0
    private var maTextureHandle = 0
    private var initialized = false
    
    init {
        val size = sampleSize * sampleSize * 4 // RGBA
        pixelBuffer = ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder())
        previousPixels = ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder())
    }

    fun setup() {
        if (initialized) return
        setupFBO()
        setupShader()
        initialized = true
    }

    /**
     * Analyze the current frame.
     * @param textureId The OES texture ID of the current frame.
     * @return True if the frame should be processed (Encoded), False if it can be skipped.
     */
    fun analyze(textureId: Int): Boolean {
        if (!initialized) setup()
        
        // 1. Render to FBO (Downsample)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glViewport(0, 0, sampleSize, sampleSize)
        
        GLES20.glUseProgram(programId)
        
        // Bind OES Texture
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(android.opengl.GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        
        // Draw Quad (Full Screen)
        // ... (Simplified draw call) ...
        // We need vertices. Reusing a simple quad here would be best or passing it in.
        // For self-contained, let's assume we have a simple VBO or array.
        // For brevity in this snippet, I'll use raw arrays if needed, but optimally usage of TextureRenderer's buffers would be better.
        // Let's implement a minimal draw here.
        drawQuad()
        
        // 2. Read Pixels
        pixelBuffer.position(0)
        GLES20.glReadPixels(0, 0, sampleSize, sampleSize, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, pixelBuffer)
        
        // Restore FBO
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        
        // 3. Compare with Previous
        var diffSum = 0L
        pixelBuffer.position(0)
        previousPixels?.position(0)
        
        // Random sampling or full scan? 32x32=1024 pixels. Fast enough to scan all.
        // Each pixel is 4 bytes.
        // We compare Luminance roughly? Or just sum absolute diffs of R,G,B.
        
        val limit = sampleSize * sampleSize * 4
        
        if (previousPixels?.hasRemaining() == true) { // Check if we have history
             for (i in 0 until limit step 4) {
                 val r1 = pixelBuffer.get(i).toInt() and 0xFF
                 val g1 = pixelBuffer.get(i+1).toInt() and 0xFF
                 val b1 = pixelBuffer.get(i+2).toInt() and 0xFF
                 
                 val r2 = previousPixels!!.get(i).toInt() and 0xFF
                 val g2 = previousPixels!!.get(i+1).toInt() and 0xFF
                 val b2 = previousPixels!!.get(i+2).toInt() and 0xFF
                 
                 diffSum += Math.abs(r1 - r2) + Math.abs(g1 - g2) + Math.abs(b1 - b2)
             }
        }
        
        // Swap Buffers
        val temp = previousPixels
        previousPixels = pixelBuffer
        // New buffer for next frame? No, we need a fresh buffer for next read?
        // Actually glReadPixels writes TO buffer.
        // 'pixelBuffer' now holds current. 'previousPixels' holds old.
        // We just swapped them. So 'previousPixels' (which was current) is now strictly history.
        // 'pixelBuffer' (which was old history) is now garbage/scratch.
        // Correct.
        pixelBuffer = temp ?: ByteBuffer.allocateDirect(limit).order(ByteOrder.nativeOrder())
        
        // Normalize Score
        // Max Diff per pixel = 255*3 = 765
        // Max Total = 765 * 1024 = 783360
        motionScore = diffSum.toFloat() / (765f * 1024f)
        
        // Thresholds
        // Static: < 0.01 (1%)
        // Motion: > 0.05 (5%)
        // High Motion: > 0.2 (20%)
        
        // Complexity? (Edge density). 
        // We could run an edge detection shader pass instead of simple copy?
        // For now, Motion is key for skipping.
        
        return motionScore > 0.01f // Skip if < 1% change
    }
    
    private val vertices = floatArrayOf(
        -1f, -1f, 0f, 0f, 0f,
         1f, -1f, 0f, 1f, 0f,
        -1f,  1f, 0f, 0f, 1f,
         1f,  1f, 0f, 1f, 1f
    )
    private val vertexBuffer: java.nio.FloatBuffer = ByteBuffer.allocateDirect(vertices.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(vertices).apply { position(0) }

    private fun drawQuad() {
        GLES20.glVertexAttribPointer(maPositionHandle, 3, GLES20.GL_FLOAT, false, 5*4, vertexBuffer.position(0))
        GLES20.glEnableVertexAttribArray(maPositionHandle)
        GLES20.glVertexAttribPointer(maTextureHandle, 2, GLES20.GL_FLOAT, false, 5*4, vertexBuffer.position(3))
        GLES20.glEnableVertexAttribArray(maTextureHandle)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun setupFBO() {
        val framebuffers = IntArray(1)
        GLES20.glGenFramebuffers(1, framebuffers, 0)
        fboId = framebuffers[0]
        
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        fboTexId = textures[0]
        
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTexId)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, sampleSize, sampleSize, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fboId)
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, fboTexId, 0)
        
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }
    
    private fun setupShader() {
        val vertexShader = """
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = aTextureCoord.xy;
            }
        """
        val fragmentShader = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """
        // ... (Compile Logic) ...
        programId = createProgram(vertexShader, fragmentShader)
        maPositionHandle = GLES20.glGetAttribLocation(programId, "aPosition")
        maTextureHandle = GLES20.glGetAttribLocation(programId, "aTextureCoord")
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
         // Minimal compile helper
         val vs = loadShader(GLES20.GL_VERTEX_SHADER, vertexSource)
         val fs = loadShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
         val program = GLES20.glCreateProgram()
         GLES20.glAttachShader(program, vs)
         GLES20.glAttachShader(program, fs)
         GLES20.glLinkProgram(program)
         return program
    }
    
    private fun loadShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        return shader
    }
    
    /**
     * Updates scores based on external hints (e.g. timestamp delta).
     */
    fun updateHints(isSceneChange: Boolean) {
        if (isSceneChange) {
            motionScore = 1.0f
        }
    }
    
    fun release() {
        // cleanup FBOs
    }
}
