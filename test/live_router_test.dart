import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/live_router.dart';
import 'package:janarym_app2/logic/command_router.dart';

void main() {
  group('LiveRouter wake handling', () {
    final liveRouter = LiveRouter();
    final commandRouter = CommandRouter();

    test('matches the same aggressive wake variants as the main router', () {
      const phrase = 'женарим что справа';
      expect(liveRouter.hasWakeWord(phrase), isTrue);
      expect(
        commandRouter.stripWakeWords(commandRouter.normalize(phrase)),
        'что справа',
      );
    });

    test('parses live intent after stripping fuzzy wake word', () {
      final command = liveRouter.parse('джанар что впереди');
      expect(command, isNotNull);
      expect(command!.intent, 'vision_ahead');
    });

    test('does not accept weak short prefixes as wake word', () {
      expect(liveRouter.hasWakeWord('жана что впереди'), isFalse);
      expect(liveRouter.parse('жана что впереди'), isNull);
    });
  });
}
