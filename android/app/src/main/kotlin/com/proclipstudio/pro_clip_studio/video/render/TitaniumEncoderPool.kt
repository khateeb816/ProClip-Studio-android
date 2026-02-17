package com.proclipstudio.pro_clip_studio.video.render

import java.util.concurrent.ConcurrentHashMap

/**
 * TITANIUM ENCODER POOL
 * 
 * Manages reusable TitaniumEncoder instances.
 * Segregates by resolution (Width x Height).
 */
object TitaniumEncoderPool {
    
    // Key: "WidthxHeight", Value: Queue of Encoders
    private val pool = ConcurrentHashMap<String, ArrayDeque<TitaniumEncoder>>()
    
    fun acquire(path: String, width: Int, height: Int): TitaniumEncoder {
        val key = "${width}x${height}"
        val queue = pool[key]
        
        synchronized(this) {
            if (queue != null && queue.isNotEmpty()) {
                val encoder = queue.removeFirst()
                try {
                    encoder.reset(path)
                    return encoder
                } catch (e: Exception) {
                    // Reset failed, just create new
                    encoder.release()
                }
            }
        }
        
        // Create new if none available or reset failed
        val newEncoder = TitaniumEncoder(path, width, height)
        newEncoder.init()
        return newEncoder
    }
    
    fun release(encoder: TitaniumEncoder, width: Int, height: Int) {
        // Don't fully release, just park it?
        // To park it, we must ensure it's in a state ready for reset().
        // For now, our reset() does re-init, so it's fine.
        val key = "${width}x${height}"
        
        synchronized(this) {
            var queue = pool[key]
            if (queue == null) {
                queue = ArrayDeque()
                pool[key] = queue
            }
            if (queue.size < 2) { // Max 2 pooled items per res to save memory
                queue.add(encoder)
            } else {
                encoder.release() // Overflow, kill it
            }
        }
    }
    
    fun clear() {
        synchronized(this) {
            for (queue in pool.values) {
                for (encoder in queue) {
                    encoder.release()
                }
                queue.clear()
            }
            pool.clear()
        }
    }
}
