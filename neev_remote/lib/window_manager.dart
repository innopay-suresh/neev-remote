import 'package:flutter/material.dart';

// Stub for platforms where window_manager isn't available
// On desktop, this will be replaced with the real window_manager package

class WindowOptions {
  final Size? size;
  final Size? minimumSize;
  final bool? center;
  final Color? backgroundColor;
  final bool? skipTaskbar;
  final TitleBarStyle? titleBarStyle;
  final String? title;

  const WindowOptions({
    this.size,
    this.minimumSize,
    this.center,
    this.backgroundColor,
    this.skipTaskbar,
    this.titleBarStyle,
    this.title,
  });
}

class TitleBarStyle {
  static const normal = TitleBarStyle._('normal');
  const TitleBarStyle._(this._);
  final String _;
}

class _WindowManagerStub {
  Future<void> ensureInitialized() async {}
  
  Future<void> waitUntilReadyToShow(WindowOptions options, Future<void> Function() callback) async {
    // Just run the callback - on web there's no window to show
    await callback();
  }
  
  Future<void> show() async {}
  Future<void> focus() async {}
}

final windowManager = _WindowManagerStub();

Future<void> initWindowManager() async {
  // Stub does nothing - real implementation would initialize window manager
}