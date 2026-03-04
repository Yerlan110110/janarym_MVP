package com.example.janarym_app2

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

class AndroidSttWakeRecognizer(private val context: Context) {
    interface EventListener {
        fun onEvent(event: Map<String, Any?>)
    }

    var eventListener: EventListener? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var speechRecognizer: SpeechRecognizer? = null
    private var language: String = "kk-KZ"
    private var partialResults: Boolean = true
    private var listening = false
    private var disposed = false

    fun initialize(args: Map<String, Any?>) {
        language = args["language"]?.toString()?.ifBlank { "kk-KZ" } ?: "kk-KZ"
        partialResults = args["partialResults"] as? Boolean ?: true
        runOnMain {
            ensureRecognizer()
        }
    }

    fun isAvailable(): Boolean = SpeechRecognizer.isRecognitionAvailable(context)

    fun start() {
        runOnMain {
            if (disposed || !isAvailable()) {
                emitError(SpeechRecognizer.ERROR_CLIENT, "fatal")
                return@runOnMain
            }
            ensureRecognizer()
            if (listening) return@runOnMain
            try {
                speechRecognizer?.startListening(buildIntent())
                listening = true
                emit(mapOf("status" to "listening", "locale" to language))
            } catch (_: Throwable) {
                listening = false
                emitError(SpeechRecognizer.ERROR_CLIENT, "fatal")
            }
        }
    }

    fun stop() {
        runOnMain {
            listening = false
            speechRecognizer?.stopListening()
            emit(mapOf("status" to "stopped", "reason" to "stop", "locale" to language))
        }
    }

    fun cancel() {
        runOnMain {
            listening = false
            speechRecognizer?.cancel()
            emit(mapOf("status" to "stopped", "reason" to "cancel", "locale" to language))
        }
    }

    fun dispose() {
        runOnMain {
            disposed = true
            listening = false
            speechRecognizer?.destroy()
            speechRecognizer = null
            emit(mapOf("status" to "stopped", "reason" to "dispose", "locale" to language))
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "status" to if (!isAvailable()) "unavailable" else if (listening) "listening" else "idle",
        "locale" to language,
    )

    private fun ensureRecognizer() {
        if (speechRecognizer != null || disposed) return
        if (!isAvailable()) return
        val recognizer = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                emit(mapOf("status" to "ready", "locale" to language))
            }

            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = Unit
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit

            override fun onError(error: Int) {
                listening = false
                emitError(error, mapErrorReason(error))
            }

            override fun onResults(results: Bundle?) {
                listening = false
                emitText("final", results)
            }

            override fun onPartialResults(partialResultsBundle: Bundle?) {
                emitText("partial", partialResultsBundle)
            }

            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        speechRecognizer = recognizer
    }

    private fun emitText(status: String, bundle: Bundle?) {
        val matches = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
        val text = matches?.firstOrNull()?.trim().orEmpty()
        if (text.isBlank()) return
        emit(
            mapOf(
                "status" to status,
                "text" to text,
                "locale" to language,
            )
        )
    }

    private fun buildIntent(): Intent {
        return Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, language)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, partialResults)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, false)
        }
    }

    private fun emitError(error: Int, reason: String) {
        emit(
            mapOf(
                "status" to "error",
                "locale" to language,
                "errorCode" to error,
                "errorName" to mapErrorName(error),
                "reason" to reason,
            )
        )
    }

    private fun emit(event: Map<String, Any?>) {
        eventListener?.onEvent(event)
    }

    private fun mapErrorName(code: Int): String {
        return when (code) {
            SpeechRecognizer.ERROR_AUDIO -> "ERROR_AUDIO"
            SpeechRecognizer.ERROR_CLIENT -> "ERROR_CLIENT"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "ERROR_INSUFFICIENT_PERMISSIONS"
            SpeechRecognizer.ERROR_NETWORK -> "ERROR_NETWORK"
            SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "ERROR_NETWORK_TIMEOUT"
            SpeechRecognizer.ERROR_NO_MATCH -> "ERROR_NO_MATCH"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "ERROR_RECOGNIZER_BUSY"
            SpeechRecognizer.ERROR_SERVER -> "ERROR_SERVER"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "ERROR_SPEECH_TIMEOUT"
            else -> "ERROR_UNKNOWN_$code"
        }
    }

    private fun mapErrorReason(code: Int): String {
        return when (code) {
            SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "timeout"
            SpeechRecognizer.ERROR_CLIENT -> "client"
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "fatal"
            else -> "fatal"
        }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }
}
