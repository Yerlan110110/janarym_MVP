package com.example.janarym_app2

import android.app.Application
import android.util.Log
import com.yandex.mapkit.MapKitFactory

class MainApplication : Application() {
  override fun onCreate() {
    super.onCreate()

    val apiKey = readYandexApiKeyFromFlutterAssets()
    if (apiKey.isNotBlank()) {
      MapKitFactory.setApiKey(apiKey)
      Log.i("MainApplication", "Yandex MapKit API key loaded from .env")
    } else {
      Log.w(
        "MainApplication",
        "YANDEX_MAPKIT_API_KEY is empty. Map and routing may be unavailable.",
      )
    }
  }

  private fun readYandexApiKeyFromFlutterAssets(): String {
    return try {
      assets.open("flutter_assets/.env").bufferedReader().useLines { lines ->
        lines
          .map { it.trim() }
          .firstOrNull { it.startsWith("YANDEX_MAPKIT_API_KEY=") }
          ?.substringAfter("=")
          ?.trim()
          ?: ""
      }
    } catch (_: Exception) {
      ""
    }
  }
}
