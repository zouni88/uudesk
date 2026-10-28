package com.uunas.uudesk

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.ComponentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel `uudesk/projection`：被控端屏幕采集启停（§3.5 cap_start/cap_stop）。
 * start 拉起透明 Activity 请求 MediaProjection 授权，授权成功后由
 * [ScreenCaptureService] 前台服务建 VirtualDisplay 喂 [ScreenEncoder]，
 * 编码帧经 EventChannel `uudesk/camera_frame` 上抛。
 */
class ProjectionPlugin(
    messenger: BinaryMessenger,
    private val context: Context,
    private val encoder: H264EncoderPlugin,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                // 用 Activity context 启动授权页：授权页进入当前任务栈，
                // 返回时复用同一个 MainActivity/Flutter 引擎，不会重建应用。
                // 仅当传入的是 Application context 时才需要 NEW_TASK。
                val intent = Intent(context, ProjectionRequestActivity::class.java)
                if (context !is Activity) {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                // 授权是异步的：这里先回 true 表示已发起；
                // 用户拒绝时服务不启动，Dart 侧收不到帧自行提示（对应 3001）。
                result.success(true)
            }
            "stop" -> {
                val intent = Intent(context, ScreenCaptureService::class.java)
                    .setAction(ScreenCaptureService.ACTION_STOP)
                context.startService(intent)
                encoder.stop()
                result.success(true)
            }
            // 会议屏幕共享保活（配合 flutter_webrtc 的 getDisplayMedia）。
            "shareStart" -> {
                MeetingShareService.start(context)
                result.success(true)
            }
            "shareStop" -> {
                MeetingShareService.stop(context)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    fun detach() = channel.setMethodCallHandler(null)

    companion object {
        const val CHANNEL = "uudesk/projection"
    }
}

/** 透明授权页：请求系统 MediaProjection 投屏授权。 */
class ProjectionRequestActivity : ComponentActivity() {

    private val launcher =
        registerForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult(),
        ) { res ->
            if (res.resultCode == RESULT_OK && res.data != null) {
                ScreenCaptureService.start(this, res.resultCode, res.data!!)
            }
            finish()
        }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as android.media.projection.MediaProjectionManager
        launcher.launch(mgr.createScreenCaptureIntent())
    }
}
