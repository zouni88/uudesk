package com.uunas.uudesk

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * MethodChannel `uudesk/video_decoder`（控制端画面）：
 * Dart 送入 §4 解出的 Annex-B NAL → MediaCodec 硬解到 SurfaceTexture，
 * configure 返回 textureId 供 Flutter `Texture` 组件渲染。
 */
class VideoDecoderPlugin(
    messenger: BinaryMessenger,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }

    private var codec: MediaCodec? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private val info = MediaCodec.BufferInfo()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> {
                    val w = call.argument<Int>("width") ?: 0
                    val h = call.argument<Int>("height") ?: 0
                    result.success(configure(w, h))
                }
                "decode" -> {
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    decode(data, call.argument<Boolean>("keyframe") ?: false)
                    result.success(null)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("video_decoder", e.message, null)
        }
    }

    private fun configure(width: Int, height: Int): Long {
        release()
        val texture = textures.createSurfaceTexture()
        texture.surfaceTexture().setDefaultBufferSize(width, height)
        entry = texture
        val outSurface = Surface(texture.surfaceTexture())
        surface = outSurface
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(MediaFormat.KEY_MAX_WIDTH, width)
            setInteger(MediaFormat.KEY_MAX_HEIGHT, height)
        }
        val c = MediaCodec.createDecoderByType(MIME)
        c.configure(format, outSurface, null, 0)
        c.start()
        codec = c
        return texture.id()
    }

    private fun decode(nal: ByteArray, keyframe: Boolean) {
        val c = codec ?: return
        val inIdx = c.dequeueInputBuffer(0)
        if (inIdx >= 0) {
            val buf = c.getInputBuffer(inIdx) ?: return
            buf.clear()
            buf.put(nal)
            c.queueInputBuffer(
                inIdx, 0, nal.size, System.nanoTime() / 1000,
                if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
            )
        }
        // Surface 输出：releaseOutputBuffer(render=true) 即上屏。
        while (true) {
            val outIdx = c.dequeueOutputBuffer(info, 0)
            if (outIdx < 0) break
            c.releaseOutputBuffer(outIdx, info.size > 0)
        }
    }

    private fun release() {
        codec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
        surface?.release()
        surface = null
        entry?.release()
        entry = null
    }

    fun detach() {
        release()
        channel.setMethodCallHandler(null)
    }

    companion object {
        const val CHANNEL = "uudesk/video_decoder"
        const val MIME = "video/avc"
    }
}
