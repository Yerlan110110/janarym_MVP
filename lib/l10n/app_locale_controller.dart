import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage { ru, kk }

extension AppLanguageX on AppLanguage {
  static const Locale _ruLocale = Locale('ru');
  static const Locale _kkLocale = Locale('kk');
  static const String _prefsKey = 'app_language_code';

  Locale get locale => this == AppLanguage.kk ? _kkLocale : _ruLocale;

  static AppLanguage fromLocale(Locale locale) {
    final code = locale.languageCode.toLowerCase();
    if (code == 'kk') {
      return AppLanguage.kk;
    }
    return AppLanguage.ru;
  }

  static AppLanguage fromStored(String? value) {
    switch ((value ?? '').toLowerCase()) {
      case 'kk':
        return AppLanguage.kk;
      case 'ru':
      default:
        return AppLanguage.ru;
    }
  }

  String get storageValue => name;

  static String get prefsKey => _prefsKey;
}

class AppLocaleController extends ChangeNotifier {
  AppLocaleController();

  AppLanguage _language = AppLanguage.ru;
  bool _initialized = false;
  bool _hasSavedSelection = false;

  AppLanguage get language => _language;
  Locale get locale => _language.locale;
  bool get isInitialized => _initialized;
  bool get hasSavedSelection => _hasSavedSelection;
  bool get requiresExplicitSelection => _initialized && !_hasSavedSelection;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(AppLanguageX.prefsKey);
    if (stored != null && stored.isNotEmpty) {
      _language = AppLanguageX.fromStored(stored);
      _hasSavedSelection = true;
    } else {
      final systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
      _language = AppLanguageX.fromLocale(systemLocale);
      _hasSavedSelection = false;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language && _hasSavedSelection) return;
    _language = language;
    _hasSavedSelection = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppLanguageX.prefsKey, language.storageValue);
  }
}
