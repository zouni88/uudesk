package com.uunas.uudesk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var decoder: VideoDecoderPlugin? = null
    private var encoder: H264EncoderPlugin? = null
    private var projection: ProjectionPlugin? = null
    private var accessibility: AccessibilityPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        decoder = VideoDecoderPlugin(messenger, flutterEngine.renderer)
        encoder = H264EncoderPlugin(messenger)
        projection = ProjectionPlugin(messenger, this, encoder!!)
        accessibility = AccessibilityPlugin(messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        decoder?.detach()
        encoder?.detach()
        projection?.detach()
        accessibility?.detach()
        decoder = null
        encoder = null
        projection = null
        accessibility = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
