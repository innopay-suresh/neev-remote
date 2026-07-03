#include "input_injector.h"

#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <X11/keysym.h>

#include <cstdint>

namespace {

// X11 display shared across injected events. Opened lazily.
Display* g_display = nullptr;

Display* display() {
  if (!g_display) g_display = XOpenDisplay(nullptr);
  return g_display;
}

// Reads a numeric field that may arrive as either float or int.
double get_num(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return 0.0;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  return 0.0;
}

int get_int(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_INT)
    return static_cast<int>(fl_value_get_int(v));
  return 0;
}

bool get_bool(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(v);
}

// USB HID usage → X11 keysym (lowercase / un-shifted). 0 when unmapped.
KeySym hid_to_keysym(int usage) {
  if (usage >= 0x04 && usage <= 0x1D) return XK_a + (usage - 0x04);
  if (usage >= 0x1E && usage <= 0x26) return XK_1 + (usage - 0x1E);
  if (usage == 0x27) return XK_0;
  if (usage >= 0x3A && usage <= 0x45) return XK_F1 + (usage - 0x3A);
  switch (usage) {
    case 0x28: return XK_Return;
    case 0x29: return XK_Escape;
    case 0x2A: return XK_BackSpace;
    case 0x2B: return XK_Tab;
    case 0x2C: return XK_space;
    case 0x2D: return XK_minus;
    case 0x2E: return XK_equal;
    case 0x2F: return XK_bracketleft;
    case 0x30: return XK_bracketright;
    case 0x31: return XK_backslash;
    case 0x33: return XK_semicolon;
    case 0x34: return XK_apostrophe;
    case 0x35: return XK_grave;
    case 0x36: return XK_comma;
    case 0x37: return XK_period;
    case 0x38: return XK_slash;
    case 0x39: return XK_Caps_Lock;
    case 0x49: return XK_Insert;
    case 0x4A: return XK_Home;
    case 0x4B: return XK_Prior;
    case 0x4C: return XK_Delete;
    case 0x4D: return XK_End;
    case 0x4E: return XK_Next;
    case 0x4F: return XK_Right;
    case 0x50: return XK_Left;
    case 0x51: return XK_Down;
    case 0x52: return XK_Up;
    case 0xE0: return XK_Control_L;
    case 0xE1: return XK_Shift_L;
    case 0xE2: return XK_Alt_L;
    case 0xE3: return XK_Super_L;
    case 0xE4: return XK_Control_R;
    case 0xE5: return XK_Shift_R;
    case 0xE6: return XK_Alt_R;
    case 0xE7: return XK_Super_R;
    default: return 0;
  }
}

void handle_inject(FlValue* args) {
  Display* d = display();
  if (!d || !args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return;
  FlValue* kv = fl_value_lookup_string(args, "k");
  if (!kv || fl_value_get_type(kv) != FL_VALUE_TYPE_STRING) return;
  const char* kind = fl_value_get_string(kv);

  if (g_strcmp0(kind, "mv") == 0) {
    int screen = DefaultScreen(d);
    int w = DisplayWidth(d, screen);
    int h = DisplayHeight(d, screen);
    int x = static_cast<int>(get_num(args, "x") * w);
    int y = static_cast<int>(get_num(args, "y") * h);
    XTestFakeMotionEvent(d, screen, x, y, CurrentTime);
  } else if (g_strcmp0(kind, "btn") == 0) {
    int b = get_int(args, "b");
    bool down = get_bool(args, "d");
    unsigned int xbtn = b == 1 ? 3 : (b == 2 ? 2 : 1);  // left=1,middle=2,right=3
    XTestFakeButtonEvent(d, xbtn, down ? True : False, CurrentTime);
  } else if (g_strcmp0(kind, "whl") == 0) {
    double dy = get_num(args, "dy");
    if (dy != 0.0) {
      unsigned int btn = dy > 0 ? 5 : 4;  // 5=down, 4=up
      XTestFakeButtonEvent(d, btn, True, CurrentTime);
      XTestFakeButtonEvent(d, btn, False, CurrentTime);
    }
    double dx = get_num(args, "dx");
    if (dx != 0.0) {
      unsigned int btn = dx > 0 ? 7 : 6;  // 7=right, 6=left
      XTestFakeButtonEvent(d, btn, True, CurrentTime);
      XTestFakeButtonEvent(d, btn, False, CurrentTime);
    }
  } else if (g_strcmp0(kind, "key") == 0) {
    KeySym sym = hid_to_keysym(get_int(args, "u"));
    if (sym == 0) return;
    KeyCode code = XKeysymToKeycode(d, sym);
    if (code == 0) return;
    XTestFakeKeyEvent(d, code, get_bool(args, "d") ? True : False, CurrentTime);
  }
  XFlush(d);
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(method_call), "inject") == 0) {
    handle_inject(fl_method_call_get_args(method_call));
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    fl_method_call_respond(method_call, response, nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(method_call, response, nullptr);
  }
}

}  // namespace

void register_input_injector(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "neev_remote/input", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
  // Intentionally leak `channel`: it must live for the process lifetime.
}
