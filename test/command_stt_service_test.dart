import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/voice/command_stt_service.dart';

void main() {
  group('shouldTranscribeRecordedCommand', () {
    test('forces transcription when requested even without VAD hit', () {
      expect(
        shouldTranscribeRecordedCommand(
          skipNoVoice: true,
          hadVoice: false,
          listenMs: 1200,
          minForceMs: 7000,
          alwaysTranscribe: true,
        ),
        isTrue,
      );
    });

    test('keeps existing VAD gating when force flag is off', () {
      expect(
        shouldTranscribeRecordedCommand(
          skipNoVoice: true,
          hadVoice: false,
          listenMs: 1200,
          minForceMs: 7000,
          alwaysTranscribe: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldAutoStopCommandListening', () {
    test('does not auto-stop on silence in press-to-stop mode', () {
      expect(
        shouldAutoStopCommandListening(
          stopOnSilence: false,
          voiceDetected: true,
          listenedMs: 3200,
          silenceMs: 2600,
          minListenMs: 1500,
          silenceHoldMs: 2400,
          maxNoSpeechMs: null,
        ),
        isFalse,
      );
    });

    test('keeps existing silence auto-stop in default mode', () {
      expect(
        shouldAutoStopCommandListening(
          stopOnSilence: true,
          voiceDetected: true,
          listenedMs: 3200,
          silenceMs: 2600,
          minListenMs: 1500,
          silenceHoldMs: 2400,
          maxNoSpeechMs: null,
        ),
        isTrue,
      );
    });

    test('can still stop after prolonged no-speech when configured', () {
      expect(
        shouldAutoStopCommandListening(
          stopOnSilence: true,
          voiceDetected: false,
          listenedMs: 5000,
          silenceMs: 5000,
          minListenMs: 1500,
          silenceHoldMs: 2400,
          maxNoSpeechMs: 4000,
        ),
        isTrue,
      );
    });
  });
}
