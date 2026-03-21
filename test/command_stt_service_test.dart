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
}
