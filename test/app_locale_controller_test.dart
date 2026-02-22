import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('uses system locale when there is no saved language', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.localeTestValue = const Locale('kk', 'KZ');

    final controller = AppLocaleController();
    await controller.init();

    expect(controller.language, AppLanguage.kk);
    expect(controller.locale, const Locale('kk'));

    addTearDown(binding.platformDispatcher.clearLocaleTestValue);
  });

  test('uses saved language when available', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppLanguageX.prefsKey: 'ru',
    });

    final controller = AppLocaleController();
    await controller.init();

    expect(controller.language, AppLanguage.ru);
    expect(controller.locale, const Locale('ru'));
  });

  test('persists selected language between controller instances', () async {
    final controller = AppLocaleController();
    await controller.init();
    await controller.setLanguage(AppLanguage.kk);

    final nextController = AppLocaleController();
    await nextController.init();

    expect(nextController.language, AppLanguage.kk);
    expect(nextController.locale, const Locale('kk'));
  });
}
