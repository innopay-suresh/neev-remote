#ifndef RUNNER_PRIVACY_MODE_H_
#define RUNNER_PRIVACY_MODE_H_

#include <flutter/flutter_engine.h>

// Registers the "neev_remote/privacy" MethodChannel. setPrivacy:true blanks the
// host's PHYSICAL screen (a click-through black overlay excluded from screen
// capture, so the remote viewer still sees the real desktop) and blocks the
// host's local keyboard/mouse; setPrivacy:false restores both. Windows host.
void RegisterPrivacyMode(flutter::FlutterEngine* engine);

// Force privacy off (e.g. when the session ends), regardless of channel state.
void PrivacyModeForceOff();

#endif  // RUNNER_PRIVACY_MODE_H_
