package com.proclipstudio.pro_clip_studio.video.render

import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * TEXTURE RENDERER
 * 
 * The "GPU Transform Engine".
 * Renders an OES Texture (from MediaCodec) to a 2D Texture/Surface (Encoder)
 * applying Crop, Scale, and Rotation via Vertex Shader.
 */
class TextureRenderer {
    
    private var programId = 0
    private var uMVPMatrixHandle = 0
    private var uSTMatrixHandle = 0
    private var aPositionHandle = 0
    private var aTextureHandle = 0
    
    private val triangleVerticesData = floatArrayOf(
        // X, Y, Z, U, V
        -1.0f, -1.0f, 0f, 0f, 0f,
         1.0f, -1.0f, 0f, 1f, 0f,
        -1.0f,  1.0f, 0f, 0f, 1f,
         1.0f,  1.0f, 0f, 1f, 1f
    )
    
    private val triangleVertices: FloatBuffer

    private val mvpMatrix = FloatArray(16)
    private val stMatrix = FloatArray(16)

    init {
        triangleVertices = ByteBuffer.allocateDirect(triangleVerticesData.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        triangleVertices.put(triangleVerticesData).position(0)
        
        Matrix.setIdentityM(stMatrix, 0)
    }

    fun surfaceCreated() {
        val vertexShader = loadShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fragmentShader = loadShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        
        programId = GLES20.glCreateProgram()
        GLES20.glAttachShader(programId, vertexShader)
        GLES20.glAttachShader(programId, fragmentShader)
        GLES20.glLinkProgram(programId)
        
        uMVPMatrixHandle = GLES20.glGetUniformLocation(programId, "uMVPMatrix")
        uSTMatrixHandle = GLES20.glGetUniformLocation(programId, "uSTMatrix")
        aPositionHandle = GLES20.glGetAttribLocation(programId, "aPosition")
        aTextureHandle = GLES20.glGetAttribLocation(programId, "aTextureCoord")
    }

    fun drawFrame(textureId: Int, stMatrix: FloatArray? = null, mvpMatrix: FloatArray? = null) {
        GLES20.glUseProgram(programId)

        // Bind Texture
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)

        // Set Attribute: Position
        triangleVertices.position(0) // X, Y, Z
        GLES20.glVertexAttribPointer(aPositionHandle, 3, GLES20.GL_FLOAT, false, 5 * 4, triangleVertices)
        GLES20.glEnableVertexAttribArray(aPositionHandle)

        // Set Attribute: Texture Coord
        triangleVertices.position(3) // U, V
        GLES20.glVertexAttribPointer(aTextureHandle, 2, GLES20.GL_FLOAT, false, 5 * 4, triangleVertices)
        GLES20.glEnableVertexAttribArray(aTextureHandle)

        // Set Uniform: MVP Matrix
        if (mvpMatrix != null) {
            GLES20.glUniformMatrix4fv(uMVPMatrixHandle, 1, false, mvpMatrix, 0)
        } else {
            Matrix.setIdentityM(this.mvpMatrix, 0)
            GLES20.glUniformMatrix4fv(uMVPMatrixHandle, 1, false, this.mvpMatrix, 0)
        }

        // Set Uniform: ST Matrix (Texture Transform)
        if (stMatrix != null) {
            GLES20.glUniformMatrix4fv(uSTMatrixHandle, 1, false, stMatrix, 0)
        } else {
             GLES20.glUniformMatrix4fv(uSTMatrixHandle, 1, false, this.stMatrix, 0)
        }

        // DRAW
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        
        GLES20.glDisableVertexAttribArray(aPositionHandle)
        GLES20.glDisableVertexAttribArray(aTextureHandle)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
    }

    private fun loadShader(shaderType: Int, source: String): Int {
        var shader = GLES20.glCreateShader(shaderType)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        return shader
    }

    companion object {
        private const val VERTEX_SHADER = """
            uniform mat4 uMVPMatrix;
            uniform mat4 uSTMatrix;
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
              gl_Position = uMVPMatrix * aPosition;
              vTextureCoord = (uSTMatrix * aTextureCoord).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES sTexture;
            void main() {
              gl_FragColor = texture2D(sTexture, vTextureCoord);
            }
        """
    }
}
