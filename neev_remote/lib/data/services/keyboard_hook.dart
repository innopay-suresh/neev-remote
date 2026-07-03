import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';

/// Windows-only low-level keyboard capture. When enabled, the native runner
/// grabs OS-reserved key combos (Win+R, Alt+Tab, …) that Flutter never receives
/// while the app is focused, and this drains them to [onKey] for forwarding to
/// the remote. No-op on other platforms (the native channel isn't there).
class KeyboardHook {
  KeyboardHook(this.onKey);

  final void Function(int hidUsage, bool down) onKey;
  static const MethodChannel _channel = MethodChannel('neev_remote/keyhook');
  Timer? _poll;
  bool _on = false;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  Future<void> setCapture(bool on) async {
    if (!supported || on == _on) return;
    _on = on;
    try {
      await _channel.invokeMethod('setCapture', on);
    } catch (_) {}
    _poll?.cancel();
    if (on) {
      _poll = Timer.periodic(const Duration(milliseconds: 12), (_) => _drain());
    }
  }

  Future<void> _drain() async {
    try {
      final res = await _channel.invokeMethod('drain');
      if (res is List) {
        for (final e in res) {
          if (e is Map) {
            final u = e['u'] as int?;
            final d = e['d'] as bool?;
            if (u != null && d != null) onKey(u, d);
          }
        }
      }
    } catch (_) {}
  }

  void dispose() {
    _poll?.cancel();
    if (_on) {
      _on = false;
      try {
        _channel.invokeMethod('setCapture', false);
      } catch (_) {}
    }
  }
}
