package com.uunas.uudesk

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * 被控端上行帧总线：ScreenEncoder 输出的 Annex-B NAL 经 EventChannel
 * `uudesk/camera_frame` 上抛 Dart，Dart 侧加 §4 帧头后走 video 通道。
 */
object FrameBus {
    @Volatile
    var onNal: ((ByteArray) -> Unit)? = null

    fun emit(nal: ByteArray) {
        onNal?.invoke(nal)
    }
}

/** MediaCodec H.264 硬编（inputSurface 供 VirtualDisplay 喂帧）。 */
object ScreenEncoder {
    const val MIME = "video/avc"

    private var codec: MediaCodec? = null

    @get:Synchronized
    var inputSurface: Surface? = null
        private set

    @Synchronized
    fun start(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        stop()
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
        }
        val c = MediaCodec.createEncoderByType(MIME)
        c.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                // surface 输入模式不使用
            }

            override fun onOutputBufferAvailable(
                codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo,
            ) {
                try {
                    val buf = codec.getOutputBuffer(index) ?: return
                    val bytes = ByteArray(info.size)
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    buf.get(bytes)
                    FrameBus.emit(withStartCode(bytes))
                } finally {
                    codec.releaseOutputBuffer(index, false)
                }
            }

            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                // surface 编码的输出格式在 configure 时已确定，无需处理
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {}
        })
        c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = c.createInputSurface()
        c.start()
        codec = c
    }

    /** keyframe_req（§3.3）：请求下一个 IDR 帧（API 33+；旧设备靠周期 IDR 兜底）。 */
    @Synchronized
    fun requestKeyframe() {
        val c = codec ?: return
        try {
            val bundle = android.os.Bundle().apply {
                putInt("android.media.video.frame.sync", 1)
            }
            c.setParameters(bundle)
        } catch (_: Exception) {
            // 部分设备不支持，忽略
        }
    }

    @Synchronized
    fun stop() {
        codec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        codec = null
        inputSurface?.release()
        inputSurface = null
    }

    private fun withStartCode(nal: ByteArray): ByteArray {
        // MediaCodec 输出通常已是 Annex-B（含 SPS/PPS）；无起始码时补 00 00 00 01。
        val hasSc = nal.size >= 4 &&
            nal[0] == 0.toByte() && nal[1] == 0.toByte() &&
            ((nal[2] == 0.toByte() && nal[3] == 1.toByte()) || nal[2] == 1.toByte())
        return if (hasSc) nal else byteArrayOf(0, 0, 0, 1) + nal
    }
}

/** 注册 EventChannel `uudesk/camera_frame`，把编码 NAL 推给 Dart。 */
class H264EncoderPlugin(messenger: BinaryMessenger) : EventChannel.StreamHandler {

    private val event = EventChannel(messenger, CHANNEL).also { it.setStreamHandler(this) }
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        FrameBus.onNal = { nal -> sink?.success(nal) }
    }

    override fun onCancel(arguments: Any?) {
        FrameBus.onNal = null
        sink = null
    }

    fun start(width: Int, height: Int, fps: Int, bitrateKbps: Int) =
        ScreenEncoder.start(width, height, fps, bitrateKbps)

    fun stop() = ScreenEncoder.stop()

    fun detach() {
        FrameBus.onNal = null
        event.setStreamHandler(null)
    }

    companion object {
        const val CHANNEL = "uudesk/camera_frame"
    }
}
