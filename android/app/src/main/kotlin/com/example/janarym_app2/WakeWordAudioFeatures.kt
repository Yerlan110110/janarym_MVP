package com.example.janarym_app2

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

internal class HighPassFilter(
  private val cutoffHz: Double,
  private val sampleRate: Int,
) {
  private val alpha: Double = computeAlpha()
  private var prevInput = 0.0
  private var prevOutput = 0.0

  fun process(input: ShortArray, length: Int): ShortArray {
    val output = ShortArray(length)
    for (i in 0 until length) {
      val x = input[i].toDouble()
      val y = alpha * (prevOutput + x - prevInput)
      prevInput = x
      prevOutput = y
      output[i] = y.coerceIn(-32768.0, 32767.0).toInt().toShort()
    }
    return output
  }

  private fun computeAlpha(): Double {
    val rc = 1.0 / (2.0 * PI * cutoffHz)
    val dt = 1.0 / sampleRate.toDouble()
    return rc / (rc + dt)
  }
}

internal object WakeWordAudioFeatures {
  private const val EPSILON = 1e-9
  private const val SPEAKER_FRAME_SIZE = 400
  private const val SPEAKER_HOP_SIZE = 160
  private const val SPEAKER_NFFT = 512
  private const val MFCC_COUNT = 13
  private const val MEL_FILTERS = 20
  private const val TEMPLATE_TIME_STEPS = 20

  fun normalizeDb(rms: Double): Double {
    return 20.0 * kotlin.math.log10(max(rms, EPSILON))
  }

  fun computeRms(samples: ShortArray): Double {
    if (samples.isEmpty()) return 0.0
    var sum = 0.0
    for (sample in samples) {
      val normalized = sample / 32768.0
      sum += normalized * normalized
    }
    return sqrt(sum / samples.size)
  }

  fun softwareNoiseSuppress(
    samples: ShortArray,
    noiseFloorRms: Double,
  ): ShortArray {
    val frameRms = computeRms(samples)
    if (frameRms <= EPSILON) return samples.copyOf()
    val attenuation =
      when {
        frameRms < noiseFloorRms * 1.1 -> 0.12
        frameRms < noiseFloorRms * 1.35 -> 0.35
        else -> 1.0
      }
    if (attenuation >= 0.999) return samples.copyOf()
    return ShortArray(samples.size) { index ->
      (samples[index] * attenuation).toInt().toShort()
    }
  }

  fun computeSpeakerEmbedding(samples: ShortArray, sampleRate: Int): DoubleArray {
    val mfccFrames = computeMfccFrames(samples, sampleRate)
    if (mfccFrames.isEmpty()) return DoubleArray(0)
    val means = DoubleArray(MFCC_COUNT)
    val stds = DoubleArray(MFCC_COUNT)
    for (coeff in 0 until MFCC_COUNT) {
      for (frame in mfccFrames) {
        means[coeff] += frame[coeff]
      }
      means[coeff] /= mfccFrames.size.toDouble()
      for (frame in mfccFrames) {
        val delta = frame[coeff] - means[coeff]
        stds[coeff] += delta * delta
      }
      stds[coeff] = sqrt(stds[coeff] / mfccFrames.size.toDouble())
    }
    return normalize(means + stds)
  }

  fun computeWakeTemplateEmbedding(
    samples: ShortArray,
    sampleRate: Int,
  ): DoubleArray {
    val mfccFrames = computeMfccFrames(samples, sampleRate)
    if (mfccFrames.isEmpty()) return DoubleArray(0)
    val flattened = DoubleArray(TEMPLATE_TIME_STEPS * MFCC_COUNT)
    for (step in 0 until TEMPLATE_TIME_STEPS) {
      val position =
        if (TEMPLATE_TIME_STEPS == 1) {
          0.0
        } else {
          step * (mfccFrames.lastIndex.toDouble() / (TEMPLATE_TIME_STEPS - 1))
        }
      val low = position.toInt()
      val high = min(low + 1, mfccFrames.lastIndex)
      val weight = position - low
      for (coeff in 0 until MFCC_COUNT) {
        flattened[step * MFCC_COUNT + coeff] =
          mfccFrames[low][coeff] * (1.0 - weight) + mfccFrames[high][coeff] * weight
      }
    }
    return normalize(flattened)
  }

  fun cosineSimilarity(a: DoubleArray, b: DoubleArray): Double {
    if (a.isEmpty() || b.isEmpty()) return 0.0
    val size = min(a.size, b.size)
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for (i in 0 until size) {
      dot += a[i] * b[i]
      normA += a[i] * a[i]
      normB += b[i] * b[i]
    }
    if (normA <= EPSILON || normB <= EPSILON) return 0.0
    return dot / (sqrt(normA) * sqrt(normB))
  }

