package com.uunas.uudesk

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 无障碍服务与 Flutter 通道之间的桥。 */
object A11yBridge {
    @Volatile
    var service: UuAccessibilityService? = null

    @Volatile
    var sink: EventChannel.EventSink? = null

    fun reportState(enabled: Boolean) {
        sink?.success(mapOf("state" to if (enabled) "enabled" else "disabled"))
    }
}

/**
 * 被控输入注入（§3.2/§9）：
 * - touch/down/move/up → dispatchGesture（坐标归一化 0..1 → 像素）；
 * - text → ACTION_SET_TEXT 写入焦点输入框。
 * 骨架实现：down 记录起点、move 累积路径、up 一次性注入整段手势
 * （tap/滑动均可；长按/连续拖拽的实时注入留 TODO）。
 */
class UuAccessibilityService : AccessibilityService() {

    private val activePath = Path()
    private var holding = false

    override fun onServiceConnected() {
        super.onServiceConnected()
        A11yBridge.service = this
        A11yBridge.reportState(true)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        if (A11yBridge.service === this) A11yBridge.service = null
        A11yBridge.reportState(false)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        if (A11yBridge.service === this) A11yBridge.service = null
        A11yBridge.reportState(false)
        super.onDestroy()
    }

    /** 注入一条 §3.2 input 消息（Dart 经 MethodChannel 下发 JSON map）。 */
    fun inject(msg: Map<*, *>) {
        when (msg["k"] as? String) {
            "down" -> {
                val p = point(msg)
                activePath.reset()
                activePath.moveTo(p[0], p[1])
                holding = true
            }
            "move" -> if (holding) {
                val p = point(msg)
                activePath.lineTo(p[0], p[1])
            }
            "up" -> {
                val p = point(msg)
                if (holding) activePath.lineTo(p[0], p[1])
                holding = false
                dispatch(activePath, 120L)
            }
            "touch" -> {
                // 多点触控简化：按 action 复用单指路径
                when (msg["action"] as? String) {
                    "down" -> inject(mapOf("k" to "down", "x" to msg["x"], "y" to msg["y"]))
                    "move" -> inject(mapOf("k" to "move", "x" to msg["x"], "y" to msg["y"]))
                    "up" -> inject(mapOf("k" to "up", "x" to msg["x"], "y" to msg["y"]))
                }
            }
            "text" -> setText(msg["s"] as? String ?: "")
            "scroll" -> {
                // 以当前坐标为锚点做短距滑动模拟滚轮
                val p = point(msg)
                val dy = ((msg["dy"] as? Number)?.toFloat() ?: 0f) * 200f
                val path = Path().apply {
                    moveTo(p[0], p[1])
                    lineTo(p[0], p[1] + dy)
                }
                dispatch(path, 150L)
            }
            "key" -> {
                // TODO: 键盘 keycode 注入（无障碍无公开按键 API，
                //  可经 AccessibilityNodeInfo 动作或 rootInputConnection.setMetaText 扩展）。
            }
        }
    }

    private fun point(msg: Map<*, *>): FloatArray {
        val w = resources.displayMetrics.widthPixels.toFloat()
        val h = resources.displayMetrics.heightPixels.toFloat()
        val x = ((msg["x"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f) * w
        val y = ((msg["y"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f) * h
        return floatArrayOf(x, y)
    }

    private fun dispatch(path: Path, durationMs: Long) {
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0L, durationMs))
            .build()
        dispatchGesture(gesture, null, null)
    }

    private fun setText(text: String) {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }
}

/** MethodChannel `uudesk/accessibility`（下发注入指令）+ EventChannel（状态上报）。 */
class AccessibilityPlugin(messenger: BinaryMessenger) {

    private val method = MethodChannel(messenger, CHANNEL)
    private val event = EventChannel(messenger, CHANNEL)

    private val handler = object : MethodChannel.MethodCallHandler {
        override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
            when (call.method) {
                "inject" -> {
                    @Suppress("UNCHECKED_CAST")
                    val msg = call.arguments as? Map<*, *>
                    if (msg != null) {
                        A11yBridge.service?.inject(msg)
                        result.success(true)
                    } else {
                        result.error("inject", "invalid input message", null)
                    }
                }
                "status" -> result.success(A11yBridge.service != null)
                else -> result.notImplemented()
            }
        }
    }

    private val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            A11yBridge.sink = events
            A11yBridge.reportState(A11yBridge.service != null)
        }

        override fun onCancel(arguments: Any?) {
            A11yBridge.sink = null
        }
    }

    init {
        method.setMethodCallHandler(handler)
        event.setStreamHandler(streamHandler)
    }

    fun detach() {
        method.setMethodCallHandler(null)
        event.setStreamHandler(null)
        A11yBridge.sink = null
    }

    companion object {
        const val CHANNEL = "uudesk/accessibility"
    }
}
