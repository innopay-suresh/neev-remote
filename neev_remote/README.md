# Neev Remote (Flutter)

Cross-platform remote-desktop **viewer + host in one app** (AnyDesk/TeamViewer
style), built with Flutter + `flutter_webrtc`. It reuses the **existing Go
signaling server** in this repo (`server/`) — no server changes required.

## Status

| Capability | State |
|---|---|
| Signaling (register / connect / offer / answer / ICE) | ✅ wired to Go server protocol |
| Argon2id auth (matches `agent/auth/auth.go`) | ✅ verified compatible |
| Host: screen capture via `getDisplayMedia` | ✅ implemented (desktop + web) |
| Host: WebRTC offer + multi-viewer support | ✅ |
| Viewer: answer + live video render + stats | ✅ |
| **Input injection (control the remote)** | ✅ mouse + keyboard, all 3 desktop OSes |
| Clipboard / file transfer / multi-monitor picker | ⏳ later |

### Remote control (Milestone 2)

The viewer captures mouse + keyboard over the video and sends them on the WebRTC
control data channel; the host injects them natively. Events use **normalized
coordinates** (host maps to its own resolution) and **USB-HID key usages** (each
host maps to its native virtual key), so viewer and host need not agree on
resolution or keyboard layout.

| Host OS | Backend | File |
|---|---|---|
| Windows | `SendInput` | `windows/runner/input_injector.cpp` |
| macOS | `CGEvent` | `macos/Runner/InputInjector.swift` |
| Linux (X11) | `XTest` | `linux/runner/input_injector.cc` |

Dart side: `lib/data/services/input_event.dart` (protocol),
`input_injector.dart` (host MethodChannel client), capture in
`presentation/widgets/remote_view_widget.dart`. Toggle **Settings → View Only**
to disable control. Wayland input injection is not covered (X11 only).

**Permissions the host must grant for control to work:**
- **macOS:** System Settings → Privacy & Security → **Accessibility** (to post
  events) and **Screen Recording** (to capture). Both prompt on first use.
- **Windows:** none for standard apps; UAC-elevated target windows need the app
  run as administrator.
- **Linux:** an **X11** session (not Wayland) with the XTest extension.

## Architecture

```
        Viewer (controller)                 Host (agent)
        ─────────────────────               ────────────────────
        connectToHost()                     startHosting()
          │  register? no                     │  register (Argon2id hash)
          │  sendConnect(id, password) ──┐    │
          │                              ▼    ▼
          │                       ┌──────────────────┐
          │                       │  Go signaling     │  server/signaling/hub.go
          │                       │  hub (WebSocket)  │
          │                       └──────────────────┘
          │  ◄── offer ── (host is the WebRTC offerer; owns screen track + data channel)
          └── answer ──►
              ◄── ICE ──►
        RTCVideoView  ◄═════ DTLS-SRTP video ═════  getDisplayMedia()
```

Key source files (`lib/`):
- `data/services/auth_service.dart` — Argon2id hashing in the Go wire format.
- `data/services/signaling_service.dart` — WebSocket envelope matching `hub.go`.
- `data/services/screen_capture_service.dart` — real `desktopCapturer` + `getDisplayMedia`.
- `data/services/webrtc_service.dart` — peer connection, ICE-candidate queueing, stats.
- `data/services/remote_service.dart` — **orchestrator** tying it all together for both roles.
- `presentation/pages/agent_page.dart` / `viewer_page.dart` — UI driven by `RemoteService`.

## Running it end-to-end

### 1. Start the Go signaling server (from repo root)
```bash
docker compose up -d           # brings up the server + Redis + (optional) TURN
# server listens on ws://localhost:8080/ws by default
```

### 2. Point the app at your relay
In the app's **Settings → Relay URL** (persisted via shared_preferences):
- local dev: `ws://localhost:8080/ws`
- production: `wss://your-domain/ws`

### 3. Run two instances (host + viewer)
```bash
# Desktop (needs Xcode+CocoaPods on macOS, or Visual Studio on Windows):
flutter run -d macos          # or: -d windows / -d linux

# Web (works anywhere, good for quick testing — getDisplayMedia shows a picker):
flutter run -d chrome
```
- Instance A → **Agent** tab → **Start Agent** → shows Agent ID + password.
- Instance B → **Viewer** tab → enter that ID + password → **Connect**.

macOS hosts will get a one-time **Screen Recording** permission prompt the first
time capture starts.

## Build outputs
```bash
flutter build macos        # .app          (requires full Xcode + CocoaPods)
flutter build windows      # .exe + dlls   (requires Visual Studio C++ desktop)
flutter build linux        # bundle
flutter build web          # static site for the web viewer/client
```

> This dev machine only had Xcode Command-Line-Tools (no full Xcode/CocoaPods),
> so native macOS/iOS builds can't be produced here — but `flutter build web`
> compiles the entire Dart codebase and passes.
