package com.example.janarym_app2

import ai.picovoice.porcupine.Porcupine
import android.content.Context
import android.content.pm.ApplicationInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.konovalov.vad.silero.VadSilero
import com.konovalov.vad.silero.config.FrameSize as SileroFrameSize
import com.konovalov.vad.silero.config.Mode as SileroMode
import com.konovalov.vad.silero.config.SampleRate as SileroSampleRate
import com.konovalov.vad.webrtc.VadWebRTC
import com.konovalov.vad.webrtc.config.FrameSize as WebRtcFrameSize
import com.konovalov.vad.webrtc.config.Mode as WebRtcMode
import com.konovalov.vad.webrtc.config.SampleRate as WebRtcSampleRate
import io.flutter.FlutterInjector
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

data class NativeWakeWordConfig(
  val accessKey: String,
  val keywordPaths: List<String>,
  val keywordLabels: List<String>,
  val broadSensitivity: Float = 0.68f,
  val strictSensitivity: Float = 0.50f,
  val recallMode: String = "maxRecall",
  val enableOwnerVerification: Boolean = true,
  val enableStage2Verification: Boolean = true,
  val acceptOnStage1: Boolean = false,
  val gatePorcupineWithVad: Boolean = true,
  val enableWakeTemplateVerification: Boolean = true,
  val speakerSimilarityThreshold: Double = 0.70,
  val wakeTemplateThreshold: Double = 0.62,
  val verifyWindowMs: Int = 380,
  val minSpeechRatio: Double = 0.55,
  val requiredStrictHits: Int = 1,
  val repeatRequiredStrictHits: Int = 2,
  val stage2WindowMs: Int = 560,
  val stage2PrerollMs: Int = 180,
  val cooldownMs: Int = 1800,
  val repeatedTriggerWindowMs: Int = 3200,
  val highNoiseDb: Double = -26.0,
  val lowNoiseDb: Double = -40.0,
  val debugLogging: Boolean = false,
) {
  companion object {
    fun fromArgs(args: Map<String, Any?>): NativeWakeWordConfig {
      val keywordPaths =
        (args["keywordPaths"] as? List<*>)
          ?.mapNotNull { it?.toString() }
          ?.filter { it.isNotBlank() }
          ?: emptyList()
      val keywordLabels =
        (args["keywordLabels"] as? List<*>)
          ?.mapNotNull { it?.toString() }
          ?.filter { it.isNotBlank() }
          ?: keywordPaths.map { path ->
            val fileName = path.substringAfterLast('/')
            fileName.substringBeforeLast('.')
          }
      return NativeWakeWordConfig(
        accessKey = args["accessKey"]?.toString()?.trim().orEmpty(),
        keywordPaths = keywordPaths,
        keywordLabels = keywordLabels,
        broadSensitivity = (args["broadSensitivity"] as? Number)?.toFloat() ?: 0.68f,
        strictSensitivity = (args["strictSensitivity"] as? Number)?.toFloat() ?: 0.50f,
        recallMode = args["recallMode"]?.toString()?.trim().orEmpty().ifEmpty { "maxRecall" },
        enableOwnerVerification = args["enableOwnerVerification"] as? Boolean ?: true,
        enableStage2Verification = args["enableStage2Verification"] as? Boolean ?: true,
        acceptOnStage1 = args["acceptOnStage1"] as? Boolean ?: false,
        gatePorcupineWithVad = args["gatePorcupineWithVad"] as? Boolean ?: true,
        enableWakeTemplateVerification =
          args["enableWakeTemplateVerification"] as? Boolean ?: true,
        speakerSimilarityThreshold =
          (args["speakerSimilarityThreshold"] as? Number)?.toDouble() ?: 0.70,
        wakeTemplateThreshold =
          (args["wakeTemplateThreshold"] as? Number)?.toDouble() ?: 0.62,
        verifyWindowMs = (args["verifyWindowMs"] as? Number)?.toInt() ?: 380,
        minSpeechRatio = (args["minSpeechRatio"] as? Number)?.toDouble() ?: 0.55,
        requiredStrictHits = (args["requiredStrictHits"] as? Number)?.toInt() ?: 1,
        repeatRequiredStrictHits =
          (args["repeatRequiredStrictHits"] as? Number)?.toInt() ?: 2,
        stage2WindowMs = (args["stage2WindowMs"] as? Number)?.toInt() ?: 560,
        stage2PrerollMs = (args["stage2PrerollMs"] as? Number)?.toInt() ?: 180,
        cooldownMs = (args["cooldownMs"] as? Number)?.toInt() ?: 1800,
        repeatedTriggerWindowMs =
          (args["repeatedTriggerWindowMs"] as? Number)?.toInt() ?: 3200,
        highNoiseDb = (args["highNoiseDb"] as? Number)?.toDouble() ?: -26.0,
        lowNoiseDb = (args["lowNoiseDb"] as? Number)?.toDouble() ?: -40.0,
        debugLogging = args["debugLogging"] as? Boolean ?: false,
      )
    }
  }
}

data class WakeWordDebugSnapshot(
  val rmsDb: Double,
  val snrDb: Double,
  val vadActive: Boolean,
  val stage1Score: Double,
  val stage2Score: Double,
  val speakerSimilarity: Double,
  val cooldownRemainingMs: Long,
  val reason: String,
  val accepted: Boolean,
)

