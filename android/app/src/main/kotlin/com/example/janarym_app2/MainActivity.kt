package com.example.janarym_app2

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      RUNTIME_CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "start" -> {
          result.success(false)
        }
        "stop" -> {
          result.success(false)
        }
        "isRunning" -> result.success(false)
        else -> result.notImplemented()
      }
    }

    val wakeEngine = getWakeEngine()
    val reflexDetector = getReflexDetector()

    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      WAKE_CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "initialize" -> {
          try {
            val arguments = call.arguments as? Map<String, Any?> ?: emptyMap()
            wakeEngine.initialize(NativeWakeWordConfig.fromArgs(arguments))
            result.success(true)
          } catch (error: Exception) {
            result.error("wake_init_failed", error.message, null)
          }
        }
        "start" -> {
          try {
            wakeEngine.start()
            result.success(true)
          } catch (error: Exception) {
            result.error("wake_start_failed", error.message, null)
          }
        }
        "stop" -> {
          try {
            wakeEngine.stop()
            result.success(true)
          } catch (error: Exception) {
            result.error("wake_stop_failed", error.message, null)
          }
        }
        "dispose" -> {
          wakeEngine.dispose()
          result.success(true)
        }
        "hasOwnerProfile" -> result.success(wakeEngine.hasOwnerProfile())
        "clearOwnerProfile" -> {
          wakeEngine.clearOwnerProfile()
          result.success(true)
        }
        "startEnrollment" -> {
          val targetSamples = (call.argument<Number>("sampleCount")?.toInt() ?: 8)
          wakeEngine.startEnrollment(targetSamples)
          result.success(true)
        }
        "cancelEnrollment" -> {
          wakeEngine.cancelEnrollment()
          result.success(true)
        }
        "status" -> result.success(wakeEngine.currentStatus())
        else -> result.notImplemented()
      }
    }

    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      REFLEX_CHANNEL,
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "initialize" -> {
          try {
            val scoreThreshold = (call.argument<Number>("scoreThreshold")?.toFloat() ?: 0.22f)
            val maxResults = (call.argument<Number>("maxResults")?.toInt() ?: 8)
            reflexDetector.initialize(
              scoreThreshold = scoreThreshold,
              maxResults = maxResults,
            )
            result.success(true)
          } catch (error: Exception) {
            result.error("reflex_init_failed", error.message, null)
          }
        }
        "detect" -> {
          val nv21Bytes = call.argument<ByteArray>("nv21Bytes")
          val width = call.argument<Number>("width")?.toInt() ?: 0
          val height = call.argument<Number>("height")?.toInt() ?: 0
          if (nv21Bytes == null || nv21Bytes.isEmpty() || width <= 0 || height <= 0) {
            result.success(emptyList<Map<String, Any?>>())
            return@setMethodCallHandler
          }
          getReflexExecutor().execute {
            try {
              val detections = reflexDetector.detect(nv21Bytes, width, height)
              runOnUiThread { result.success(detections) }
            } catch (error: Exception) {
              runOnUiThread {
                result.error("reflex_detect_failed", error.message, null)
              }
            }
          }
        }
        "dispose" -> {
          reflexDetector.dispose()
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }

    EventChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      WAKE_EVENTS_CHANNEL,
    ).setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(
          arguments: Any?,
          events: EventChannel.EventSink?,
        ) {
          wakeEngine.setEventListener(
            object : NativeWakeWordEventListener {
              override fun onEvent(event: Map<String, Any?>) {
                events?.success(event)
              }
            },
          )
        }

        override fun onCancel(arguments: Any?) {
          wakeEngine.setEventListener(null)
        }
      },
    )
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    wakeEngine?.setEventListener(null)
    super.cleanUpFlutterEngine(flutterEngine)
  }

  override fun onDestroy() {
    if (isFinishing) {
      wakeEngine?.setEventListener(null)
      wakeEngine?.dispose()
      wakeEngine = null
      reflexDetector?.dispose()
      reflexDetector = null
      reflexExecutor?.shutdownNow()
      reflexExecutor = null
    }
    super.onDestroy()
  }

  companion object {
    private const val RUNTIME_CHANNEL = "janarym/runtime_service"
    private const val WAKE_CHANNEL = "janarym/wake_word"
    private const val WAKE_EVENTS_CHANNEL = "janarym/wake_word/events"
    private const val REFLEX_CHANNEL = "janarym/reflex_detector"
    @Volatile private var wakeEngine: NativeWakeWordEngine? = null
    @Volatile private var reflexDetector: ReflexNativeDetector? = null
    @Volatile private var reflexExecutor: ExecutorService? = null
  }

  private fun getWakeEngine(): NativeWakeWordEngine {
    val existing = wakeEngine
    if (existing != null) return existing
    return synchronized(MainActivity::class.java) {
      wakeEngine ?: NativeWakeWordEngine(applicationContext).also {
        wakeEngine = it
      }
    }
  }

  private fun getReflexDetector(): ReflexNativeDetector {
    val existing = reflexDetector
    if (existing != null) return existing
    return synchronized(MainActivity::class.java) {
      reflexDetector ?: ReflexNativeDetector(applicationContext).also {
        reflexDetector = it
      }
    }
  }

  private fun getReflexExecutor(): ExecutorService {
    val existing = reflexExecutor
    if (existing != null) return existing
    return synchronized(MainActivity::class.java) {
      reflexExecutor ?: Executors.newSingleThreadExecutor().also {
        reflexExecutor = it
      }
    }
  }
}
