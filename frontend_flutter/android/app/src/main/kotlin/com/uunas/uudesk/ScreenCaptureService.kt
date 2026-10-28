package com.uunas.uudesk

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.IBinder
import android.util.DisplayMetrics

/**
 * MediaProjection 前台服务（foregroundServiceType=mediaProjection）：
 * 持有授权结果，启动 [ScreenEncoder] 并把 VirtualDisplay 输出接到编码器
 * inputSurface；帧经 FrameBus → EventChannel `uudesk/camera_frame` 上抛。
 */
class ScreenCaptureService : Service() {

    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "UUDesk 屏幕采集", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification())
        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_RESULT_DATA)
        if (data == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = mgr.getMediaProjection(resultCode, data) ?: run {
            stopSelf()
            return START_NOT_STICKY
        }
        projection = mp

        val dm: DisplayMetrics = resources.displayMetrics
        val w = dm.widthPixels and 0xFFFE // 编码器要求偶数尺寸
        val h = dm.heightPixels and 0xFFFE
        ScreenEncoder.start(w, h, DEFAULT_FPS, DEFAULT_BITRATE_KBPS)
        val surface = ScreenEncoder.inputSurface
        if (surface == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        virtualDisplay = mp.createVirtualDisplay(
            "uu_desk", w, h, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface, null, null,
        )
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        virtualDisplay?.release()
        virtualDisplay = null
        projection?.stop()
        projection = null
        ScreenEncoder.stop()
        super.onDestroy()
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("UUDesk 正在共享屏幕")
            .setContentText("PC 端远程查看中")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .build()

    companion object {
        const val ACTION_STOP = "com.uunas.uudesk.action.STOP_CAPTURE"
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        private const val CHANNEL_ID = "uu_desk_capture"
        private const val NOTIF_ID = 1001
        private const val DEFAULT_FPS = 30
        private const val DEFAULT_BITRATE_KBPS = 6000

        fun start(context: Context, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenCaptureService::class.java)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
            context.startForegroundService(intent)
        }
    }
}

/**
 * 会议屏幕共享保活前台服务（foregroundServiceType=mediaProjection）。
 *
 * flutter_webrtc 自身不启动前台服务：
 * - Android 14+ 调用 MediaProjectionManager.getMediaProjection 前，应用必须已有
 *   mediaProjection 类型的前台服务，否则共享直接失败；
 * - 共享期间保持前台服务可显著降低进程被系统回收的概率，避免切回应用时
 *   Activity/Flutter 引擎重建（表现为“回到会议就重启”）。
 */
class MeetingShareService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(SHARE_CHANNEL_ID, "UUDesk 会议共享", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_SHARE) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(SHARE_NOTIF_ID, buildNotification())
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, SHARE_CHANNEL_ID)
            .setContentTitle("UUDesk 正在共享屏幕")
            .setContentText("会议屏幕共享进行中")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .build()

    companion object {
        const val ACTION_STOP_SHARE = "com.uunas.uudesk.action.STOP_SHARE_KEEPALIVE"
        private const val SHARE_CHANNEL_ID = "uu_desk_share"
        private const val SHARE_NOTIF_ID = 1002

        fun start(context: Context) {
            context.startForegroundService(Intent(context, MeetingShareService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MeetingShareService::class.java))
        }
    }
}
