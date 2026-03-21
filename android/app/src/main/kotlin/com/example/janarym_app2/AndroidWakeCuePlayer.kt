package com.example.janarym_app2

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import java.io.File
import java.io.FileOutputStream

class AndroidWakeCuePlayer(private val context: Context) {
  @Volatile private var soundPool: SoundPool? = null
  @Volatile private var soundId: Int = 0
  @Volatile private var loaded: Boolean = false
  @Volatile private var loading: Boolean = false

  @Synchronized
  fun preload(): Boolean {
    if (loaded) return true
    if (loading) return false

    val pool = soundPool ?: SoundPool.Builder()
      .setMaxStreams(1)
      .setAudioAttributes(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .build(),
      )
      .build()
      .also { created ->
        created.setOnLoadCompleteListener { _, sampleId, status ->
          loaded = status == 0 && sampleId == soundId
          loading = false
        }
        soundPool = created
      }

    return try {
      loading = true
      val soundFile = ensureWakeCueFile()
      soundId = pool.load(soundFile.absolutePath, 1)
      soundId != 0
    } catch (_: Exception) {
      loading = false
      false
    }
  }

  fun play(): Boolean {
    if (!loaded) {
      preload()
    }
    val pool = soundPool ?: return false
    val id = soundId
    if (!loaded || id == 0) return false
    return pool.play(id, 1f, 1f, 1, 0, 1f) != 0
  }

  @Synchronized
  fun release() {
    loaded = false
    loading = false
    soundId = 0
    soundPool?.release()
    soundPool = null
  }

  private fun ensureWakeCueFile(): File {
    val target = File(context.cacheDir, "wake_cue_start.wav")
    if (target.exists() && target.length() > 0L) {
      return target
    }
    context.assets.open(ASSET_PATH).use { input ->
      FileOutputStream(target).use { output ->
        input.copyTo(output)
      }
    }
    return target
  }

  companion object {
    private const val ASSET_PATH = "flutter_assets/assets/sounds/start.wav"
  }
}
