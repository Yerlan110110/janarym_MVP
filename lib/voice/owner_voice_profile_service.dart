import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:record/record.dart';

class RecordedVoiceSample {
  const RecordedVoiceSample({
    required this.wavBytes,
    required this.rmsDb,
    required this.durationMs,
  });

  final Uint8List wavBytes;
  final double rmsDb;
  final int durationMs;
}

class OwnerVoiceVerificationResult {
  const OwnerVoiceVerificationResult({
    required this.hasProfile,
    required this.matched,
    required this.similarity,
    required this.threshold,
    required this.noiseDb,
  });

  final bool hasProfile;
  final bool matched;
  final double similarity;
  final double threshold;
  final double noiseDb;
}

class OwnerVoiceProfileService {
  OwnerVoiceProfileService({
    FlutterSecureStorage? secureStorage,
    AudioRecorder? recorder,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _recorder = recorder ?? AudioRecorder();

  static const String _profileKey = 'janarym_owner_voice_profile_v1';
  final FlutterSecureStorage _secureStorage;
  final AudioRecorder _recorder;

  _VoiceProfile? _profile;

  bool get hasProfile => _profile != null;

  Future<void> init() async {
    final raw = await _secureStorage.read(key: _profileKey);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final vectorRaw = decoded['vector'] as List<dynamic>? ?? const [];
      final vector = vectorRaw
          .map((item) => (item as num).toDouble())
          .toList(growable: false);
      if (vector.isEmpty) return;
      _profile = _VoiceProfile(
        sampleCount: (decoded['sampleCount'] as num?)?.toInt() ?? 1,
        vector: vector,
      );
    } catch (_) {
      _profile = null;
    }
  }

  Future<RecordedVoiceSample?> captureSample({int durationMs = 320}) async {
    final canRecord = await _recorder.hasPermission();
    if (!canRecord) return null;
    final path =
        '${Directory.systemTemp.path}/janarym_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        noiseSuppress: true,
        echoCancel: true,
      ),
      path: path,
    );
    await Future.delayed(Duration(milliseconds: durationMs.clamp(200, 1200)));
    try {
      await _recorder.stop();
    } catch (_) {}
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } catch (_) {}
    final pcm = _extractPcm(bytes);
    return RecordedVoiceSample(
      wavBytes: bytes,
      rmsDb: _computeRmsDb(pcm),
      durationMs: durationMs,
    );
  }

  Future<OwnerVoiceVerificationResult> verifySample(
    RecordedVoiceSample sample,
  ) async {
    final noiseDb = sample.rmsDb;
    final vector = _extractVoiceprint(sample.wavBytes);
    final existing = _profile;
    if (existing == null || vector.isEmpty) {
      return OwnerVoiceVerificationResult(
        hasProfile: false,
        matched: true,
        similarity: 1,
        threshold: _adaptiveThreshold(noiseDb),
        noiseDb: noiseDb,
      );
    }
    final similarity = _cosineSimilarity(existing.vector, vector);
    final threshold = _adaptiveThreshold(noiseDb);
    return OwnerVoiceVerificationResult(
      hasProfile: true,
      matched: similarity >= threshold,
      similarity: similarity,
      threshold: threshold,
      noiseDb: noiseDb,
    );
  }

  Future<void> autoEnrollIfNeeded(RecordedVoiceSample sample) async {
    final vector = _extractVoiceprint(sample.wavBytes);
    if (vector.isEmpty) return;
    final existing = _profile;
    if (existing == null) {
      _profile = _VoiceProfile(sampleCount: 1, vector: vector);
    } else if (existing.sampleCount < 5) {
      final nextCount = existing.sampleCount + 1;
      final merged = List<double>.generate(
        min(existing.vector.length, vector.length),
        (index) =>
            ((existing.vector[index] * existing.sampleCount) + vector[index]) /
            nextCount,
        growable: false,
      );
      _profile = _VoiceProfile(sampleCount: nextCount, vector: merged);
    } else {
      return;
    }
    await _persist();
  }

  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {}
  }

  Future<void> _persist() async {
    final profile = _profile;
    if (profile == null) return;
    await _secureStorage.write(
      key: _profileKey,
      value: jsonEncode(<String, Object?>{
        'sampleCount': profile.sampleCount,
        'vector': profile.vector,
      }),
    );
  }

  double _adaptiveThreshold(double noiseDb) {
    var threshold = 0.78;
    if (noiseDb > -24) {
      threshold += 0.1;
    } else if (noiseDb > -30) {
      threshold += 0.06;
    } else if (noiseDb < -42) {
      threshold -= 0.04;
    }
    return threshold.clamp(0.66, 0.92).toDouble();
  }

  List<double> _extractVoiceprint(Uint8List wavBytes) {
    final pcm = _extractPcm(wavBytes);
    if (pcm.length < 256) return const [];
    final frameSize = 400;
    final hop = 160;
    final bandFrequencies = <double>[250, 500, 1000, 1800, 2600, 3600];
    final bandValues = List<List<double>>.generate(
      bandFrequencies.length,
      (_) => <double>[],
    );
    final rmsValues = <double>[];
    final zcrValues = <double>[];

    for (var offset = 0; offset + frameSize <= pcm.length; offset += hop) {
      final frame = pcm.sublist(offset, offset + frameSize);
      rmsValues.add(_frameRms(frame));
      zcrValues.add(_frameZeroCrossingRate(frame));
      for (var i = 0; i < bandFrequencies.length; i++) {
        bandValues[i].add(_goertzelMagnitude(frame, 16000, bandFrequencies[i]));
      }
    }

    final features = <double>[
      _mean(rmsValues),
      _stddev(rmsValues),
      _mean(zcrValues),
      _stddev(zcrValues),
    ];
    for (final values in bandValues) {
      final logged = values.map((value) => log(value + 1e-8)).toList();
      features.add(_mean(logged));
      features.add(_stddev(logged));
    }
    final norm = sqrt(
      features.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (norm <= 1e-9) return const [];
    return features.map((value) => value / norm).toList(growable: false);
  }

  List<double> _extractPcm(Uint8List wavBytes) {
    if (wavBytes.length < 44) return const [];
    final bytes = ByteData.sublistView(wavBytes);
    if (_ascii(bytes, 0, 4) != 'RIFF' || _ascii(bytes, 8, 12) != 'WAVE') {
      return const [];
    }
    var channels = 1;
    var bitsPerSample = 16;
    var sampleRate = 16000;
    Uint8List? rawPcm;
    var offset = 12;
    while (offset + 8 <= wavBytes.length) {
      final chunkId = _ascii(bytes, offset, offset + 4);
      final chunkSize = bytes.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;
      final dataEnd = dataStart + chunkSize;
      if (dataEnd > wavBytes.length) break;
      if (chunkId == 'fmt ') {
        channels = bytes.getUint16(dataStart + 2, Endian.little);
        sampleRate = bytes.getUint32(dataStart + 4, Endian.little);
        bitsPerSample = bytes.getUint16(dataStart + 14, Endian.little);
      } else if (chunkId == 'data') {
        rawPcm = Uint8List.sublistView(wavBytes, dataStart, dataEnd);
        break;
      }
      offset = dataEnd + (chunkSize.isOdd ? 1 : 0);
    }
    if (rawPcm == null || bitsPerSample != 16) return const [];
    final data = ByteData.sublistView(rawPcm);
    final samples = <double>[];
    for (var i = 0; i + (channels * 2) <= rawPcm.length; i += channels * 2) {
      double mixed = 0;
      for (var ch = 0; ch < channels; ch++) {
        mixed += data.getInt16(i + (ch * 2), Endian.little) / 32768.0;
      }
      samples.add(mixed / channels);
    }
    if (sampleRate == 16000) return samples;
    final step = sampleRate / 16000.0;
    final downsampled = <double>[];
    for (double pos = 0; pos < samples.length; pos += step) {
      downsampled.add(samples[pos.floor()]);
    }
    return downsampled;
  }

  String _ascii(ByteData data, int start, int end) {
    final buffer = StringBuffer();
    for (var i = start; i < end; i++) {
      buffer.writeCharCode(data.getUint8(i));
    }
    return buffer.toString();
  }

  double _computeRmsDb(List<double> pcm) {
    if (pcm.isEmpty) return -90;
    final rms = _frameRms(pcm);
    if (rms <= 1e-9) return -90;
    return 20 * (log(rms) / ln10);
  }

  double _frameRms(List<double> frame) {
    if (frame.isEmpty) return 0;
    final sum = frame.fold<double>(0, (acc, sample) => acc + sample * sample);
    return sqrt(sum / frame.length);
  }

  double _frameZeroCrossingRate(List<double> frame) {
    if (frame.length < 2) return 0;
    var crossings = 0;
    for (var i = 1; i < frame.length; i++) {
      final prev = frame[i - 1];
      final next = frame[i];
      if ((prev >= 0 && next < 0) || (prev < 0 && next >= 0)) {
        crossings++;
      }
    }
    return crossings / frame.length;
  }

  double _goertzelMagnitude(
    List<double> frame,
    double sampleRate,
    double targetFrequency,
  ) {
    final omega = 2 * pi * targetFrequency / sampleRate;
    final coeff = 2 * cos(omega);
    var q0 = 0.0;
    var q1 = 0.0;
    var q2 = 0.0;
    for (final sample in frame) {
      q0 = coeff * q1 - q2 + sample;
      q2 = q1;
      q1 = q0;
    }
    final real = q1 - q2 * cos(omega);
    final imag = q2 * sin(omega);
    return sqrt(real * real + imag * imag) / frame.length;
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final len = min(a.length, b.length);
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA <= 1e-9 || normB <= 1e-9) return 0;
    return (dot / (sqrt(normA) * sqrt(normB))).clamp(-1.0, 1.0).toDouble();
  }

  double _mean(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _stddev(List<double> values) {
    if (values.length < 2) return 0;
    final mean = _mean(values);
    final variance =
        values.fold<double>(
          0,
          (sum, value) => sum + pow(value - mean, 2).toDouble(),
        ) /
        values.length;
    return sqrt(variance);
  }
}

class _VoiceProfile {
  const _VoiceProfile({required this.sampleCount, required this.vector});

  final int sampleCount;
  final List<double> vector;
}
