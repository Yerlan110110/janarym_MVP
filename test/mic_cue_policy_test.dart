import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/voice/mic_cue_policy.dart';

void main() {
  group('MicCuePolicy', () {
    test('plays cue only after accepted wake word', () {
      expect(shouldPlayMicCue(MicCueEvent.wakeAccepted), isTrue);
    });

    test('suppresses cues for startup and non-wake listening flows', () {
      expect(shouldPlayMicCue(MicCueEvent.startupArm), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.commandListeningStarted), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.commandListeningStopped), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.followUpStart), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.routeConfirmationStart), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.directFallbackStart), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.manualStop), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.voiceEnrollmentAction), isFalse);
    });

    test('suppresses cues for UI-only actions', () {
      expect(shouldPlayMicCue(MicCueEvent.uiPanelOpened), isFalse);
      expect(shouldPlayMicCue(MicCueEvent.uiPanelClosed), isFalse);
    });
  });
}
