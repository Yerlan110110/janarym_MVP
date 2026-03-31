import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/l10n/app_locale_controller.dart';
import 'package:janarym_app2/main.dart';
import 'package:janarym_app2/runtime/mode_orchestrator.dart';
import 'package:janarym_app2/widgets/mode_picker_sheet.dart';

void main() {
  ModeDescriptor descriptorFor(AssistantMode mode) {
    switch (mode) {
      case AssistantMode.textReader:
        return const ModeDescriptor(
          mode: JanarymMode.text_reader,
          contextKey: 'text_reader',
          ui: ModeUiIndicator(
            labelRu: 'Чтение текста',
            labelKk: 'Оқу',
            shortRu: 'Текст',
            shortKk: 'Мәтін',
            icon: Icons.text_snippet_rounded,
            accentColor: Color(0xFFA78BFA),
          ),
          perception: ModePerceptionFilter(),
          prompts: ModePromptProfile(
            blindRu: '',
            blindKk: '',
            visionRu: '',
            visionKk: '',
          ),
        );
      case AssistantMode.memory:
        return const ModeDescriptor(
          mode: JanarymMode.memory,
          contextKey: 'memory',
          ui: ModeUiIndicator(
            labelRu: 'Память',
            labelKk: 'Жад',
            shortRu: 'Память',
            shortKk: 'Жад',
            icon: Icons.bookmark_rounded,
            accentColor: Color(0xFF60A5FA),
          ),
          perception: ModePerceptionFilter(),
          prompts: ModePromptProfile(
            blindRu: '',
            blindKk: '',
            visionRu: '',
            visionKk: '',
          ),
        );
      default:
        return const ModeDescriptor(
          mode: JanarymMode.home,
          contextKey: 'home',
          ui: ModeUiIndicator(
            labelRu: 'Обычный',
            labelKk: 'Қалыпты',
            shortRu: 'Дом',
            shortKk: 'Үй',
            icon: Icons.home_rounded,
            accentColor: Color(0xFF34D399),
          ),
          perception: ModePerceptionFilter(),
          prompts: ModePromptProfile(
            blindRu: '',
            blindKk: '',
            visionRu: '',
            visionKk: '',
          ),
        );
    }
  }

  testWidgets('renders glass panel and dispatches taps', (tester) async {
    AssistantMode? selectedMode;
    String? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF020617),
          body: Center(
            child: SizedBox(
              width: 380,
              child: ModePickerSheet<AssistantMode>(
                menuItems: const [
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.general,
                    label: 'Обычный',
                    icon: Icons.home_rounded,
                  ),
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.textReader,
                    label: 'Чтение текста',
                    icon: Icons.text_snippet_rounded,
                  ),
                  ModeMenuEntry<AssistantMode>(
                    actionId: 'voice_enrollment',
                    label: 'Голосовой профиль',
                    icon: Icons.record_voice_over_rounded,
                  ),
                ],
                currentMode: AssistantMode.general,
                appLanguage: AppLanguage.ru,
                modeDescriptorFor: descriptorFor,
                onModeSelected: (mode) => selectedMode = mode,
                onActionSelected: (actionId) => selectedAction = actionId,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Режимы'), findsOneWidget);
    expect(
      find.text('Экран остаётся видимым, выберите режим одним жестом'),
      findsOneWidget,
    );

    await tester.tap(find.text('Чтение текста'));
    await tester.pumpAndSettle();
    expect(selectedMode, AssistantMode.textReader);

    await tester.tap(find.text('Голосовой профиль'));
    await tester.pumpAndSettle();
    expect(selectedAction, 'voice_enrollment');
  });

  testWidgets('fits long labels on narrow layouts without overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF020617),
          body: Center(
            child: SizedBox(
              width: 320,
              child: ModePickerSheet<AssistantMode>(
                menuItems: const [
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.general,
                    label: 'Обычный',
                    icon: Icons.home_rounded,
                  ),
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.navigation,
                    label: 'Маршрутизатор',
                    icon: Icons.alt_route_rounded,
                  ),
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.textReader,
                    label: 'Чтение текста',
                    icon: Icons.text_snippet_rounded,
                  ),
                  ModeMenuEntry<AssistantMode>(
                    mode: AssistantMode.antiFraud,
                    label: 'Антимошеничество',
                    icon: Icons.shield_rounded,
                  ),
                ],
                currentMode: AssistantMode.general,
                appLanguage: AppLanguage.ru,
                modeDescriptorFor: descriptorFor,
                onModeSelected: (_) {},
                onActionSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
