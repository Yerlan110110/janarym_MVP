package com.example.janarym_app2

import android.app.Application
import android.content.pm.ApplicationInfo
import android.util.Log
import com.yandex.mapkit.MapKitFactory

class MainApplication : Application() {
  override fun onCreate() {
    super.onCreate()

    val apiKey = readYandexApiKeyFromFlutterAssets()
    if (apiKey.isNotBlank()) {
      MapKitFactory.setApiKey(apiKey)
      if (isDebuggableApp()) {
        Log.i("MainApplication", "Yandex MapKit API key loaded from .env")
      }
    } else {
      if (isDebuggableApp()) {
        Log.w(
          "MainApplication",
          "YANDEX_MAPKIT_API_KEY is empty. Map and routing may be unavailable.",
        )
      }
    }
  }

  private fun readYandexApiKeyFromFlutterAssets(): String {
    val assetCandidates = listOf(
      "flutter_assets/.env",
      "flutter_assets/.env.example",
    )
    for (assetPath in assetCandidates) {
      val apiKey = runCatching {
        assets.open(assetPath).bufferedReader().useLines { lines ->
          for (line in lines) {
            val value = parseEnvValue(line.trim(), "YANDEX_MAPKIT_API_KEY")
            if (value != null) {
              return@useLines value
            }
          }
          ""
        }
      }.getOrNull()
      if (apiKey != null) {
        return apiKey
      }
    }
    return ""
  }

  private fun parseEnvValue(line: String, key: String): String? {
    val prefix = "$key="
    if (!line.startsWith(prefix)) return null
    val rawValue = line.substringAfter("=").trim()
    val uncommented = rawValue.substringBefore("#").trim()
    return uncommented.removeSurrounding("\"").removeSurrounding("'").trim()
  }

  private fun isDebuggableApp(): Boolean {
    return (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
  }
}
