#include "keyboard_hook.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <memory>
#include <mutex>
#include <utility>

namespace {

HHOOK g_hook = nullptr;
bool g_capture = false;
std::mutex g_mutex;
std::deque<std::pair<int, bool>> g_queue;  // (HID usage, isDown)

// Win32 VK -> USB HID usage (keyboard page). Inverse of the host injector's
// HidToVk so a captured key maps back to the same platform-independent code.
int VkToHid(DWORD vk) {
  if (vk >= 'A' && vk <= 'Z') return 0x04 + static_cast<int>(vk - 'A');
  if (vk >= '1' && vk <= '9') return 0x1E + static_cast<int>(vk - '1');
  if (vk == '0') return 0x27;
  if (vk >= VK_F1 && vk <= VK_F12) return 0x3A + static_cast<int>(vk - VK_F1);
  switch (vk) {
    case VK_RETURN: return 0x28;
    case VK_ESCAPE: return 0x29;
    case VK_BACK: return 0x2A;
    case VK_TAB: return 0x2B;
    case VK_SPACE: return 0x2C;
    case VK_OEM_MINUS: return 0x2D;
    case VK_OEM_PLUS: return 0x2E;
    case VK_OEM_4: return 0x2F;
    case VK_OEM_6: return 0x30;
    case VK_OEM_5: return 0x31;
    case VK_OEM_1: return 0x33;
    case VK_OEM_7: return 0x34;
    case VK_OEM_3: return 0x35;
    case VK_OEM_COMMA: return 0x36;
    case VK_OEM_PERIOD: return 0x37;
    case VK_OEM_2: return 0x38;
    case VK_CAPITAL: return 0x39;
    case VK_INSERT: return 0x49;
    case VK_HOME: return 0x4A;
    case VK_PRIOR: return 0x4B;
    case VK_DELETE: return 0x4C;
    case VK_END: return 0x4D;
    case VK_NEXT: return 0x4E;
    case VK_RIGHT: return 0x4F;
    case VK_LEFT: return 0x50;
    case VK_DOWN: return 0x51;
    case VK_UP: return 0x52;
    case VK_LCONTROL: case VK_CONTROL: return 0xE0;
    case VK_LSHIFT: case VK_SHIFT: return 0xE1;
    case VK_LMENU: case VK_MENU: return 0xE2;
    case VK_LWIN: return 0xE3;
    case VK_RCONTROL: return 0xE4;
    case VK_RSHIFT: return 0xE5;
    case VK_RMENU: return 0xE6;
    case VK_RWIN: return 0xE7;
    default: return 0;
  }
}

// True only when our MAIN remote-view window is focused — not a child dialog
// (e.g. the native file picker, class "#32770"), so typing there still works.
bool OurMainWindowForeground() {
  HWND fg = GetForegroundWindow();
  if (!fg) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(fg, &pid);
  if (pid != GetCurrentProcessId()) return false;
  wchar_t cls[64] = {0};
  GetClassNameW(fg, cls, 63);
  return wcscmp(cls, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0;
}

LRESULT CALLBACK LLKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode == HC_ACTION && g_capture) {
    auto* k = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
    // Ignore keys we injected ourselves, and only capture while our window is
    // focused so the user can always click away to regain the local keyboard.
    if (!(k->flags & LLKHF_INJECTED) && OurMainWindowForeground()) {
      bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
      bool up = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
      if (down || up) {
        int hid = VkToHid(k->vkCode);
        if (hid != 0) {
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_queue.emplace_back(hid, down);
            if (g_queue.size() > 256) g_queue.pop_front();  // safety cap
          }
          return 1;  // suppress local handling — the key goes to the remote
        }
      }
    }
  }
  return CallNextHookEx(g_hook, nCode, wParam, lParam);
}

void SetCapture(bool on) {
  g_capture = on;
  if (on && !g_hook) {
    g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, LLKeyboardProc,
                               GetModuleHandleW(nullptr), 0);
  } else if (!on && g_hook) {
    UnhookWindowsHookEx(g_hook);
    g_hook = nullptr;
    std::lock_guard<std::mutex> lock(g_mutex);
    g_queue.clear();
  }
}

flutter::EncodableValue DrainQueue() {
  flutter::EncodableList out;
  std::lock_guard<std::mutex> lock(g_mutex);
  for (auto& e : g_queue) {
    out.push_back(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("u"), flutter::EncodableValue(e.first)},
        {flutter::EncodableValue("d"), flutter::EncodableValue(e.second)},
    }));
  }
  g_queue.clear();
  return flutter::EncodableValue(std::move(out));
}

}  // namespace

void RegisterKeyboardHook(flutter::FlutterEngine* engine) {
  static std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      channel;
  channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "neev_remote/keyhook",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "setCapture") {
          bool on = false;
          if (auto* b = std::get_if<bool>(call.arguments())) on = *b;
          SetCapture(on);
          result->Success();
        } else if (call.method_name() == "drain") {
          result->Success(DrainQueue());
        } else {
          result->NotImplemented();
        }
      });
}