interface NativeWakeWordEventListener {
  fun onEvent(event: Map<String, Any?>)
}

class NativeWakeWordEngine(context: Context) {
  private val appContext = context.applicationContext
  private val mainHandler = Handler(Looper.getMainLooper())
  private val profileStore = WakeWordProfileStore(appContext)
  private var eventListener: NativeWakeWordEventListener? = null

  @Volatile private var config: NativeWakeWordConfig? = null
  @Volatile private var status: String = "armed"
  private var broadPorcupine: Porcupine? = null
  private var strictPorcupine: Porcupine? = null
  private var vadWebRtc: VadWebRTC? = null
  private var vadSilero: VadSilero? = null
  private var audioRecord: AudioRecord? = null
  private var audioThread: Thread? = null
  private val running = AtomicBoolean(false)
  private var noiseSuppressor: NoiseSuppressor? = null
  private var automaticGainControl: AutomaticGainControl? = null
  private var acousticEchoCanceler: AcousticEchoCanceler? = null
  private var audioBufferSizeBytes = 0
  private var frameLength = 0
  private val highPassFilter = HighPassFilter(cutoffHz = 140.0, sampleRate = SAMPLE_RATE)
  private val vadAccumulator = ShortFifoBuffer()
  private val porcupineAccumulator = ShortFifoBuffer()
  private val recentAudio = ShortCircularBuffer(SAMPLE_RATE * 2)
  private val rollingRmsDb = ArrayDeque<Double>()
  private var lastDebugEmissionMs = 0L
  private var cooldownUntilMs = 0L
  private var lastRejectedAtMs = 0L
  private var lastCandidateAtMs = 0L
  private var candidateCapture: CandidateCapture? = null
  private var enrollmentSession: EnrollmentSession? = null
  private var activeProfile: WakeWordProfile? = null
  private var lastErrorMessage: String? = null

  fun setEventListener(listener: NativeWakeWordEventListener?) {
    eventListener = listener
  }

  @Synchronized
  @Throws(Exception::class)
  fun initialize(newConfig: NativeWakeWordConfig) {
    if (newConfig.accessKey.isBlank()) {
      throw IllegalArgumentException("PICOVOICE_ACCESS_KEY is empty")
    }
    if (newConfig.keywordPaths.isEmpty()) {
      throw IllegalArgumentException("No wake word keyword paths configured")
    }

    val wasRunning = running.get()
    if (wasRunning) {
      stop()
    }
    releaseDetectors()
    releaseAudioRecord()

    try {
      config = newConfig
      activeProfile = profileStore.load()
      buildDetectors(newConfig)
      buildAudioRecord()
      updateState("armed", null)
      emitProfileStatus()
      if (wasRunning) {
        start()
      }
    } catch (error: Exception) {
      updateState("error", error.message ?: "Wake initialization failed")
      throw error
    }
  }

