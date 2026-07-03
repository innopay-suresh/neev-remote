import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Host-side privacy mode: blanks the physical screen (still visible to the
/// remote viewer) and blocks local input. Windows only; no-op elsewhere.
class PrivacyMode {
  static const MethodChannel _channel = MethodChannel('neev_remote/privacy');

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<void> set(bool on) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('setPrivacy', on);
    } catch (_) {}
  }
}
