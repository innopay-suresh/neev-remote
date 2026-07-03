#ifndef RUNNER_KEYBOARD_HOOK_H_
#define RUNNER_KEYBOARD_HOOK_H_

#include <flutter/flutter_engine.h>

// Registers the "neev_remote/keyhook" MethodChannel. When capture is enabled
// (setCapture:true) a low-level keyboard hook grabs keystrokes while THIS app is
// the foreground window and queues them (as USB HID usage codes) for the Dart
// side to drain and forward to the remote — so OS-reserved combos (Win+R,
// Alt+Tab, …) reach the remote instead of the local machine. Suppression only
// happens while our window is focused, so clicking away always restores the
// local keyboard.
void RegisterKeyboardHook(flutter::FlutterEngine* engine);

#endif  // RUNNER_KEYBOARD_HOOK_H_
