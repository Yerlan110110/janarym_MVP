import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidRuntimeService {
  AndroidRuntimeService._();

  static const MethodChannel _channel = MethodChannel(
    'janarym/runtime_service',
  );

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> start({String reason = 'runtime_start'}) async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('start', {
        'reason': reason,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> stop({String reason = 'runtime_stop'}) async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('stop', {
        'reason': reason,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isRunning() async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isRunning');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
