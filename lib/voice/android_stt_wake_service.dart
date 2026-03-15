import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SttWakeEvent {
  const SttWakeEvent({
    required this.status,
    this.text,
    this.locale,
    this.errorCode,
    this.errorName,
    this.reason,
  });

  final String status;
  final String? text;
  final String? locale;
  final int? errorCode;
  final String? errorName;
  final String? reason;

  factory SttWakeEvent.fromMap(Map<dynamic, dynamic> map) {
    return SttWakeEvent(
      status: (map['status'] ?? 'idle').toString(),
      text: map['text']?.toString(),
      locale: map['locale']?.toString(),
      errorCode: map['errorCode'] is int
          ? map['errorCode'] as int
          : int.tryParse(map['errorCode']?.toString() ?? ''),
      errorName: map['errorName']?.toString(),
      reason: map['reason']?.toString(),
    );
  }
}

class AndroidSttWakeService {
  AndroidSttWakeService({this.debugLogs = false});

  final bool debugLogs;

  static const MethodChannel _channel = MethodChannel('janarym/stt_wake');
  static const EventChannel _events = EventChannel('janarym/stt_wake/events');

  Stream<SttWakeEvent>? _sharedStream;

  Future<void> initialize({
    required String language,
    required bool partialResults,
    bool preferOffline = true,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _channel.invokeMethod<void>('initialize', {
      'language': language,
      'partialResults': partialResults,
      'preferOffline': preferOffline,
    });
  }

  Future<bool> isAvailable() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final value = await _channel.invokeMethod<bool>('isAvailable');
    return value ?? false;
  }

  Future<void> start() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _channel.invokeMethod<void>('start');
  }

  Future<void> stop() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _channel.invokeMethod<void>('stop');
  }

  Future<void> cancel() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _channel.invokeMethod<void>('cancel');
  }

  Future<void> dispose() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    await _channel.invokeMethod<void>('dispose');
  }

  Future<Map<String, dynamic>> status() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return <String, dynamic>{'status': 'unavailable'};
    }
    final raw = await _channel.invokeMethod<dynamic>('status');
    if (raw is Map) {
      return raw.map<String, dynamic>(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return <String, dynamic>{'status': 'unknown'};
  }

  Stream<SttWakeEvent> get events {
    return _sharedStream ??= _events
        .receiveBroadcastStream()
        .map((event) => SttWakeEvent.fromMap(event as Map<dynamic, dynamic>))
        .asBroadcastStream();
  }
}
