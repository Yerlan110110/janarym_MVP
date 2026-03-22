import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/runtime/feature_flags.dart';
import 'package:janarym_app2/runtime/mode_orchestrator.dart';

void main() {
  group('RuntimeFeatureFlags', () {
    setUp(() {
      dotenv.clean();
      dotenv.loadFromString(envString: 'TEST_FLAG=1');
    });

    test('anti fraud is enabled by default and find is not advertised', () {
      final flags = RuntimeFeatureFlags.fromEnv();

      expect(flags.antiFraudEnabled, isTrue);
      expect(flags.enabledModes(), isNot(contains('find')));
    });

    test('mode orchestrator does not expose public find mode', () {
      final flags = RuntimeFeatureFlags.fromEnv();
      final orchestrator = ModeOrchestrator(flags: flags);

      expect(orchestrator.availableModes(), isNot(contains(JanarymMode.find)));
    });
  });
}
