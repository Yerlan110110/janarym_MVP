package com.example.janarym_app2

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class WakeWordProfile(
  val sampleCount: Int,
  val wakeTemplate: DoubleArray,
  val speakerEmbedding: DoubleArray,
)

class WakeWordProfileStore(context: Context) {
  private val appContext = context.applicationContext
  private val preferences =
    appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

  fun load(): WakeWordProfile? {
    val payload = preferences.getString(PROFILE_KEY, null) ?: return null
    return try {
      val decoded = decrypt(payload)
      val json = JSONObject(decoded)
      WakeWordProfile(
        sampleCount = json.optInt("sampleCount", 0),
        wakeTemplate = json.optJSONArray("wakeTemplate").toDoubleArray(),
        speakerEmbedding = json.optJSONArray("speakerEmbedding").toDoubleArray(),
      )
    } catch (_: Exception) {
      null
    }
  }

  fun save(profile: WakeWordProfile) {
    val json = JSONObject()
      .put("sampleCount", profile.sampleCount)
      .put("wakeTemplate", JSONArray(profile.wakeTemplate.toList()))
      .put("speakerEmbedding", JSONArray(profile.speakerEmbedding.toList()))
      .toString()
    preferences.edit().putString(PROFILE_KEY, encrypt(json)).apply()
  }

  fun clear() {
    preferences.edit().remove(PROFILE_KEY).apply()
  }

  private fun encrypt(plainText: String): String {
    val cipher = Cipher.getInstance(TRANSFORMATION)
    cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
    val ciphertext = cipher.doFinal(plainText.toByteArray(StandardCharsets.UTF_8))
    val iv = cipher.iv
    val packed = ByteBuffer
      .allocate(Int.SIZE_BYTES + iv.size + ciphertext.size)
      .putInt(iv.size)
      .put(iv)
      .put(ciphertext)
      .array()
    return Base64.encodeToString(packed, Base64.NO_WRAP)
  }

  private fun decrypt(payload: String): String {
    val bytes = Base64.decode(payload, Base64.NO_WRAP)
    val buffer = ByteBuffer.wrap(bytes)
    val ivSize = buffer.int
    val iv = ByteArray(ivSize)
    buffer.get(iv)
    val ciphertext = ByteArray(buffer.remaining())
    buffer.get(ciphertext)
    val cipher = Cipher.getInstance(TRANSFORMATION)
    cipher.init(
      Cipher.DECRYPT_MODE,
      getOrCreateSecretKey(),
      GCMParameterSpec(GCM_TAG_BITS, iv),
    )
    return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
  }

  private fun getOrCreateSecretKey(): SecretKey {
    val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }
    val existing = keyStore.getKey(KEY_ALIAS, null) as? SecretKey
    if (existing != null) {
      return existing
    }

    val keyGenerator =
      KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEY_STORE)
    val keySpec = KeyGenParameterSpec.Builder(
      KEY_ALIAS,
      KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
    )
      .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
      .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
      .setKeySize(256)
      .build()
    keyGenerator.init(keySpec)
    return keyGenerator.generateKey()
  }

  private fun JSONArray?.toDoubleArray(): DoubleArray {
    if (this == null) return DoubleArray(0)
    return DoubleArray(length()) { index -> optDouble(index, 0.0) }
  }

  companion object {
    private const val PREFS_NAME = "janarym_wake_word_profile"
    private const val PROFILE_KEY = "encrypted_profile_v2"
    private const val KEY_ALIAS = "janarym_wake_profile_key"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val ANDROID_KEY_STORE = "AndroidKeyStore"
    private const val GCM_TAG_BITS = 128
  }
}