  @Synchronized
  fun start() {
    if (running.get()) return
    val record = audioRecord
    if (record == null || broadPorcupine == null || vadWebRtc == null || vadSilero == null) {
      updateState("error", "Wake engine is not initialized")
      return
    }
    try {
      running.set(true)
      record.startRecording()
      status = "listening"
      emitState()
      audioThread =
        Thread({
          try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            val readBuffer = ShortArray(audioBufferSizeBytes / BYTES_PER_SAMPLE)
            while (running.get()) {
              val read =
                record.read(
                  readBuffer,
                  0,
                  readBuffer.size,
                  AudioRecord.READ_BLOCKING,
                )
              if (read <= 0) {
                maybeLog("read_error code=$read")
                continue
              }
              processAudio(readBuffer, read)
            }
          } catch (error: Exception) {
            maybeLog("audio_thread_error ${error.message}")
            updateState("error", error.message ?: "Wake audio thread failed")
          }
        }, "JanarymWakeThread").also { thread ->
          thread.isDaemon = true
          thread.start()
        }
    } catch (error: Exception) {
      running.set(false)
      updateState("error", error.message ?: "Wake start failed")
    }
  }

  @Synchronized
  fun stop() {
    if (!running.get()) {
      if (status != "error") {
        updateState("armed", null)
      }
      return
    }
    running.set(false)
    candidateCapture = null
    enrollmentSession = null
    try {
      audioRecord?.stop()
    } catch (_: Exception) {
    }
    try {
      audioThread?.join(400)
    } catch (_: InterruptedException) {
      Thread.currentThread().interrupt()
    }
    audioThread = null
    if (status != "error") {
      updateState("armed", null)
    }
  }

  @Synchronized
  fun dispose() {
    stop()
    releaseDetectors()
    releaseAudioRecord()
    eventListener = null
  }

  @Synchronized
  fun hasOwnerProfile(): Boolean = profileStore.load() != null

  @Synchronized
  fun clearOwnerProfile() {
    profileStore.clear()
    activeProfile = null
    emitEvent(
      mapOf(
        "type" to "profile",
        "hasProfile" to false,
      ),
    )
  }

  @Synchronized
  fun startEnrollment(sampleCount: Int) {
    val targetSamples = sampleCount.coerceIn(8, 12)
    enrollmentSession = EnrollmentSession(targetSamples = targetSamples)
    emitEvent(
      mapOf(
        "type" to "enrollment",
        "state" to "started",
        "current" to 0,
        "total" to targetSamples,
      ),
    )
  }

  @Synchronized
  fun cancelEnrollment() {
    enrollmentSession = null
    emitEvent(
      mapOf(
        "type" to "enrollment",
        "state" to "cancelled",
      ),
    )
  }

  fun currentStatus(): String = status

  private fun processAudio(readBuffer: ShortArray, read: Int) {
    val rawChunk = readBuffer.copyOf(read)
    val filteredChunk = highPassFilter.process(rawChunk, rawChunk.size)
    recentAudio.append(filteredChunk, filteredChunk.size)

    val rollingRms = WakeWordAudioFeatures.computeRms(filteredChunk)
    val rollingDb = WakeWordAudioFeatures.normalizeDb(rollingRms)
    synchronized(rollingRmsDb) {
      rollingRmsDb.addLast(rollingDb)
      val maxFrames = max(1, (2000 / 20))
      while (rollingRmsDb.size > maxFrames) {
        rollingRmsDb.removeFirst()
      }
    }

    val noiseFloorRms = estimateNoiseFloorRms()
    val denoisedChunk = WakeWordAudioFeatures.softwareNoiseSuppress(filteredChunk, noiseFloorRms)
    appendCandidateAudio(denoisedChunk)

    vadAccumulator.append(denoisedChunk, denoisedChunk.size)
    while (vadAccumulator.size >= VAD_FRAME_SIZE) {
      val vadFrame = vadAccumulator.pop(VAD_FRAME_SIZE)
      val isSpeech = try {
        vadWebRtc?.isSpeech(vadFrame) ?: false
      } catch (_: Exception) {
        true
      }
      emitDebugSnapshot(
        rmsDb = rollingDb,
        snrDb = computeSnrDb(rollingRms, noiseFloorRms),
        vadActive = isSpeech,
      )
      if (enrollmentSession != null) {
        handleEnrollmentFrame(vadFrame, isSpeech)
      }
      if (candidateCapture != null || enrollmentSession != null) {
        continue
      }
      if ((config?.gatePorcupineWithVad ?: true) && !isSpeech) {
        continue
      }
      porcupineAccumulator.append(vadFrame, vadFrame.size)
      while (porcupineAccumulator.size >= frameLength) {
        val porcupineFrame = porcupineAccumulator.pop(frameLength)
        val keywordIndex = try {
          broadPorcupine?.process(porcupineFrame) ?: -1
        } catch (error: Exception) {
          maybeLog("stage1_error ${error.message}")
          -1
        }
        if (keywordIndex >= 0) {
          handleStage1Candidate(keywordIndex, rollingRms, noiseFloorRms)
        }
      }
    }
  }

  private fun handleStage1Candidate(
    keywordIndex: Int,
    signalRms: Double,
    noiseFloorRms: Double,
  ) {
    val now = SystemClock.elapsedRealtime()
    val currentConfig = config ?: return
    if (now < cooldownUntilMs) {
      emitDecision(
        accepted = false,
        reason = "cooldown",
        rmsDb = WakeWordAudioFeatures.normalizeDb(signalRms),
        snrDb = computeSnrDb(signalRms, noiseFloorRms),
        stage1Score = 1.0,
        stage2VerificationEnabled = currentConfig.enableStage2Verification,
        templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
        ownerVerificationEnabled = currentConfig.enableOwnerVerification,
      )
      return
    }
    if (candidateCapture != null) return
    if (currentConfig.acceptOnStage1 || !currentConfig.enableStage2Verification) {
      cooldownUntilMs = now + currentConfig.cooldownMs
      maybeLog(
        "stage1_accept keywordIndex=$keywordIndex acceptOnStage1=${currentConfig.acceptOnStage1} gatePorcupineWithVad=${currentConfig.gatePorcupineWithVad}",
      )
      emitDecision(
        accepted = true,
        reason = "stage1_accept",
        rmsDb = WakeWordAudioFeatures.normalizeDb(signalRms),
        snrDb = computeSnrDb(signalRms, noiseFloorRms),
        stage1Score = 1.0,
        stage2Score = 1.0,
        templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
        stage2VerificationEnabled = currentConfig.enableStage2Verification,
        ownerVerificationEnabled = currentConfig.enableOwnerVerification,
        minSpeechRatio = currentConfig.minSpeechRatio,
        requiredStrictHits = currentConfig.requiredStrictHits,
        repeatRequiredStrictHits = currentConfig.repeatRequiredStrictHits,
        keywordIndex = keywordIndex,
      )
      emitEvent(
        mapOf(
          "type" to "wake",
          "timestampMs" to System.currentTimeMillis(),
          "keywordIndex" to keywordIndex,
          "keywordLabel" to currentConfig.keywordLabels.getOrElse(keywordIndex) { "unknown" },
          "stage2Score" to 1.0,
          "speakerSimilarity" to null,
        ),
      )
      return
    }
    lastCandidateAtMs = now
    val preRollSamples =
      SAMPLE_RATE * currentConfig.stage2PrerollMs.coerceIn(120, 500) / 1000
    val postSamples =
      SAMPLE_RATE * currentConfig.stage2WindowMs.coerceIn(500, 900) / 1000
    val preRoll = recentAudio.toArray(preRollSamples)
    candidateCapture =
      CandidateCapture(
        keywordIndex = keywordIndex,
        preRollSamples = preRoll,
        targetPostSamples = postSamples,
      )
    maybeLog(
      "stage1_candidate keywordIndex=$keywordIndex preRoll=${preRoll.size} postSamples=$postSamples",
    )
  }

  private fun appendCandidateAudio(samples: ShortArray) {
    val capture = candidateCapture ?: return
    capture.append(samples)
    if (capture.isComplete) {
      candidateCapture = null
      evaluateCandidate(capture.keywordIndex, capture.toShortArray())
    }
  }

  private fun evaluateCandidate(keywordIndex: Int, candidateAudio: ShortArray) {
    val currentConfig = config ?: return
    if (!currentConfig.enableStage2Verification) {
      val signalRms = WakeWordAudioFeatures.computeRms(candidateAudio)
      val rmsDb = WakeWordAudioFeatures.normalizeDb(signalRms)
      val snrDb = computeSnrDb(signalRms, estimateNoiseFloorRms())
      cooldownUntilMs = SystemClock.elapsedRealtime() + currentConfig.cooldownMs
      emitDecision(
        accepted = true,
        reason = "stage2_bypass_accept",
        rmsDb = rmsDb,
        snrDb = snrDb,
        stage1Score = 1.0,
        stage2Score = 1.0,
        templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
        stage2VerificationEnabled = currentConfig.enableStage2Verification,
        ownerVerificationEnabled = currentConfig.enableOwnerVerification,
        minSpeechRatio = currentConfig.minSpeechRatio,
        requiredStrictHits = currentConfig.requiredStrictHits,
        repeatRequiredStrictHits = currentConfig.repeatRequiredStrictHits,
        keywordIndex = keywordIndex,
      )
      emitEvent(
        mapOf(
          "type" to "wake",
          "timestampMs" to System.currentTimeMillis(),
          "keywordIndex" to keywordIndex,
          "keywordLabel" to currentConfig.keywordLabels.getOrElse(keywordIndex) { "unknown" },
          "stage2Score" to 1.0,
          "speakerSimilarity" to null,
        ),
      )
      return
    }
    val profile = activeProfile ?: profileStore.load().also { activeProfile = it }
    val signalRms = WakeWordAudioFeatures.computeRms(candidateAudio)
    val rmsDb = WakeWordAudioFeatures.normalizeDb(signalRms)
    val snrDb = computeSnrDb(signalRms, estimateNoiseFloorRms())
    val recentRejected = SystemClock.elapsedRealtime() - lastRejectedAtMs < currentConfig.repeatedTriggerWindowMs
    val requiredStrictHits =
      if (recentRejected) currentConfig.repeatRequiredStrictHits
      else currentConfig.requiredStrictHits
    val speechRatio = computeSileroSpeechRatio(candidateAudio)
    val strictHits = runStrictVerification(candidateAudio)
    val wakeTemplateSimilarity =
      if (
        currentConfig.enableWakeTemplateVerification &&
          profile?.wakeTemplate?.isNotEmpty() == true
      ) {
        WakeWordAudioFeatures.cosineSimilarity(
          profile.wakeTemplate,
          WakeWordAudioFeatures.computeWakeTemplateEmbedding(candidateAudio, SAMPLE_RATE),
        )
      } else {
        Double.NaN
      }

    val stage2Threshold =
      if (currentConfig.enableWakeTemplateVerification) {
        adjustedWakeTemplateThreshold(currentConfig, rmsDb)
      } else {
        Double.NaN
      }
    val stage2Score = max(speechRatio, if (wakeTemplateSimilarity.isNaN()) 0.0 else wakeTemplateSimilarity)
    val templateReject =
      currentConfig.enableWakeTemplateVerification &&
        !wakeTemplateSimilarity.isNaN() &&
        wakeTemplateSimilarity < stage2Threshold
    if (
      speechRatio < currentConfig.minSpeechRatio ||
        strictHits < requiredStrictHits ||
        templateReject
    ) {
      lastRejectedAtMs = SystemClock.elapsedRealtime()
      emitDecision(
        accepted = false,
        reason = "stage2_reject",
        rmsDb = rmsDb,
        snrDb = snrDb,
        stage1Score = 1.0,
        stage2Score = stage2Score,
        wakeTemplateSimilarity = wakeTemplateSimilarity,
        templateThreshold = stage2Threshold,
        speakerSimilarity = Double.NaN,
        stage2VerificationEnabled = currentConfig.enableStage2Verification,
        templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
        ownerVerificationEnabled = currentConfig.enableOwnerVerification,
        minSpeechRatio = currentConfig.minSpeechRatio,
        requiredStrictHits = requiredStrictHits,
        repeatRequiredStrictHits = currentConfig.repeatRequiredStrictHits,
      )
      maybeLog(
        "stage2_reject speechRatio=${speechRatio.format(3)} minSpeechRatio=${currentConfig.minSpeechRatio.format(3)} strictHits=$strictHits requiredStrictHits=$requiredStrictHits repeatRequiredStrictHits=${currentConfig.repeatRequiredStrictHits} wakeTemplate=${wakeTemplateSimilarity.format(3)} threshold=${stage2Threshold.format(3)} templateCheckEnabled=${currentConfig.enableWakeTemplateVerification}",
      )
      return
    }

    val speakerSimilarity =
      if (currentConfig.enableOwnerVerification && profile?.speakerEmbedding?.isNotEmpty() == true) {
        val verifySamples =
          WakeWordAudioFeatures.sliceLast(
            candidateAudio,
            SAMPLE_RATE * currentConfig.verifyWindowMs.coerceIn(350, 800) / 1000,
          )
        WakeWordAudioFeatures.cosineSimilarity(
          profile.speakerEmbedding,
          WakeWordAudioFeatures.computeSpeakerEmbedding(verifySamples, SAMPLE_RATE),
        )
      } else {
        Double.NaN
      }
    val speakerThreshold =
      if (currentConfig.enableOwnerVerification) {
        adjustedSpeakerThreshold(currentConfig, rmsDb)
      } else {
        Double.NaN
      }
    if (!speakerSimilarity.isNaN() && speakerSimilarity < speakerThreshold) {
      lastRejectedAtMs = SystemClock.elapsedRealtime()
      emitDecision(
        accepted = false,
        reason = "speaker_reject",
        rmsDb = rmsDb,
        snrDb = snrDb,
        stage1Score = 1.0,
        stage2Score = stage2Score,
        wakeTemplateSimilarity = wakeTemplateSimilarity,
        templateThreshold = stage2Threshold,
        speakerSimilarity = speakerSimilarity,
        speakerThreshold = speakerThreshold,
        stage2VerificationEnabled = currentConfig.enableStage2Verification,
        templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
        ownerVerificationEnabled = currentConfig.enableOwnerVerification,
        minSpeechRatio = currentConfig.minSpeechRatio,
        requiredStrictHits = requiredStrictHits,
        repeatRequiredStrictHits = currentConfig.repeatRequiredStrictHits,
      )
      maybeLog(
        "speaker_reject similarity=${speakerSimilarity.format(3)} threshold=${speakerThreshold.format(3)} speakerCheckEnabled=${currentConfig.enableOwnerVerification}",
      )
      return
    }

    cooldownUntilMs = SystemClock.elapsedRealtime() + currentConfig.cooldownMs
    emitDecision(
      accepted = true,
      reason = "accepted",
      rmsDb = rmsDb,
      snrDb = snrDb,
      stage1Score = 1.0,
      stage2Score = stage2Score,
      wakeTemplateSimilarity = wakeTemplateSimilarity,
      templateThreshold = stage2Threshold,
      speakerSimilarity = speakerSimilarity,
      speakerThreshold = speakerThreshold,
      stage2VerificationEnabled = currentConfig.enableStage2Verification,
      templateVerificationEnabled = currentConfig.enableWakeTemplateVerification,
      ownerVerificationEnabled = currentConfig.enableOwnerVerification,
      minSpeechRatio = currentConfig.minSpeechRatio,
      requiredStrictHits = requiredStrictHits,
      repeatRequiredStrictHits = currentConfig.repeatRequiredStrictHits,
      keywordIndex = keywordIndex,
    )
    emitEvent(
      mapOf(
        "type" to "wake",
        "timestampMs" to System.currentTimeMillis(),
        "keywordIndex" to keywordIndex,
        "keywordLabel" to currentConfig.keywordLabels.getOrElse(keywordIndex) { "unknown" },
        "stage2Score" to stage2Score,
        "speakerSimilarity" to if (speakerSimilarity.isNaN()) null else speakerSimilarity,
      ),
    )
  }

  private fun handleEnrollmentFrame(frame: ShortArray, isSpeech: Boolean) {
    val session = enrollmentSession ?: return
    if (isSpeech) {
      session.currentSpeech.append(frame, frame.size)
      session.speechFrames += 1
      session.silenceFrames = 0
      return
    }

    if (session.currentSpeech.size == 0) {
      return
    }
    session.silenceFrames += 1
    if (session.silenceFrames < 4) {
      return
    }

    val sample = session.currentSpeech.pop(session.currentSpeech.size)
    session.currentSpeech.clear()
    session.speechFrames = 0
    session.silenceFrames = 0
    if (sample.size !in MIN_ENROLLMENT_SAMPLES..MAX_ENROLLMENT_SAMPLES) {
      maybeLog("enrollment_skip size=${sample.size}")
      return
    }
    val strictHits = runStrictVerification(sample)
    if (strictHits <= 0) {
      maybeLog("enrollment_skip strict_hits=0")
      return
    }
    session.templateEmbeddings += WakeWordAudioFeatures.computeWakeTemplateEmbedding(sample, SAMPLE_RATE)
    session.speakerEmbeddings += WakeWordAudioFeatures.computeSpeakerEmbedding(sample, SAMPLE_RATE)
    emitEvent(
      mapOf(
        "type" to "enrollment",
        "state" to "progress",
        "current" to session.templateEmbeddings.size,
        "total" to session.targetSamples,
      ),
    )
    if (session.templateEmbeddings.size >= session.targetSamples) {
      val profile =
        WakeWordProfile(
          sampleCount = session.targetSamples,
          wakeTemplate = WakeWordAudioFeatures.mergeEmbeddings(session.templateEmbeddings),
          speakerEmbedding = WakeWordAudioFeatures.mergeEmbeddings(session.speakerEmbeddings),
        )
      profileStore.save(profile)
      activeProfile = profile
      enrollmentSession = null
      emitEvent(
        mapOf(
          "type" to "enrollment",
          "state" to "completed",
          "current" to profile.sampleCount,
          "total" to profile.sampleCount,
        ),
      )
      emitProfileStatus()
    }
  }

  private fun buildDetectors(config: NativeWakeWordConfig) {
    val keywordFiles =
      config.keywordPaths.map { assetPath ->
        resolveAssetToFile(assetPath).absolutePath
      }
    broadPorcupine =
      Porcupine.Builder()
        .setAccessKey(config.accessKey)
        .setKeywordPaths(keywordFiles.toTypedArray())
        .setSensitivities(FloatArray(keywordFiles.size) { config.broadSensitivity })
        .build(appContext)
    // Recall-first mode uses only the broad detector. The strict detector stays
    // disabled to minimize post-hit verification and wake latency.
    strictPorcupine = null
    frameLength = broadPorcupine?.frameLength ?: throw IllegalStateException("Porcupine frame length unavailable")

    vadWebRtc =
      VadWebRTC(
        sampleRate = WebRtcSampleRate.SAMPLE_RATE_16K,
        frameSize = WebRtcFrameSize.FRAME_SIZE_320,
        mode = WebRtcMode.VERY_AGGRESSIVE,
        silenceDurationMs = 120,
        speechDurationMs = 30,
      )
    vadSilero =
      VadSilero(
        appContext,
        sampleRate = SileroSampleRate.SAMPLE_RATE_16K,
        frameSize = SileroFrameSize.FRAME_SIZE_512,
        mode = SileroMode.AGGRESSIVE,
        silenceDurationMs = 150,
        speechDurationMs = 30,
      )
  }

  private fun buildAudioRecord() {
    val minBuffer =
      AudioRecord.getMinBufferSize(
        SAMPLE_RATE,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
      )
    if (minBuffer <= 0) {
      throw IllegalStateException("AudioRecord min buffer unavailable")
    }
    audioBufferSizeBytes =
      max(minBuffer, frameLength * BYTES_PER_SAMPLE * 3)
    val record =
      AudioRecord(
        MediaRecorder.AudioSource.VOICE_RECOGNITION,
        SAMPLE_RATE,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
        audioBufferSizeBytes,
      )
    if (record.state != AudioRecord.STATE_INITIALIZED) {
      record.release()
      throw IllegalStateException("AudioRecord failed to initialize")
    }
    audioRecord = record
    attachAudioEffects(record.audioSessionId)
  }

  private fun attachAudioEffects(sessionId: Int) {
    try {
      noiseSuppressor?.release()
      automaticGainControl?.release()
      acousticEchoCanceler?.release()
      noiseSuppressor =
        if (NoiseSuppressor.isAvailable()) {
          NoiseSuppressor.create(sessionId)?.apply { enabled = true }
        } else {
          null
        }
      automaticGainControl =
        if (AutomaticGainControl.isAvailable()) {
          AutomaticGainControl.create(sessionId)?.apply { enabled = true }
        } else {
          null
        }
      acousticEchoCanceler =
        if (AcousticEchoCanceler.isAvailable()) {
          AcousticEchoCanceler.create(sessionId)?.apply { enabled = true }
        } else {
          null
        }
    } catch (error: Exception) {
      maybeLog("audio_effects_init_failed ${error.message}")
    }
  }

  private fun estimateNoiseFloorRms(): Double {
    val values = synchronized(rollingRmsDb) { rollingRmsDb.toList() }
    if (values.isEmpty()) return 0.0005
    val sorted = values.sorted()
    val percentile = sorted[(sorted.lastIndex * 0.2).toInt()]
    return 10.0.pow(percentile / 20.0)
  }

  private fun computeSileroSpeechRatio(audio: ShortArray): Double {
    val silero = vadSilero ?: return 0.0
    if (audio.size < SILERO_FRAME_SIZE) return 0.0
    var speechFrames = 0
    var totalFrames = 0
    var offset = 0
    while (offset + SILERO_FRAME_SIZE <= audio.size) {
      val frame = audio.copyOfRange(offset, offset + SILERO_FRAME_SIZE)
      if (silero.isSpeech(frame)) {
        speechFrames += 1
      }
      totalFrames += 1
      offset += SILERO_HOP_SIZE
    }
    if (totalFrames == 0) return 0.0
    return speechFrames.toDouble() / totalFrames.toDouble()
  }

  private fun runStrictVerification(audio: ShortArray): Int {
    val strict = strictPorcupine ?: return 1
    if (audio.size < frameLength) return 0
    var hits = 0
    var offset = 0
    val hop = max(1, frameLength / 2)
    while (offset + frameLength <= audio.size) {
      val frame = audio.copyOfRange(offset, offset + frameLength)
      val result = strict.process(frame)
      if (result >= 0) {
        hits += 1
      }
      offset += hop
    }
    return hits
  }

  private fun adjustedSpeakerThreshold(config: NativeWakeWordConfig, rmsDb: Double): Double {
    var threshold = config.speakerSimilarityThreshold
    if (rmsDb > config.highNoiseDb) {
      threshold += 0.05
    } else if (rmsDb > config.lowNoiseDb) {
      threshold += 0.02
    }
    return threshold.coerceIn(0.72, 0.92)
  }

  private fun adjustedWakeTemplateThreshold(config: NativeWakeWordConfig, rmsDb: Double): Double {
    var threshold = config.wakeTemplateThreshold
    if (rmsDb > config.highNoiseDb) {
      threshold += 0.04
    } else if (rmsDb > config.lowNoiseDb) {
      threshold += 0.02
    }
    return threshold.coerceIn(0.62, 0.88)
  }

  private fun emitState() {
    emitEvent(
      mapOf(
        "type" to "state",
        "status" to status,
        "lastError" to lastErrorMessage,
      ),
    )
  }

  private fun updateState(
    newStatus: String,
    error: String?,
  ) {
    status = newStatus
    lastErrorMessage = error
    emitEvent(
      mapOf(
        "type" to "state",
        "status" to newStatus,
        "lastError" to error,
      ),
    )
  }

  private fun emitDecision(
    accepted: Boolean,
    reason: String,
    rmsDb: Double,
    snrDb: Double,
    stage1Score: Double,
    stage2Score: Double = 0.0,
    wakeTemplateSimilarity: Double = Double.NaN,
    templateThreshold: Double = Double.NaN,
    speakerSimilarity: Double = Double.NaN,
    speakerThreshold: Double = Double.NaN,
    stage2VerificationEnabled: Boolean = true,
    templateVerificationEnabled: Boolean = true,
    ownerVerificationEnabled: Boolean = true,
    minSpeechRatio: Double = 0.55,
    requiredStrictHits: Int = 1,
    repeatRequiredStrictHits: Int = 2,
    keywordIndex: Int = -1,
  ) {
    val cooldownRemaining = max(0L, cooldownUntilMs - SystemClock.elapsedRealtime())
    emitEvent(
      mapOf(
        "type" to "debug",
        "rmsDb" to rmsDb,
        "snrDb" to snrDb,
        "vadActive" to true,
        "stage1Score" to stage1Score,
        "stage2Score" to stage2Score,
        "wakeTemplateSimilarity" to if (wakeTemplateSimilarity.isNaN()) null else wakeTemplateSimilarity,
        "templateThreshold" to if (templateThreshold.isNaN()) null else templateThreshold,
        "speakerSimilarity" to if (speakerSimilarity.isNaN()) null else speakerSimilarity,
        "speakerThreshold" to if (speakerThreshold.isNaN()) null else speakerThreshold,
        "stage2VerificationEnabled" to stage2VerificationEnabled,
        "templateVerificationEnabled" to templateVerificationEnabled,
        "ownerVerificationEnabled" to ownerVerificationEnabled,
        "minSpeechRatio" to minSpeechRatio,
        "requiredStrictHits" to requiredStrictHits,
        "repeatRequiredStrictHits" to repeatRequiredStrictHits,
        "cooldownRemainingMs" to cooldownRemaining,
        "reason" to reason,
        "accepted" to accepted,
        "keywordIndex" to keywordIndex,
      ),
    )
  }

  private fun emitDebugSnapshot(rmsDb: Double, snrDb: Double, vadActive: Boolean) {
    val now = SystemClock.elapsedRealtime()
    if (now - lastDebugEmissionMs < DEBUG_EMIT_INTERVAL_MS) return
    lastDebugEmissionMs = now
    val cooldownRemaining = max(0L, cooldownUntilMs - now)
    val currentConfig = config
    emitEvent(
      mapOf(
        "type" to "debug",
        "rmsDb" to rmsDb,
        "snrDb" to snrDb,
        "vadActive" to vadActive,
        "stage1Score" to 0.0,
        "stage2Score" to 0.0,
        "wakeTemplateSimilarity" to null,
        "templateThreshold" to null,
        "speakerSimilarity" to null,
        "speakerThreshold" to null,
        "stage2VerificationEnabled" to (currentConfig?.enableStage2Verification ?: true),
        "templateVerificationEnabled" to (currentConfig?.enableWakeTemplateVerification ?: true),
        "ownerVerificationEnabled" to (currentConfig?.enableOwnerVerification ?: true),
        "minSpeechRatio" to (currentConfig?.minSpeechRatio ?: 0.55),
        "requiredStrictHits" to (currentConfig?.requiredStrictHits ?: 1),
        "repeatRequiredStrictHits" to (currentConfig?.repeatRequiredStrictHits ?: 2),
        "cooldownRemainingMs" to cooldownRemaining,
        "reason" to if (vadActive) "speech" else "noise",
        "accepted" to false,
      ),
    )
  }

  private fun emitProfileStatus() {
    emitEvent(
      mapOf(
        "type" to "profile",
        "hasProfile" to (activeProfile != null),
      ),
    )
  }

  private fun emitEvent(event: Map<String, Any?>) {
    val listener = eventListener ?: return
    mainHandler.post {
      listener.onEvent(event)
    }
  }

  private fun maybeLog(message: String) {
    if (!isDebuggableApp() || config?.debugLogging != true) return
    Log.i(TAG, message)
  }

  private fun isDebuggableApp(): Boolean {
    return (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
  }

  private fun computeSnrDb(signalRms: Double, noiseRms: Double): Double {
    val ratio = max(signalRms, 1e-7) / max(noiseRms, 1e-7)
    return 20.0 * kotlin.math.log10(ratio)
  }

  private fun releaseDetectors() {
    try {
      broadPorcupine?.delete()
    } catch (_: Exception) {
    }
    try {
      strictPorcupine?.delete()
    } catch (_: Exception) {
    }
    broadPorcupine = null
    strictPorcupine = null
    try {
      vadWebRtc?.close()
    } catch (_: Exception) {
    }
    try {
      vadSilero?.close()
    } catch (_: Exception) {
    }
    vadWebRtc = null
    vadSilero = null
  }

  private fun releaseAudioRecord() {
    try {
      noiseSuppressor?.release()
    } catch (_: Exception) {
    }
    try {
      automaticGainControl?.release()
    } catch (_: Exception) {
    }
    try {
      acousticEchoCanceler?.release()
    } catch (_: Exception) {
    }
    noiseSuppressor = null
    automaticGainControl = null
    acousticEchoCanceler = null
    try {
      audioRecord?.release()
    } catch (_: Exception) {
    }
    audioRecord = null
  }

  private fun resolveAssetToFile(assetPath: String): File {
    val lookupKey = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(assetPath)
    val outFile = File(appContext.filesDir, "wake_assets/$assetPath")
    if (outFile.exists() && outFile.length() > 0) {
      return outFile
    }
    outFile.parentFile?.mkdirs()
    appContext.assets.open(lookupKey).use { input ->
      FileOutputStream(outFile).use { output ->
        input.copyTo(output)
      }
    }
    return outFile
  }

  private fun Double.format(digits: Int): String = "%.${digits}f".format(this)

  private data class CandidateCapture(
    val keywordIndex: Int,
    val preRollSamples: ShortArray,
    val targetPostSamples: Int,
  ) {
    private val postRoll = ShortFifoBuffer()

    val isComplete: Boolean
      get() = postRoll.size >= targetPostSamples

    fun append(samples: ShortArray) {
      if (samples.isNotEmpty()) {
        postRoll.append(samples, samples.size)
      }
    }

    fun toShortArray(): ShortArray {
      val post = postRoll.pop(min(postRoll.size, targetPostSamples))
      return preRollSamples + post
    }
  }

  private data class EnrollmentSession(
    val targetSamples: Int,
    val currentSpeech: ShortFifoBuffer = ShortFifoBuffer(),
    val templateEmbeddings: MutableList<DoubleArray> = mutableListOf(),
    val speakerEmbeddings: MutableList<DoubleArray> = mutableListOf(),
    var speechFrames: Int = 0,
    var silenceFrames: Int = 0,
  )

  private class ShortFifoBuffer(initialCapacity: Int = 2048) {
    private var data = ShortArray(initialCapacity)
    var size: Int = 0
      private set

    fun append(samples: ShortArray, length: Int) {
      if (length <= 0) return
      ensureCapacity(size + length)
      System.arraycopy(samples, 0, data, size, length)
      size += length
    }

    fun pop(length: Int): ShortArray {
      val actual = min(length, size)
      if (actual <= 0) return ShortArray(0)
      val out = data.copyOfRange(0, actual)
      if (actual < size) {
        System.arraycopy(data, actual, data, 0, size - actual)
      }
      size -= actual
      return out
    }

    fun clear() {
      size = 0
    }

    private fun ensureCapacity(target: Int) {
      if (target <= data.size) return
      var next = data.size
      while (next < target) {
        next *= 2
      }
      data = data.copyOf(next)
    }
  }

  private class ShortCircularBuffer(private val capacity: Int) {
    private val data = ShortArray(capacity)
    private var writeIndex = 0
    private var size = 0

    fun append(samples: ShortArray, length: Int) {
      for (i in 0 until length) {
        data[writeIndex] = samples[i]
        writeIndex = (writeIndex + 1) % capacity
        if (size < capacity) {
          size += 1
        }
      }
    }

    fun toArray(maxSamples: Int = size): ShortArray {
      val actual = min(maxSamples, size)
      val out = ShortArray(actual)
      val start = (writeIndex - actual + capacity) % capacity
      for (i in 0 until actual) {
        out[i] = data[(start + i) % capacity]
      }
      return out
    }
  }

  companion object {
    private const val TAG = "NativeWakeWord"
    private const val SAMPLE_RATE = 16000
    private const val BYTES_PER_SAMPLE = 2
    private const val VAD_FRAME_SIZE = 320
    private const val SILERO_FRAME_SIZE = 512
    private const val SILERO_HOP_SIZE = 256
    private const val MIN_ENROLLMENT_SAMPLES = SAMPLE_RATE / 3
    private const val MAX_ENROLLMENT_SAMPLES = SAMPLE_RATE * 2
    private const val DEBUG_EMIT_INTERVAL_MS = 250L
  }
}
