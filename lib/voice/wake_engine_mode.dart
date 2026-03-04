import 'package:flutter_dotenv/flutter_dotenv.dart';

enum WakeEngineMode { porcupine, sttAndroid }

WakeEngineMode readWakeEngineModeFromEnv() {
  final raw = (dotenv.env['WAKE_ENGINE'] ?? '').trim().toLowerCase();
  switch (raw) {
    case 'porcupine':
      return WakeEngineMode.porcupine;
    case 'stt_android':
    case 'sttandroid':
    default:
      return WakeEngineMode.sttAndroid;
  }
}
