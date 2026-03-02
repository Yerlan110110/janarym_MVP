package com.example.janarym_app2

import android.content.Context
import android.graphics.Bitmap
import org.tensorflow.lite.support.image.TensorImage
import org.tensorflow.lite.task.core.BaseOptions
import org.tensorflow.lite.task.vision.detector.ObjectDetector

class ReflexNativeDetector(private val context: Context) {
  @Volatile private var detector: ObjectDetector? = null
  @Volatile private var reusableBitmap: Bitmap? = null
  @Volatile private var argbBuffer: IntArray? = null

  fun initialize(
    modelAssetPath: String = DEFAULT_MODEL_ASSET,
    scoreThreshold: Float = DEFAULT_SCORE_THRESHOLD,
    maxResults: Int = DEFAULT_MAX_RESULTS,
    numThreads: Int = DEFAULT_NUM_THREADS,
  ) {
    if (detector != null) return

    val baseOptions = BaseOptions.builder().setNumThreads(numThreads).build()
    val options =
      ObjectDetector.ObjectDetectorOptions
        .builder()
        .setBaseOptions(baseOptions)
        .setScoreThreshold(scoreThreshold)
        .setMaxResults(maxResults)
        .build()
    detector = ObjectDetector.createFromFileAndOptions(context, modelAssetPath, options)
  }

  fun detect(nv21Bytes: ByteArray, width: Int, height: Int): List<Map<String, Any?>> {
    if (nv21Bytes.isEmpty() || width <= 0 || height <= 0) return emptyList()
    val activeDetector = detector ?: run {
      initialize()
      detector
    } ?: return emptyList()
    val bitmap = obtainBitmap(width, height)
    val pixels = obtainArgbBuffer(width, height)
    nv21ToArgb(nv21Bytes, width, height, pixels)
    bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
    val tensorImage = TensorImage.fromBitmap(bitmap)
    val safeWidth = width.coerceAtLeast(1)
    val safeHeight = height.coerceAtLeast(1)

    return activeDetector
      .detect(tensorImage)
      .mapNotNull { detection ->
        val category = detection.categories.maxByOrNull { it.score } ?: return@mapNotNull null
        val box = detection.boundingBox
        val left = (box.left.toFloat() / safeWidth).coerceIn(0f, 1f)
        val top = (box.top.toFloat() / safeHeight).coerceIn(0f, 1f)
        val right = (box.right.toFloat() / safeWidth).coerceIn(0f, 1f)
        val bottom = (box.bottom.toFloat() / safeHeight).coerceIn(0f, 1f)
        val normalizedWidth = (right - left).coerceIn(0f, 1f)
        val normalizedHeight = (bottom - top).coerceIn(0f, 1f)
        if (normalizedWidth <= 0f || normalizedHeight <= 0f) {
          return@mapNotNull null
        }
        mapOf(
          "label" to category.label.lowercase(),
          "displayName" to category.displayName,
          "score" to category.score.toDouble(),
          "left" to left.toDouble(),
          "top" to top.toDouble(),
          "width" to normalizedWidth.toDouble(),
          "height" to normalizedHeight.toDouble(),
        )
      }
  }

  fun dispose() {
    detector?.close()
    detector = null
    reusableBitmap?.recycle()
    reusableBitmap = null
    argbBuffer = null
  }

  private fun obtainBitmap(width: Int, height: Int): Bitmap {
    val current = reusableBitmap
    if (current != null && current.width == width && current.height == height) {
      return current
    }
    current?.recycle()
    return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
      reusableBitmap = it
    }
  }

  private fun obtainArgbBuffer(width: Int, height: Int): IntArray {
    val requiredSize = width * height
    val current = argbBuffer
    if (current != null && current.size == requiredSize) {
      return current
    }
    return IntArray(requiredSize).also {
      argbBuffer = it
    }
  }

  private fun nv21ToArgb(
    nv21Bytes: ByteArray,
    width: Int,
    height: Int,
    output: IntArray,
  ) {
    val frameSize = width * height
    for (y in 0 until height) {
      val yRow = y * width
      val uvRow = frameSize + (y shr 1) * width
      for (x in 0 until width) {
        val yValue = nv21Bytes[yRow + x].toInt() and 0xff
        val uvIndex = uvRow + (x and -2)
        val vValue = (nv21Bytes[uvIndex].toInt() and 0xff) - 128
        val uValue = (nv21Bytes[uvIndex + 1].toInt() and 0xff) - 128

        var r = (yValue + 1.370705f * vValue).toInt()
        var g = (yValue - 0.337633f * uValue - 0.698001f * vValue).toInt()
        var b = (yValue + 1.732446f * uValue).toInt()

        if (r < 0) r = 0 else if (r > 255) r = 255
        if (g < 0) g = 0 else if (g > 255) g = 255
        if (b < 0) b = 0 else if (b > 255) b = 255

        output[yRow + x] =
          (0xff shl 24) or
            (r shl 16) or
            (g shl 8) or
            b
      }
    }
  }

  companion object {
    private const val DEFAULT_MODEL_ASSET = "models/efficientdet_lite0.tflite"
    private const val DEFAULT_SCORE_THRESHOLD = 0.22f
    private const val DEFAULT_MAX_RESULTS = 8
    private const val DEFAULT_NUM_THREADS = 4
  }
}
