package com.example.morsl

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val cutoutExecutor = Executors.newSingleThreadExecutor()
    override fun onDestroy() {
        cutoutExecutor.shutdown()
        super.onDestroy()
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val cutouts = DishCutouts(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "morsl/plates")
            .setMethodCallHandler { call, reply ->
                if (call.method !in setOf("available", "prepare", "subjects")) {
                    reply.notImplemented()
                    return@setMethodCallHandler
                }
                cutoutExecutor.execute {
                    try {
                        val value: Any = when (call.method) {
                            "available" -> cutouts.available()
                            "prepare" -> cutouts.prepare()
                            else -> cutouts.subjects(requireNotNull(call.argument<String>("path")))
                        }
                        runOnUiThread { reply.success(value) }
                    } catch (error: Exception) {
                        runOnUiThread { reply.error("cutouts", error.message, null) }
                    }
                }
            }
    }
}
