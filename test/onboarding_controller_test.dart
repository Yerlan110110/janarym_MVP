import 'package:flutter_test/flutter_test.dart';
import 'package:janarym_app2/personalization/data/personalization_database.dart';
import 'package:janarym_app2/personalization/personalization_controller.dart';
import 'package:janarym_app2/personalization/personalization_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('PersonalizationController onboarding', () {
    late PersonalizationRepository repository;
    late PersonalizationController controller;

    setUp(() {
      final db = PersonalizationDatabase(
        dbFactory: databaseFactoryFfi,
        databaseName:
            'test_onboarding_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      repository = PersonalizationRepository(database: db);
      controller = PersonalizationController(repository: repository);
    });

    tearDown(() async {
      await repository.close();
      controller.dispose();
    });

    test('starts as required and supports pause/resume', () async {
      await controller.init();
      expect(controller.onboardingRequired, isTrue);
      expect(controller.onboardingStep, 0);

      await controller.startOrResumeOnboarding();
      expect(controller.onboardingActive, isTrue);

      controller.pauseOnboarding();
      expect(controller.onboardingActive, isFalse);
      expect(controller.onboardingPaused, isTrue);
    });

    test('completes 10 questions and marks profile complete', () async {
      await controller.init();
      await controller.startOrResumeOnboarding();

      final answers = [
        'Ерлан',
        'русский',
        'коротко',
        'прямой',
        'чаще',
        'боюсь перекрестков',
        'да',
        'безопаснее',
        'да',
        'позже',
      ];

      for (final answer in answers) {
        await controller.answerOnboardingQuestion(answer);
      }

      expect(controller.onboardingRequired, isFalse);
      expect(controller.snapshot.profile.onboardingCompleted, isTrue);
      expect(controller.snapshot.profile.onboardingStep, 10);
      expect(controller.snapshot.fears, isNotEmpty);
    });

    test('restartOnboardingFromScratch resets progress and answers', () async {
      await controller.init();
      await controller.startOrResumeOnboarding();
      await controller.answerOnboardingQuestion('Ерлан');
      await controller.answerOnboardingQuestion('русский');
      await controller.answerOnboardingQuestion('коротко');

      expect(controller.onboardingStep, 3);
      expect(controller.snapshot.answers.length, greaterThanOrEqualTo(3));

      await controller.restartOnboardingFromScratch();

      expect(controller.onboardingRequired, isTrue);
      expect(controller.onboardingStep, 0);
      expect(controller.onboardingActive, isTrue);
      expect(controller.snapshot.answers, isEmpty);
      expect(controller.snapshot.profile.displayName, isEmpty);
    });
  });
}