  fun mergeEmbeddings(embeddings: List<DoubleArray>): DoubleArray {
    val valid = embeddings.filter { it.isNotEmpty() }
    if (valid.isEmpty()) return DoubleArray(0)
    val size = valid.minOf { it.size }
    val merged = DoubleArray(size)
    for (embedding in valid) {
      for (i in 0 until size) {
        merged[i] += embedding[i]
      }
    }
    for (i in 0 until size) {
      merged[i] /= valid.size.toDouble()
    }
    return normalize(merged)
  }

  fun sliceLast(samples: ShortArray, sampleCount: Int): ShortArray {
    if (sampleCount <= 0 || samples.isEmpty()) return ShortArray(0)
    if (samples.size <= sampleCount) return samples.copyOf()
    return samples.copyOfRange(samples.size - sampleCount, samples.size)
  }

  private fun computeMfccFrames(samples: ShortArray, sampleRate: Int): List<DoubleArray> {
    if (samples.size < SPEAKER_FRAME_SIZE) return emptyList()
    val melFilterBank = buildMelFilterBank(sampleRate)
    val hammingWindow = DoubleArray(SPEAKER_FRAME_SIZE) { index ->
      0.54 - 0.46 * cos((2.0 * PI * index) / (SPEAKER_FRAME_SIZE - 1))
    }
    val emphasized = DoubleArray(samples.size)
    var previous = 0.0
    for (i in samples.indices) {
      val current = samples[i] / 32768.0
      emphasized[i] = current - 0.97 * previous
      previous = current
    }

    val frames = ArrayList<DoubleArray>()
    var offset = 0
    while (offset + SPEAKER_FRAME_SIZE <= emphasized.size) {
      val frame = DoubleArray(SPEAKER_FRAME_SIZE)
      for (i in frame.indices) {
        frame[i] = emphasized[offset + i] * hammingWindow[i]
      }
      val powerSpectrum = computePowerSpectrum(frame, SPEAKER_NFFT)
      val melEnergies = DoubleArray(MEL_FILTERS)
      for (filter in 0 until MEL_FILTERS) {
        var energy = 0.0
        for (bin in powerSpectrum.indices) {
          energy += powerSpectrum[bin] * melFilterBank[filter][bin]
        }
        melEnergies[filter] = ln(max(energy, EPSILON))
      }
      frames.add(discreteCosineTransform(melEnergies, MFCC_COUNT))
      offset += SPEAKER_HOP_SIZE
    }
    return frames
  }

  private fun computePowerSpectrum(frame: DoubleArray, nfft: Int): DoubleArray {
    val spectrum = DoubleArray((nfft / 2) + 1)
    for (k in spectrum.indices) {
      var real = 0.0
      var imag = 0.0
      for (n in frame.indices) {
        val angle = (2.0 * PI * k * n) / nfft
        real += frame[n] * cos(angle)
        imag -= frame[n] * kotlin.math.sin(angle)
      }
      spectrum[k] = (real * real + imag * imag) / nfft
    }
    return spectrum
  }

  private fun buildMelFilterBank(sampleRate: Int): Array<DoubleArray> {
    val lowMel = hzToMel(20.0)
    val highMel = hzToMel(sampleRate / 2.0)
    val melPoints = DoubleArray(MEL_FILTERS + 2) { index ->
      lowMel + (highMel - lowMel) * index / (MEL_FILTERS + 1)
    }
    val hzPoints = melPoints.map(::melToHz)
    val binPoints = hzPoints.map { hz ->
      ((SPEAKER_NFFT + 1) * hz / sampleRate).toInt().coerceIn(0, SPEAKER_NFFT / 2)
    }
    return Array(MEL_FILTERS) { filter ->
      val weights = DoubleArray((SPEAKER_NFFT / 2) + 1)
      val start = binPoints[filter]
      val center = binPoints[filter + 1]
      val end = binPoints[filter + 2]
      for (bin in start until center) {
        val denominator = max(center - start, 1)
        weights[bin] = (bin - start).toDouble() / denominator
      }
      for (bin in center until end) {
        val denominator = max(end - center, 1)
        weights[bin] = (end - bin).toDouble() / denominator
      }
      weights
    }
  }

  private fun discreteCosineTransform(input: DoubleArray, outputSize: Int): DoubleArray {
    val output = DoubleArray(outputSize)
    for (k in 0 until outputSize) {
      var sum = 0.0
      for (n in input.indices) {
        sum += input[n] * cos((PI / input.size) * (n + 0.5) * k)
      }
      output[k] = sum
    }
    return output
  }

  private fun normalize(values: DoubleArray): DoubleArray {
    var norm = 0.0
    for (value in values) {
      norm += value * value
    }
    norm = sqrt(norm)
    if (norm <= EPSILON) return values.copyOf()
    return DoubleArray(values.size) { index -> values[index] / norm }
  }

  private fun hzToMel(hz: Double): Double = 2595.0 * ln(1.0 + hz / 700.0) / ln(10.0)

  private fun melToHz(mel: Double): Double = 700.0 * (10.0.pow(mel / 2595.0) - 1.0)
}
