import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/voice/wake_phrase_matcher.dart';

void main() {
  group('WakePhraseMatcher full transcript', () {
    test('accepts exact and close Жанар variants', () {
      final cases = <String>[
        'жанарым',
        'жанарим',
        'жанарум',
        'janarym',
        'zhanarym',
        'джанарым',
        'женарым',
        'женарим',
        'zhanarim',
        'эй жанарым',
        'жанарим слушай',
        'жанар давай',
      ];

      for (final value in cases) {
        final match = WakePhraseMatcher.match(value);
        expect(
          WakePhraseMatcher.isAccepted(match),
          isTrue,
          reason: 'expected accepted for "$value": ${match.reason}',
        );
      }
    });

    test('keeps short or unrelated words below accept threshold', () {
      final cases = <String>['жан', 'жана', 'жанат', 'жанболат', 'привет'];

      for (final value in cases) {
        final match = WakePhraseMatcher.match(value);
        expect(
          WakePhraseMatcher.isAccepted(match),
          isFalse,
          reason: 'expected rejected for "$value": ${match.reason}',
        );
      }
    });
  });

  group('WakePhraseMatcher partial transcript', () {
    test('accepts close partial Жанар roots', () {
      final cases = <String>['жанар', 'джанар', 'женар', 'zhanar'];

      for (final value in cases) {
        final match = WakePhraseMatcher.match(value, isPartial: true);
        expect(
          WakePhraseMatcher.isAccepted(match),
          isTrue,
          reason: 'expected partial accept for "$value": ${match.reason}',
        );
      }
    });

    test('does not accept ambiguous short partials', () {
      final cases = <String>['жан', 'жана'];

      for (final value in cases) {
        final match = WakePhraseMatcher.match(value, isPartial: true);
        expect(
          WakePhraseMatcher.isAccepted(match),
          isFalse,
          reason: 'expected partial reject for "$value": ${match.reason}',
        );
      }
    });
  });

  group('WakePhraseMatcher stripping', () {
    test('removes canonical and fuzzy wake forms from text', () {
      expect(
        WakePhraseMatcher.stripWakeWords('женарим включи режим маршрута'),
        'включи режим маршрута',
      );
      expect(
        WakePhraseMatcher.stripWakeWords('эй жанарым прочитай текст'),
        'эй прочитай текст',
      );
      expect(
        WakePhraseMatcher.stripWakeWords('zhan a rym что впереди'),
        'что впереди',
      );
    });
  });
}
