import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/anti_fraud/currency_check_analyzer.dart';

void main() {
  group('CurrencyCheckAnalyzer', () {
    test('flags souvenir markers from OCR as counterfeit', () {
      final result = CurrencyCheckAnalyzer.analyze(
        ocrText: '5000 НЕ ЯВЛЯЕТСЯ ПЛАТЕЖНЫМ СРЕДСТВОМ сувенирная банкнота',
      );

      expect(result.verdict, CurrencyCheckVerdict.counterfeit);
      expect(result.nominal, '5000');
      expect(result.reasons, isNotEmpty);
      expect(result.source, 'ocr');
    });

    test('parses authentic verdict from visual json', () {
      final result = CurrencyCheckAnalyzer.analyze(
        visualResponse:
            '{"verdict":"authentic","nominal":"10000","reason":"security features visible"}',
      );

      expect(result.verdict, CurrencyCheckVerdict.authentic);
      expect(result.nominal, '10000');
      expect(result.source, 'vision_json');
    });

    test('returns uncertain when evidence is insufficient', () {
      final result = CurrencyCheckAnalyzer.analyze(
        ocrText: 'тенге',
        visualResponse: 'image too blurry to verify',
      );

      expect(result.verdict, CurrencyCheckVerdict.uncertain);
    });
  });
}
