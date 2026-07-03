#ifndef RUNNER_INPUT_INJECTOR_H_
#define RUNNER_INPUT_INJECTOR_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "neev_remote/input" MethodChannel that injects remote
// mouse/keyboard events into the local X11 session via the XTest extension.
void register_input_injector(FlBinaryMessenger* messenger);

#endif  // RUNNER_INPUT_INJECTOR_H_
