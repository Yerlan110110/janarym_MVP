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

  AppLanguage get language => _language;
  Locale get locale => _language.locale;
  bool get isInitialized => _initialized;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(AppLanguageX.prefsKey);
    if (stored != null && stored.isNotEmpty) {
      _language = AppLanguageX.fromStored(stored);
    } else {
      final systemLocale = WidgetsBinding.instance.platformDispatcher.locale;
      _language = AppLanguageX.fromLocale(systemLocale);
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppLanguageX.prefsKey, language.storageValue);
  }
}
