import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/input_event.dart';

/// Flip to true to log the input event stream (down/up/cancel + a 1/s move
/// heartbeat) to the console / app log. Used to pinpoint whether the *viewer*
/// stops sending after a click vs. the host stops injecting.
const bool kLogRemoteInput = false;

/// Renders the remote video stream and, unless [viewOnly], captures local
/// mouse + keyboard input and forwards it as normalized [InputEvent]s via
/// [onInput].
class RemoteViewWidget extends StatefulWidget {
  final MediaStream? remoteStream;
  final bool isConnected;
  final bool viewOnly;
  /// The remote host's OS ('windows' | 'macos' | 'linux'), used to translate
  /// the primary command modifier (⌘ ↔ Ctrl) so copy/paste etc. work cross-OS.
  final String? hostOs;
  final void Function(InputEvent event)? onInput;

  /// UAC overlay: when the host's UAC secure desktop is active, [uacFrame] is a
  /// PNG of it (the normal video goes black during UAC). Taps are forwarded via
  /// [onUacClick] (normalized 0..1, button 0=left).
  final bool uacActive;
  final Uint8List? uacFrame;
  final int uacW;
  final int uacH;
  /// 0 = UAC prompt, 1 = login screen, 2 = locked session.
  final int uacKind;

  /// When true, the remote video fills the window (cover); else it's letterboxed
  /// (contain / fit).
  final bool fillMode;

  /// When true, keyboard input is NOT forwarded to the remote and the video
  /// won't steal focus — so an in-app text field (chat, transmit-login dialog)
  /// can receive typing.
  final bool inputPaused;
  final void Function(int button, double x, double y)? onUacClick;
  final VoidCallback? onUacApprove;
  final VoidCallback? onUacDecline;

  const RemoteViewWidget({
    super.key,
    this.remoteStream,
    this.isConnected = false,
    this.viewOnly = false,
    this.hostOs,
    this.onInput,
    this.uacActive = false,
    this.uacFrame,
    this.uacW = 0,
    this.uacH = 0,
    this.uacKind = 0,
    this.fillMode = false,
    this.inputPaused = false,
    this.onUacClick,
    this.onUacApprove,
    this.onUacDecline,
  });

  @override
  State<RemoteViewWidget> createState() => _RemoteViewWidgetState();
}

