#include "flutter_window.h"

#include <windows.h>

#include <cstdio>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "input_injector.h"
#include "keyboard_hook.h"
#include "privacy_mode.h"

// Minimal diagnostic log (headless mode only) so a login-screen launch can be
// debugged without a visible window. Shares the helper's ProgramData folder.
static void HostLog(const char* msg) {
  ::CreateDirectoryW(L"C:\\ProgramData\\NeevRemote", nullptr);
  FILE* f = nullptr;
  if (_wfopen_s(&f, L"C:\\ProgramData\\NeevRemote\\host.log", L"a+") != 0 ||
      !f) {
    return;
  }
  SYSTEMTIME st;
  ::GetLocalTime(&st);
  fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] %s\n", st.wYear, st.wMonth,
          st.wDay, st.wHour, st.wMinute, st.wSecond, msg);
  fclose(f);
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool headless)
    : project_(project), headless_(headless) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  if (headless_) HostLog("service-host: creating Flutter view controller");

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    if (headless_) {
      HostLog(
          "service-host: FlutterViewController failed (engine/view null) — "
          "likely GPU/ANGLE init on the login desktop");
    }
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterInputInjector(flutter_controller_->engine());
  RegisterKeyboardHook(flutter_controller_->engine());
  RegisterPrivacyMode(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // In headless (login-screen) mode never show the window — the engine + Dart
  // isolate run, driving WebRTC/signaling, with no visible surface.
  if (!headless_) {
    flutter_controller_->engine()->SetNextFrameCallback([&]() {
      this->Show();
    });
  } else {
    HostLog("service-host: engine up, running headless (window hidden)");
  }

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
