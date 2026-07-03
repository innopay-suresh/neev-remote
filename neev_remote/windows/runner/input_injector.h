#ifndef RUNNER_INPUT_INJECTOR_H_
#define RUNNER_INPUT_INJECTOR_H_

#include <flutter/flutter_engine.h>

// Registers the "neev_remote/input" MethodChannel that injects remote
// mouse/keyboard events into the local OS via SendInput.
void RegisterInputInjector(flutter::FlutterEngine* engine);

#endif  // RUNNER_INPUT_INJECTOR_H_
