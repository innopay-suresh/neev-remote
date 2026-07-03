#include "privacy_mode.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

HWND g_blank = nullptr;
bool g_blocked = false;

HWND CreateBlankWindow() {
  static bool registered = false;
  const wchar_t* cls = L"NeevPrivacyBlank";
  if (!registered) {
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = cls;
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
    registered = true;
  }
  int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
  int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
  // Layered + transparent = opaque black locally but click-through (injected
  // remote input passes to the real windows behind it); no-activate keeps
  // keyboard focus on the real app.
  HWND hwnd = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
          WS_EX_NOACTIVATE,
      cls, L"", WS_POPUP, x, y, w, h, nullptr, nullptr,
      GetModuleHandleW(nullptr), nullptr);
  if (!hwnd) return nullptr;
  SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
  // Exclude from screen capture (Win10 2004+): the captured stream shows the
  // real desktop behind the black overlay.
  typedef BOOL(WINAPI * SetAffFn)(HWND, DWORD);
  auto fn = (SetAffFn)GetProcAddress(GetModuleHandleW(L"user32.dll"),
                                     "SetWindowDisplayAffinity");
  if (fn) fn(hwnd, 0x00000011 /* WDA_EXCLUDEFROMCAPTURE */);
  ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  return hwnd;
}

void SetPrivacy(bool on) {
  if (on) {
    if (!g_blank) g_blank = CreateBlankWindow();
    if (!g_blocked) g_blocked = (BlockInput(TRUE) != 0);
  } else {
    if (g_blocked) {
      BlockInput(FALSE);
      g_blocked = false;
    }
    if (g_blank) {
      DestroyWindow(g_blank);
      g_blank = nullptr;
    }
  }
}

}  // namespace

void PrivacyModeForceOff() { SetPrivacy(false); }

void RegisterPrivacyMode(flutter::FlutterEngine* engine) {
  static std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "neev_remote/privacy",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "setPrivacy") {
          bool on = false;
          if (auto* b = std::get_if<bool>(call.arguments())) on = *b;
          SetPrivacy(on);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