class _RemoteViewWidgetState extends State<RemoteViewWidget>
    with WidgetsBindingObserver {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final FocusNode _focusNode = FocusNode();
  bool _initialized = false;
  int _activeButton = 0;
  bool _buttonHeld = false;
  Offset _lastLocal = Offset.zero;
  final Stopwatch _moveClock = Stopwatch()..start();
  int _lastMoveMs = -100;
  // Move-heartbeat logging.
  int _moveCount = 0;
  int _lastHeartbeatMs = 0;
  // Blank-video watchdog: if no frame is decoded shortly after the stream is
  // attached, re-attach it to kick the renderer (fixes intermittent blank /
  // white video, seen Windows→Windows).
  Timer? _frameWatchdog;
  int _frameKicks = 0;

  // Real pixel size of the current UAC frame, decoded from the bytes so the
  // letterbox aspect is always correct even if the size (`A`) message was missed
  // (e.g. the viewer connected after the secure desktop was already up).
  int _uacImgW = 0;
  int _uacImgH = 0;
  int _uacFrameHash = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initRenderer();
    if (widget.uacFrame != null) _measureUacFrame(widget.uacFrame!);
  }

  // Decode just enough to read the frame's width/height. Cheap at UAC frame
  // rates (~1/s) and skipped when the bytes are unchanged.
  Future<void> _measureUacFrame(Uint8List bytes) async {
    final hash = Object.hash(bytes.length, bytes.isEmpty ? 0 : bytes[0]);
    if (hash == _uacFrameHash) return;
    _uacFrameHash = hash;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final w = frame.image.width, h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (mounted && (w != _uacImgW || h != _uacImgH)) {
        setState(() {
          _uacImgW = w;
          _uacImgH = h;
        });
      }
    } catch (_) {}
  }

  Future<void> _initRenderer() async {
    await _renderer.initialize();
    if (widget.remoteStream != null) {
      _renderer.srcObject = widget.remoteStream;
      _startFrameWatchdog();
    }
    if (mounted) setState(() => _initialized = true);
  }

  /// Re-attaches the stream if no frame has been decoded a couple seconds after
  /// it was attached. `videoWidth` stays 0 until the first decoded frame, so it
  /// is a reliable "is anything rendering" signal. Re-attaching kicks a stuck
  /// renderer; gives up after a few tries once frames flow.
  void _startFrameWatchdog() {
    _frameWatchdog?.cancel();
    _frameKicks = 0;
    _frameWatchdog = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted || !_initialized || widget.remoteStream == null) {
        t.cancel();
        return;
      }
      if (_renderer.videoWidth > 0) {
        t.cancel(); // frames are flowing
        return;
      }
      if (_frameKicks >= 6) {
        t.cancel();
        return;
      }
      _frameKicks++;
      _renderer.srcObject = null;
      _renderer.srcObject = widget.remoteStream;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!_initialized) return;
    // The macOS WebRTC renderer can hang the app when the window is minimized
    // (hidden) while a texture is still attached. Detach the stream while
    // hidden/paused and re-attach on resume. `inactive` (mere focus loss) is
    // deliberately ignored so the video doesn't blank when you click away.
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Releasing here is essential: minimizing/restoring or maximizing the
        // window can interrupt the pointer stream with NO PointerUp/Cancel, so
        // a held button would stay stuck-down on the host and freeze its mouse.
        _releaseHeld();
        _renderer.srcObject = null;
        break;
      case AppLifecycleState.inactive:
        _releaseHeld();
        break;
      case AppLifecycleState.resumed:
        _renderer.srcObject = widget.remoteStream;
        if (widget.remoteStream != null) _startFrameWatchdog();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Sends a button-up for any held button so the host never gets stuck with a
  /// pressed button (which freezes its cursor).
  void _releaseHeld() {
    if (!_buttonHeld) return;
    _buttonHeld = false;
    _emit(InputEvent.button(_activeButton, false));
    _log('lifecycle release btn=$_activeButton');
  }

  @override
  void didUpdateWidget(RemoteViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When input is paused (chat / dialog opened) release the video's focus so
    // the text field can receive typing; re-grab it when unpaused.
    if (widget.inputPaused != oldWidget.inputPaused) {
      if (widget.inputPaused) {
        _focusNode.unfocus();
      } else if (_controlEnabled) {
        _focusNode.requestFocus();
      }
    }
    if (widget.remoteStream != oldWidget.remoteStream) {
      _renderer.srcObject = widget.remoteStream;
      if (widget.remoteStream != null) _startFrameWatchdog();
    }
    if (widget.uacFrame != null && widget.uacFrame != oldWidget.uacFrame) {
      _measureUacFrame(widget.uacFrame!);
    }
  }

  @override
  void dispose() {
    _frameWatchdog?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _renderer.srcObject = null;
    _renderer.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _controlEnabled => !widget.viewOnly && widget.onInput != null;

  /// Maps a pointer position within [size] to normalized 0..1 coordinates over
  /// the letterboxed ("contain") video rect. Returns null if outside the video.
  Offset? _normalize(Offset local, Size size) {
    final vw = _renderer.videoWidth.toDouble();
    final vh = _renderer.videoHeight.toDouble();
    if (vw <= 0 || vh <= 0 || size.width <= 0 || size.height <= 0) {
      // Fall back to the whole widget area.
      return Offset(local.dx / size.width, local.dy / size.height);
    }
    final ar = vw / vh;
    double dispW, dispH;
    if (size.width / size.height > ar) {
      dispH = size.height;
      dispW = dispH * ar;
    } else {
      dispW = size.width;
      dispH = dispW / ar;
    }
    final left = (size.width - dispW) / 2;
    final top = (size.height - dispH) / 2;
    final nx = (local.dx - left) / dispW;
    final ny = (local.dy - top) / dispH;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
    return Offset(nx, ny);
  }

  int _buttonFrom(int buttons) {
    if (buttons & kSecondaryButton != 0) return 1;
    if (buttons & kMiddleMouseButton != 0) return 2;
    return 0;
  }

  void _emit(InputEvent e) => widget.onInput?.call(e);

  void _onPointerDown(PointerDownEvent e, Size size) {
    _lastLocal = e.localPosition;
    final pos = _normalize(e.localPosition, size);
    if (pos == null) return;
    // Only request focus when we don't already have it. Calling requestFocus on
    // every click rebuilds the Focus subtree, and on macOS that rebuild drops
    // the MouseRegion's hover tracking — so move/hover events silently stop
    // after the first click and the remote cursor appears frozen.
    if (!widget.inputPaused && !_focusNode.hasFocus) _focusNode.requestFocus();
    _activeButton = _buttonFrom(e.buttons);
    _buttonHeld = true;
    _emit(InputEvent.move(pos.dx, pos.dy));
    _emit(InputEvent.button(_activeButton, true, x: pos.dx, y: pos.dy));
    _log('DOWN btn=$_activeButton');
  }

  // Hover events fire ONLY when no mouse button is pressed. So if we still
  // believe a button is held when a hover arrives, a PointerUp was missed
  // (macOS can swallow it during a Space/window switch or cursor-shape change)
  // and the host is stuck dragging — looking frozen. Release it immediately so
  // the cursor unfreezes the instant the user moves.
  void _onPointerHover(Offset local, Size size) {
    if (_buttonHeld) {
      _buttonHeld = false;
      final pos = _normalize(local, size);
      _emit(InputEvent.button(_activeButton, false, x: pos?.dx, y: pos?.dy));
      _log('HOVER while held -> released stuck btn=$_activeButton');
    }
    _onPointerMove(local, size);
  }

  void _onPointerMove(Offset local, Size size) {
    _lastLocal = local;
    // Throttle to ~60/s so fast movement doesn't flood the data channel.
    final now = _moveClock.elapsedMilliseconds;
    if (now - _lastMoveMs < 16) return;
    _lastMoveMs = now;
    final pos = _normalize(local, size);
    if (pos != null) {
      _emit(InputEvent.move(pos.dx, pos.dy));
      _heartbeat(now);
    }
  }

  void _onPointerUp(Offset local, Size size) {
    _lastLocal = local;
    // Always release the active button, even if the pointer was lifted outside
    // the video rect — otherwise the host's button stays stuck down.
    if (!_buttonHeld) return;
    _buttonHeld = false;
    final pos = _normalize(local, size);
    _emit(InputEvent.button(_activeButton, false, x: pos?.dx, y: pos?.dy));
    _log('UP btn=$_activeButton');
  }

  // macOS can deliver a PointerCancel instead of a PointerUp after a click
  // (gesture arena / cursor changes). If we ignore it the host's button stays
  // pressed, turning every later move into a drag and freezing the cursor.
  void _onPointerCancel(Size size) {
    if (!_buttonHeld) return;
    _buttonHeld = false;
    final pos = _normalize(_lastLocal, size);
    _emit(InputEvent.button(_activeButton, false, x: pos?.dx, y: pos?.dy));
    _log('CANCEL btn=$_activeButton (released)');
  }

  void _heartbeat(int now) {
    _moveCount++;
    if (now - _lastHeartbeatMs >= 1000) {
      _log('moves sent in last ~1s: $_moveCount');
      _moveCount = 0;
      _lastHeartbeatMs = now;
    }
  }

  void _log(String msg) {
    if (kLogRemoteInput) debugPrint('[remote-input] $msg');
  }

  // HID usages for the primary command modifiers.
  static const int _hidCtrlL = 0xE0, _hidCtrlR = 0xE4;
  static const int _hidGuiL = 0xE3, _hidGuiR = 0xE7; // ⌘ on macOS, Win key

  /// Translates the viewer's primary command modifier to the host's so that
  /// shortcuts like copy/paste work across platforms. macOS uses ⌘ (GUI);
  /// Windows/Linux use Ctrl. Same-family pairs pass through unchanged.
  int _remapModifier(int hid) {
    final host = widget.hostOs;
    if (host == null) return hid;
    final viewerIsMac = defaultTargetPlatform == TargetPlatform.macOS;
    final hostIsMac = host == 'macos';
    if (viewerIsMac == hostIsMac) return hid; // same family, no swap
    if (viewerIsMac && !hostIsMac) {
      // ⌘ on this Mac → Ctrl on the Windows/Linux host.
      if (hid == _hidGuiL) return _hidCtrlL;
      if (hid == _hidGuiR) return _hidCtrlR;
    } else {
      // Ctrl on this Windows/Linux box → ⌘ on the macOS host.
      if (hid == _hidCtrlL) return _hidGuiL;
      if (hid == _hidCtrlR) return _hidGuiR;
    }
    return hid;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      _emit(InputEvent.wheel(e.scrollDelta.dx, e.scrollDelta.dy));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (widget.inputPaused) return KeyEventResult.ignored;
    final usage = event.physicalKey.usbHidUsage;
    if (usage == 0) return KeyEventResult.ignored;
    // Flutter packs the USB HID *usage page* into the upper 16 bits (the
    // keyboard page is 0x07, so e.g. KeyA == 0x00070004). Every native host
    // maps the bare usage code, so strip the page before sending — otherwise
    // no key ever matches and typing silently does nothing.
    final hid = _remapModifier(usage & 0xFFFF);
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      // Forward auto-repeat as additional downs so holding a key repeats it.
      _emit(InputEvent.key(hid, true));
      return KeyEventResult.handled;
    } else if (event is KeyUpEvent) {
      _emit(InputEvent.key(hid, false));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isConnected) {
      return _buildStatus('Waiting for connection...', Icons.hourglass_empty);
    }
    if (widget.remoteStream == null) {
      return _buildStatus('No video stream', Icons.videocam_off);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          Widget video = _initialized
              ? RTCVideoView(
                  _renderer,
                  objectFit: widget.fillMode
                      ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
                      : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  mirror: false,
                )
              : const ColoredBox(color: Colors.black);

          if (_controlEnabled) {
            video = Focus(
              focusNode: _focusNode,
              autofocus: !widget.inputPaused,
              canRequestFocus: !widget.inputPaused,
              onKeyEvent: _onKey,
              child: Listener(
                // opaque so pointer down/up fire over the (non-hit-testable)
                // video texture — otherwise only hover worked and clicks were
                // silently dropped.
                behavior: HitTestBehavior.opaque,
                onPointerHover: (e) => _onPointerHover(e.localPosition, size),
                onPointerDown: (e) => _onPointerDown(e, size),
                onPointerMove: (e) => _onPointerMove(e.localPosition, size),
                onPointerUp: (e) => _onPointerUp(e.localPosition, size),
                onPointerCancel: (_) => _onPointerCancel(size),
                onPointerSignal: _onPointerSignal,
                child: MouseRegion(
                  // Show the local arrow over the remote video. The Windows
                  // desktop capturer does NOT include the host cursor, so
                  // hiding the local one (SystemMouseCursors.none) left the
                  // Windows viewer with no visible cursor at all — you couldn't
                  // see where you were pointing or aim clicks.
                  cursor: SystemMouseCursors.basic,
                  // The cursor leaving the video (incl. when the window is
                  // minimized) releases any held button so the host never gets
                  // stuck — desktop lifecycle events are unreliable on minimize.
                  onExit: (_) => _releaseHeld(),
                  child: video,
                ),
              ),
            );
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              video,
              if (widget.viewOnly)
                Positioned(
                  top: AppSpacing.md,
                  right: AppSpacing.md,
                  child: _viewOnlyBadge(),
                ),
              // UAC overlay: the host's secure desktop, on top of the (black)
              // video while a UAC prompt is up. Taps map to normalized coords
              // and are injected into consent.exe on the host.
              if (widget.uacActive && widget.uacFrame != null)
                _buildUacOverlay(size),
            ],
          );
        },
      ),
    );
  }

  // The host's secure desktop (UAC) shown over the video. The desktop image
  // fills the WHOLE area (so the centered UAC dialog is as large and visible as
  // possible), with the slim control bar floated over the empty top strip — the
  // dialog is vertically centered on the primary monitor, so the bar never
  // covers it. Taps on the image map to normalized coords and are injected on
  // the host's secure desktop; typing is forwarded through the normal keyboard
  // path (the SYSTEM helper injects it there too), so a standard-user credential
  // prompt can be filled.
  Widget _buildUacOverlay(Size size) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF0B1220),
        child: Stack(
          children: [
            Positioned.fill(child: _uacImageArea()),
            Positioned(top: 0, left: 0, right: 0, child: _uacControlBar()),
          ],
        ),
      ),
    );
  }

  // Slim informational bar: the user interacts with the real dialog directly —
  // click Yes/No in the view below, or click the password field and type. Kept
  // to a single centered line so the dialog below stays as large as possible.
  Widget _uacControlBar() {
    // Label + colour by which secure screen this is, so the operator knows what
    // they're looking at (a UAC request vs the Windows sign-in / lock screen).
    final (IconData icon, String title, Color color) = switch (widget.uacKind) {
      1 => (
        Icons.login,
        'Windows sign-in screen — click a user, then use "Login" in the toolbar '
            'to send the username & password, or type directly.',
        const Color(0xFF1E293B),
      ),
      2 => (
        Icons.lock,
        'Locked — click the account, then use "Login" in the toolbar to send the '
            'password (or type it), and press Enter.',
        const Color(0xFF1E293B),
      ),
      _ => (
        Icons.admin_panel_settings_outlined,
        'User Account Control — approve/decline below, or use "Login" in the '
            'toolbar to send admin credentials.',
        AppColors.accentDark,
      ),
    };
    return Material(
      color: color.withValues(alpha: 0.97),
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // The secure-desktop frame, letterboxed within whatever space is left below
  // the control bar. Taps forward normalized coords to the host.
  Widget _uacImageArea() {
    final png = widget.uacFrame!;
    // Prefer the real decoded size; fall back to the size message, then 16:9.
    final iw = _uacImgW > 0
        ? _uacImgW.toDouble()
        : (widget.uacW > 0 ? widget.uacW.toDouble() : 16.0);
    final ih = _uacImgH > 0
        ? _uacImgH.toDouble()
        : (widget.uacH > 0 ? widget.uacH.toDouble() : 9.0);
    final ar = iw / ih;
    return LayoutBuilder(
      builder: (context, c) {
        final area = c.biggest;
        double dispW, dispH;
        if (area.width / area.height > ar) {
          dispH = area.height;
          dispW = dispH * ar;
        } else {
          dispW = area.width;
          dispH = dispW / ar;
        }
        final left = (area.width - dispW) / 2;
        final top = (area.height - dispH) / 2;
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              width: dispW,
              height: dispH,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) {
                  final nx = (e.localPosition.dx / dispW).clamp(0.0, 1.0);
                  final ny = (e.localPosition.dy / dispH).clamp(0.0, 1.0);
                  widget.onUacClick?.call(0, nx, ny);
                },
                // The rect already has the image's aspect ratio, so fill = no
                // distortion and tap math maps 1:1 to the host desktop.
                child:
                    Image.memory(png, fit: BoxFit.fill, gaplessPlayback: true),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _viewOnlyBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.visibility, size: 16, color: Colors.white),
          SizedBox(width: AppSpacing.xs),
          Text('View Only', style: TextStyle(color: Colors.white, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildStatus(String message, IconData icon) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.lg),
            Text(message,
                style:
                    AppTypography.body.copyWith(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
