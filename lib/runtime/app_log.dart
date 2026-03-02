import 'package:flutter/foundation.dart';

void appLog(String message) {
  if (kReleaseMode) return;
  debugPrint(message);
}
