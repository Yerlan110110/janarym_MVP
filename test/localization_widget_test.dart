import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('updates UI text when language changes', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final controller = AppLocaleController();
    await controller.init();

    await tester.pumpWidget(
      AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return MaterialApp(
            locale: controller.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                return Text(AppLocalizations.of(context).modeNavigation);
              },
            ),
          );
        },
      ),
    );

    expect(find.text('Режим маршрута'), findsOneWidget);

    await controller.setLanguage(AppLanguage.kk);
    await tester.pumpAndSettle();

    expect(find.text('Маршрут режимі'), findsOneWidget);
  });
}
