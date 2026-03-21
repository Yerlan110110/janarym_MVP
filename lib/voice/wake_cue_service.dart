import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WakeCueService {
  static const MethodChannel _channel = MethodChannel('janarym/wake_cue');

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> preload() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('preload');
    } catch (_) {}
  }

  Future<void> play() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('play');
    } catch (_) {}
  }
}
