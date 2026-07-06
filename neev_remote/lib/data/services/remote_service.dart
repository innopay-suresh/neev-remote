import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:pasteboard/pasteboard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import 'auth_service.dart';
import 'clip_agent_bridge.dart';
import 'discovery_model.dart';
import 'file_store.dart';
import 'file_transfer_service.dart';
import 'input_event.dart';
import 'input_injector.dart';
import 'keyboard_hook.dart';
import 'privacy_mode.dart';
import 'screen_capture_service.dart';
import 'signaling_service.dart';
import 'system_command.dart';
import 'uac_bridge.dart';
import 'webrtc_service.dart';

/// Flip to true to emit verbose input/clipboard diagnostics to the console.
/// Off in shipping builds so the log stays quiet.
const bool kRemoteVerboseLog = false;

enum HostStatus { offline, starting, online, error }

enum ViewerStatus { idle, connecting, connected, failed }

/// One in-session chat line.
class ChatMessage {
  final String text;
  final bool mine;
  ChatMessage(this.text, {required this.mine});
}

/// A pending incoming-connection request awaiting the host user's consent.
class ConsentRequest {
  final String controllerId;
  ConsentRequest(this.controllerId);
}

/// Central orchestrator that turns the signaling + WebRTC + capture services
/// into a working remote-desktop session, for both roles:
///
///  * **Host** (agent): registers with the Go signaling server, waits for an
///    incoming `connect`, captures the screen and becomes the WebRTC offerer.
///  * **Viewer** (controller): sends `connect`, answers the host's offer and
///    renders the incoming video stream.
///
/// Both roles use independent signaling connections so a single app instance
/// can host and view at the same time (like AnyDesk).
class RemoteService extends ChangeNotifier {
  RemoteService({this.iceServers = AppConstants.iceServers});

  final List<Map<String, dynamic>> iceServers;

  // ICE servers resolved from the signaling server at connect time. The server
  // advertises STUN + a reachable TURN relay; without this the app would only
  // ever have STUN and could never relay when the direct path is dead.
  List<Map<String, dynamic>>? _resolvedIce;

  /// Fetch ICE servers (STUN + TURN) from the deployment server. Falls back to
  /// the built-in STUN list if the server is unreachable or returns nothing.
  Future<List<Map<String, dynamic>>> _resolveIceServers(String relayUrl) async {
    try {
      final ws = Uri.parse(relayUrl);
      final scheme = (ws.scheme == 'wss' || ws.scheme == 'https') ? 'https' : 'http';
      final base = '$scheme://${ws.authority}';
      final res = await http
          .get(Uri.parse('$base/api/v1/session/ice-servers'))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final list = (body['ice_servers'] as List?)
                ?.whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList() ??
            const [];
        if (list.isNotEmpty) {
          if (kRemoteVerboseLog) {
            debugPrint('[ice] resolved ${list.length} server(s) from $base');
          }
          return list;
        }
      }
    } catch (e) {
      if (kRemoteVerboseLog) debugPrint('[ice] resolve failed, using STUN: $e');
    }
    return iceServers;
  }


  // ---- Host state ----
  SignalingService? _hostSignaling;
  final ScreenCaptureService _capture = ScreenCaptureService();
  final InputInjector _injector = InputInjector();

  // Privileged UAC helper bridge (Windows host only; no-op elsewhere). Streams
  // the secure desktop to viewers and injects their Yes/No into consent.exe.
  final UacBridge _uac = UacBridge();

  // Bidirectional file transfer over the peer's dedicated 'file' data channel.
  late final FileTransferManager _files = FileTransferManager(
    send: _sendFileData,
    buffered: _fileBuffered,
    store: FileStore(),
    onChange: notifyListeners,
    onRequest: _onFileRequest,
    onClipboardFile: _onClipboardFileReceived,
  );

  /// Active + recent file transfers (for the session UI). Clipboard-copied
  /// files ARE shown now — a visible confirmation that the copy went through
  /// (and where it landed) is more reliable than silent CF_HDROP paste.
  List<FileTransfer> get fileTransfers => _files.transfers;

  // A clipboard file finished arriving: put it on THIS machine's clipboard so
  // Ctrl+V pastes the real file. Suppress our own poller so we don't echo it.
  Future<void> _onClipboardFileReceived(String path) async {
    try {
      _clipFileSuppress = 3;
      _lastClipFiles = [path];
      // Prefer the user-context agent (works when the host is SYSTEM); fall back
      // to the in-process clipboard (works when the host is attended).
      final ok = await _clipAgent.writeFiles([path]);
      if (!ok) await Pasteboard.writeFiles([path]);
    } catch (_) {}
  }

  /// Export: send a picked file to the connected peer (viewer→host or
  /// host→viewers).
  Future<FileTransfer?> sendFile(String name, Uint8List bytes) =>
      _files.sendFile(name, bytes);

  /// Import: ask the connected peer to pick a file and send it to us.
  void requestFileFromPeer() {
    _sendFileData(jsonEncode({'k': 'ft', 't': 'request'}));
  }

  /// In-session view-only: when true the viewer watches without sending input
  /// (separate from the persisted view-only setting; either one disables input).
  bool viewerViewOnly = false;
  void setViewOnly(bool value) {
    if (viewerViewOnly == value) return;
    viewerViewOnly = value;
    notifyListeners();
  }

  // The peer sent an import request — open a picker here and send the choice.
  Future<void> _onFileRequest() async {
    try {
      final f = await openFile();
      if (f == null) return;
      final bytes = await f.readAsBytes();
      await _files.sendFile(f.name, bytes);
    } catch (_) {}
  }

  void clearFinishedTransfers() => _files.clearFinished();

  // Route file bytes to the active peer: the host if we're viewing, else all
  // connected viewers if we're hosting.
  void _sendFileData(String data) {
    final v = _viewerPeer;
    if (v != null) {
      v.sendFileData(data);
      return;
    }
    for (final p in _hostPeers.values) {
      p.sendFileData(data);
    }
  }

  int _fileBuffered() => _viewerPeer?.fileChannelBufferedAmount ?? 0;

  // ---- Viewer-side UAC overlay state (driven by host 'uac' messages) ----
  bool uacActive = false;
  Uint8List? uacFrame;
  int uacW = 0;
  int uacH = 0;
  // Which secure desktop is showing: 0=UAC prompt, 1=login screen, 2=locked.
  int uacKind = 0;
  // A secure-desktop frame is base64'd and split into ordered chunks so it fits
  // the WebRTC data-channel per-message limit (a full-res frame base64s to
  // ~300 KB, over the ~256 KB cap, and was being silently dropped). Reassembled
  // here in order; the reliable/ordered channel guarantees no gaps.
  final StringBuffer _uacChunkBuf = StringBuffer();
  int _uacChunkNext = 0;
  int _uacChunkTotal = 0;
  final Map<String, WebRTCService> _hostPeers = {};
  HostStatus _hostStatus = HostStatus.offline;
  String? _agentId;

  // Server-assisted discovery: the relay groups hosts by public IP and tells us
  // our LAN-mates, so discovery works even where UDP broadcast is blocked.
  Timer? _discoverTimer;
  final Map<String, DiscoveredDevice> _serverPeers = {};

  /// Hosts the relay reports on our network (from the last `peers` reply).
  List<DiscoveredDevice> get serverPeers => _serverPeers.values.toList();

  // ---- Incoming-connection consent + per-session permissions (host) --------
  /// When true, an incoming connection prompts the host user (Accept/Dismiss).
  /// Set false for unattended access. The app wires this from settings.
  bool promptOnConnect = true;
  ConsentRequest? _pendingConsent;
  ConsentRequest? get pendingConsent => _pendingConsent;
  // Permissions granted to the current session (host → viewer).
  bool permControl = true;
  bool permClipboard = true;
  bool permFiles = true;
  // Defaults pushed from settings — pre-fill the consent dialog + used when
  // accepting silently (unattended / never-ask).
  bool defaultPermControl = true;
  bool defaultPermClipboard = true;
  bool defaultPermFiles = true;

  /// Host: accept the pending incoming connection with the chosen permissions.
  Future<void> acceptConnection(
      {bool control = true, bool clipboard = true, bool files = true}) async {
    final req = _pendingConsent;
    if (req == null) return;
    permControl = control;
    permClipboard = clipboard;
    permFiles = files;
    _pendingConsent = null;
    notifyListeners();
    await _startHostOffer(req.controllerId);
  }

  /// Host: decline the pending incoming connection.
  void rejectConnection() {
    final req = _pendingConsent;
    if (req == null) return;
    _pendingConsent = null;
    notifyListeners();
    _hostSignaling?.sendBye(req.controllerId);
  }
  String? _password;
  String? _hostError;

  HostStatus get hostStatus => _hostStatus;
  bool get isHosting =>
      _hostStatus == HostStatus.online || _hostStatus == HostStatus.starting;
  String? get agentId => _agentId;
  String? get password => _password;
  String? get hostError => _hostError;
  int get connectedViewers => _hostPeers.length;

  // ---- Viewer state ----
  SignalingService? _viewerSignaling;
  WebRTCService? _viewerPeer;
  ViewerStatus _viewerStatus = ViewerStatus.idle;
  String? _targetId;
  String? _viewerError;

  // Auto-reconnect: after a remote reboot (or any unexpected drop) keep re-dialing
  // the same host for a while. Params persist across disconnectViewer so a retry
  // can reuse them. NOTE: for the host to reappear after a reboot it must be set
  // to auto-start + share on boot (unattended access — a later feature).
  String? _lastRelayUrl;
  String? _lastTargetId;
  String? _lastPassword;
  bool autoReconnect = false;
  Timer? _reconnectTimer;
  int _reconnectTries = 0;

  /// Host monitors available to switch between (viewer side; empty if the host
  /// has a single monitor). Each entry: {'id':..., 'n': name}.
  List<Map<String, String>> hostMonitors = const [];
  String? _remoteHostOs;
  MediaStream? _remoteStream;
  SessionStats _stats = const SessionStats();
  Timer? _statsTimer;

  // ---- Clipboard sync (shared across roles) ----
  Timer? _clipTimer;
  String? _lastClip;
  // Clipboard image sync (chunked, since images are large).
  int _lastClipImgHash = 0;
  int _clipTick = 0;
  final StringBuffer _clipImgBuf = StringBuffer();
  int _clipImgNext = 0;
  int _clipImgTotal = 0;
  // Clipboard FILE sync: copying a file mirrors it to the peer's CLIPBOARD (via
  // a temp file over the reliable file channel), so Ctrl+V on the other machine
  // pastes the actual file.
  List<String> _lastClipFiles = const [];
  int _clipFileSuppress = 0; // ticks to skip re-sending a just-received file
  // User-context clipboard agent (SYSTEM helper): reads/writes the interactive
  // FILE clipboard that a SYSTEM host can't touch itself. Falls back to
  // Pasteboard when absent (attended install).
  final ClipAgentBridge _clipAgent = ClipAgentBridge();

  // ---- Host dead-man's switch: release stuck buttons if input goes silent
  // (viewer minimized / frozen / disconnected) so the host mouse never freezes.
  final Set<int> _heldButtons = {};
  final Stopwatch _inputClock = Stopwatch()..start();
  int _lastInputMs = 0;
  Timer? _hostInputWatchdog;

  // AnyDesk/TeamViewer model: when the SYSTEM helper agent is connected, ALL
  // input is injected by it (it runs at SYSTEM integrity, so UIPI never blocks
  // it — it reaches elevated windows, the UAC secure desktop, and the login
  // screen alike). Our own Medium-integrity injector is only the fallback for
  // when the helper isn't installed/running. [_routeToHelper] latches while a
  // button is held so a drag never splits across the two injectors.
  bool _routeToHelper = false;

  ViewerStatus get viewerStatus => _viewerStatus;
  bool get isViewing =>
      _viewerStatus == ViewerStatus.connecting ||
      _viewerStatus == ViewerStatus.connected;
  String? get targetId => _targetId;
  String? get viewerError => _viewerError;
  /// The remote host's OS ('windows' | 'macos' | 'linux'), learned over the
  /// control channel. Null until the host announces it. Used by the viewer to
  /// translate the primary command modifier across platforms.
  String? get remoteHostOs => _remoteHostOs;
  MediaStream? get remoteStream => _remoteStream;
  SessionStats get stats => _stats;

  // =========================================================================
  // HOST
  // =========================================================================

  /// Starts hosting. Returns the generated/used password so the UI can show it.
  Future<String> startHosting({
    required String relayUrl,
    String? password,
    String? fixedAgentId,
  }) async {
    await stopHosting();
    _resolvedIce = await _resolveIceServers(relayUrl);
    _setupUacBridge();  // Windows host: stream UAC to viewers (no-op elsewhere)

    // Machine-wide identity (multi-user / cross-session): when the SYSTEM helper
    // is installed, it owns a single id + password for the whole machine — every
    // user account shares them, so the box is reachable with the same
    // credentials no matter which user is logged in / active. Falls back to the
    // per-install id + a fresh password when the helper isn't present.
    ({String id, String password})? machine;
    if (_uac.isSupported) {
      machine = await _uac.fetchMachineCreds();
    }

    final pw = (password != null && password.isNotEmpty)
        ? password
        : (machine != null && machine.password.isNotEmpty)
            ? machine.password
            : AuthService.generatePassword();
    _password = pw;
    // Prefer the machine-wide id; else a stable per-install ID (generated once,
    // persisted, reused each launch). Only a reinstall yields a new per-install
    // id; the machine id survives reinstalls (it lives in ProgramData).
    final agentId = fixedAgentId ??
        (machine != null && machine.id.isNotEmpty
            ? machine.id
            : await _persistentAgentId());
    _hostStatus = HostStatus.starting;
    _hostError = null;
    notifyListeners();

    final signaling = SignalingService(
      serverUrl: relayUrl,
      onMessage: _onHostMessage,
      onConnected: () {
        _hostSignaling?.registerHost(
          passwordHash: AuthService.hashPassword(pw),
          agentId: agentId,
          hostname: _hostname(),
          os: _osName(),
          version: AppConstants.appVersion,
        );
      },
      onDisconnected: () {
        if (_hostStatus != HostStatus.offline) {
          _hostStatus = HostStatus.error;
          _hostError = 'Disconnected from signaling server';
          notifyListeners();
        }
      },
    );
    _hostSignaling = signaling;

    try {
      await signaling.connect();
    } catch (e) {
      _hostStatus = HostStatus.error;
      _hostError = 'Cannot reach signaling server: $e';
      notifyListeners();
      rethrow;
    }
    return pw;
  }

  Future<void> stopHosting() async {
    _statsTimerMaybeStop();
    _stopHostInputWatchdog();
    _routeToHelper = false;
    PrivacyMode.set(false); // never leave the host blanked/locked
    for (final peer in _hostPeers.values) {
      await peer.close();
    }
    _hostPeers.clear();
    await _capture.stopCapture();
    await _hostSignaling?.disconnect();
    _hostSignaling = null;
    _agentId = null;
    _discoverTimer?.cancel();
    _discoverTimer = null;
    _serverPeers.clear();
    _hostStatus = HostStatus.offline;
    notifyListeners();
  }

  Future<void> _onHostMessage(SignalingMessage msg) async {
    switch (msg.type) {
      case SignalingMessageType.registered:
        _agentId = msg.payload?['agent_id'] as String?;
        _hostStatus = HostStatus.online;
        _startServerDiscovery();
        notifyListeners();
        break;
      case SignalingMessageType.peers:
        _onServerPeers(msg.payload);
        break;
      case SignalingMessageType.connect:
        // A controller wants in. msg.from is the controller's routing id.
        final controllerId = msg.from;
        if (controllerId == null) break;
        // Attended: ask the host user first (AnyDesk-style). Unattended access
        // (promptOnConnect=false) accepts immediately with full permissions.
        if (promptOnConnect) {
          _pendingConsent = ConsentRequest(controllerId);
          notifyListeners();
        } else {
          // Silent accept (unattended / never-ask) uses the default permissions.
          permControl = defaultPermControl;
          permClipboard = defaultPermClipboard;
          permFiles = defaultPermFiles;
          await _startHostOffer(controllerId);
        }
        break;
      case SignalingMessageType.answer:
        final peer = _hostPeers[msg.from];
        if (peer != null && msg.payload != null) {
          await peer.setRemoteDescription(_sdpFrom(msg.payload));
        }
        break;
      case SignalingMessageType.candidate:
        final peer = _hostPeers[msg.from];
        if (peer != null && msg.payload != null) {
          await peer.addIceCandidate(_candidateFrom(msg.payload));
        }
        break;
      case SignalingMessageType.bye:
        final peer = _hostPeers.remove(msg.from);
        await peer?.close();
        _disablePrivacyIfNoViewers();
        notifyListeners();
        break;
      case SignalingMessageType.error:
        _hostError = msg.error ?? 'Signaling error';
        notifyListeners();
        break;
      default:
        break;
    }
  }

  // Poll the relay for LAN-mates every few seconds while we're registered.
  void _startServerDiscovery() {
    _discoverTimer?.cancel();
    _hostSignaling?.sendDiscover();
    _discoverTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final s = _hostSignaling;
      if (s == null) {
        _discoverTimer?.cancel();
        _discoverTimer = null;
        return;
      }
      s.sendDiscover();
    });
  }

  /// Force an immediate relay discovery poll (the Discovery page refresh button).
  void refreshDiscovery() {
    _serverPeers.clear();
    notifyListeners();
    _hostSignaling?.sendDiscover();
  }

  void _onServerPeers(dynamic payload) {
    if (payload is! Map) return;
    final list = payload['peers'];
    if (list is! List) return;
    final now = DateTime.now();
    final seen = <String>{};
    for (final p in list) {
      if (p is! Map) continue;
      final id = (p['id'] as String?)?.trim() ?? '';
      if (id.isEmpty || id == _agentId) continue;
      seen.add(id);
      final name = (p['hostname'] as String?)?.trim();
      _serverPeers[id] = DiscoveredDevice(
        id: id,
        name: (name == null || name.isEmpty) ? id : name,
        os: (p['os'] as String?) ?? '',
        ip: '',
        lastSeen: now,
      );
    }
    // Drop machines the relay no longer lists (went offline / left the network).
    _serverPeers.removeWhere((id, _) => !seen.contains(id));
    notifyListeners();
  }

  Future<void> _startHostOffer(String controllerId) async {
    // Capture the screen once and reuse the stream across viewers.
    // Cap the resolution: capturing a Retina display at full native pixels
    // (e.g. 2880×1800) produces large frames that add encode + network
    // latency. 1920-wide keeps text readable while noticeably cutting lag.
    final stream = _capture.stream ??
        await _capture.startCapture(fps: 30, maxWidth: 1920, maxHeight: 1200);
    if (stream == null) {
      _hostError = 'Screen capture failed (permission denied?)';
      notifyListeners();
      return;
    }

    final peer = WebRTCService();
    peer.onDataMessage = (raw) => _handleData(raw, isHost: true);
    // Announce our OS (so the viewer can translate ⌘↔Ctrl) and, if there's more
    // than one monitor, the monitor list so the viewer can switch between them.
    peer.onDataChannelOpen = () async {
      peer.sendData(jsonEncode({'k': 'os', 'v': _osName()}));
      try {
        final mons = await _capture.getSources();
        if (mons.length > 1) {
          peer.sendData(jsonEncode({
            'k': 'mons',
            'l': [
              for (final s in mons) {'id': s.id, 'n': s.name}
            ],
          }));
        }
      } catch (_) {}
    };
    peer.onIceCandidate = (c) =>
        _hostSignaling?.sendCandidate(controllerId, _candidateMap(c));
    peer.onConnectionStateChange = (state) {
      if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _hostPeers.remove(controllerId)?.close();
        _disablePrivacyIfNoViewers();
        notifyListeners();
      }
    };
    _hostPeers[controllerId] = peer;

    // Use iceTransportPolicy 'all': direct path for same-network peers (e.g.
    // <->Mac), automatic TURN-relay fallback when no direct path exists (e.g.
    // Win<->Win across AP-isolated clients). Forcing relay broke the working
    // direct paths, so we let ICE choose.
    await peer.initialize(
      iceServers: _resolvedIce ?? iceServers,
      isOfferer: true,
    );
    await peer.addLocalStream(stream);
    final offer = await peer.createOffer();
    _hostSignaling?.sendOffer(controllerId, _sdpMap(offer));
    _ensureClipboardSync();
    _startHostInputWatchdog();
    notifyListeners();
  }

  // =========================================================================
  // VIEWER
  // =========================================================================

  Future<void> connectToHost({
    required String relayUrl,
    required String targetId,
    required String password,
  }) async {
    await disconnectViewer(keepAutoReconnect: true);
    _resolvedIce = await _resolveIceServers(relayUrl);

    // Remember for auto-reconnect.
    _lastRelayUrl = relayUrl;
    _lastTargetId = targetId;
    _lastPassword = password;

    _targetId = targetId;
    _viewerStatus = ViewerStatus.connecting;
    _viewerError = null;
    notifyListeners();

    final signaling = SignalingService(
      serverUrl: relayUrl,
      onMessage: _onViewerMessage,
      onConnected: () {
        // The viewer (controller) does not register; it just requests a peer.
        _viewerSignaling?.sendConnect(targetId, password);
      },
      onDisconnected: () {
        if (_viewerStatus != ViewerStatus.idle) {
          _viewerStatus = ViewerStatus.failed;
          _viewerError = 'Disconnected from signaling server';
          notifyListeners();
          _maybeScheduleReconnect();
        }
      },
    );
    _viewerSignaling = signaling;

    try {
      await signaling.connect();
    } catch (e) {
      _viewerStatus = ViewerStatus.failed;
      _viewerError = 'Cannot reach signaling server: $e';
      notifyListeners();
      _maybeScheduleReconnect();
    }
  }

  /// Sends a remote-control input event to the host. Mouse MOVES go on the
  /// low-latency unreliable channel (stale moves are dropped, so the cursor
  /// doesn't lag); buttons, wheel and keys stay on the reliable channel so they
  /// are never lost or reordered.
  void sendViewerInput(InputEvent event) {
    if (event.kind == 'mv') {
      _viewerPeer?.sendCursor(event.encode());
    } else {
      _viewerPeer?.sendData(event.encode());
    }
  }

  /// Sends a system key combo to the host by explicit HID usage codes (e.g.
  /// [0xE3, 0x15] = Win+R). Used for shortcuts the LOCAL OS would otherwise
  /// intercept (Win+*, Alt+Tab, …). Codes are sent verbatim — no ⌘↔Ctrl remap
  /// and independent of the local keyboard layout/brand. Press in order,
  /// release in reverse.
  Future<void> sendKeyCombo(List<int> hidUsages) async {
    for (final u in hidUsages) {
      sendViewerInput(InputEvent.key(u, true));
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    for (final u in hidUsages.reversed) {
      sendViewerInput(InputEvent.key(u, false));
    }
  }

  Future<void> disconnectViewer({bool keepAutoReconnect = false}) async {
    // A user-initiated disconnect cancels any pending auto-reconnect.
    if (!keepAutoReconnect) {
      autoReconnect = false;
      _reconnectTimer?.cancel();
    }
    if (keyboardCapture) {
      keyboardCapture = false;
      _keyHook.setCapture(false);
    }
    _statsTimerMaybeStop();
    final id = _targetId;
    if (id != null) _viewerSignaling?.sendBye(id);
    await _viewerPeer?.close();
    _viewerPeer = null;
    await _viewerSignaling?.disconnect();
    _viewerSignaling = null;
    _remoteStream = null;
    _targetId = null;
    _stats = const SessionStats();
    _viewerStatus = ViewerStatus.idle;
    notifyListeners();
    if (keepAutoReconnect) _maybeScheduleReconnect();
  }

  /// Viewer: reboot the remote host and keep re-dialing until it's back.
  void rebootHost() {
    _viewerPeer?.sendData(jsonEncode({'k': 'cmd', 'c': 'reboot'}));
    autoReconnect = true;
    _reconnectTries = 0;
  }

  // ---- Actions menu (viewer → host), AnyDesk-parity ------------------------

  /// Viewer: lock the remote machine (its sign-in screen).
  void lockRemote() =>
      _viewerPeer?.sendData(jsonEncode({'k': 'cmd', 'c': 'lock'}));

  /// Viewer: sign the remote user out (log off).
  void signOutRemote() =>
      _viewerPeer?.sendData(jsonEncode({'k': 'cmd', 'c': 'logoff'}));

  /// Viewer: send Ctrl+Alt+Del to the remote (routed through its SYSTEM helper
  /// so the real Secure Attention Sequence fires, not an ignored synthetic one).
  void sendCtrlAltDel() =>
      _viewerPeer?.sendData(jsonEncode({'k': 'cmd', 'c': 'sas'}));

  /// Viewer: paste the local clipboard text into the remote's focused field
  /// ("Insert from clipboard"). Types via the host helper so it reaches secure
  /// / elevated windows too.
  Future<bool> insertClipboardToRemote() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      if (text.isEmpty) return false;
      transmitText(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Viewer: grab the current remote frame as a PNG and save it to Downloads.
  /// Returns the saved path, or null if unavailable.
  Future<String?> captureRemoteScreenshot() async {
    try {
      final track = _remoteStream?.getVideoTracks();
      if (track == null || track.isEmpty) return null;
      final buffer = await track.first.captureFrame();
      final bytes = buffer.asUint8List();
      if (bytes.isEmpty) return null;
      final ts = DateTime.now();
      final name =
          'neev-screenshot-${ts.year}${_two(ts.month)}${_two(ts.day)}-'
          '${_two(ts.hour)}${_two(ts.minute)}${_two(ts.second)}.png';
      final store = FileStore();
      if (!store.supported) return null;
      return await store.saveToDownloads(name, bytes);
    } catch (_) {
      return null;
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  // Re-dial the same host after an unexpected drop while auto-reconnect is on.
  void _maybeScheduleReconnect() {
    if (!autoReconnect) return;
    if (_lastRelayUrl == null || _lastTargetId == null || _lastPassword == null) {
      return;
    }
    if (_reconnectTimer?.isActive ?? false) return;
    _reconnectTries++;
    if (_reconnectTries > 60) {
      autoReconnect = false; // give up after ~5 min
      return;
    }
    _reconnectTimer = Timer(const Duration(seconds: 5), () async {
      if (!autoReconnect || _viewerStatus == ViewerStatus.connected) return;
      try {
        await connectToHost(
          relayUrl: _lastRelayUrl!,
          targetId: _lastTargetId!,
          password: _lastPassword!,
        );
      } catch (_) {
        _maybeScheduleReconnect();
      }
    });
  }

  // Host: run a command sent by the controlling viewer.
  void _onHostCommand(Map<String, dynamic> m) {
    switch (m['c']) {
      case 'reboot':
        rebootMachine();
        break;
      case 'privacy':
        PrivacyMode.set(m['on'] == true);
        break;
      case 'lock':
        lockMachine();
        break;
      case 'logoff':
        signOutMachine();
        break;
      case 'sas': // Ctrl+Alt+Del via the SYSTEM helper (SAS).
        _uac.sendSas();
        break;
    }
  }

  // Safety: never leave the host blanked + input-blocked with no one watching.
  /// Lock this device when the last viewer disconnects (Settings → Security).
  bool lockOnSessionEnd = false;

  void _disablePrivacyIfNoViewers() {
    if (_hostPeers.isEmpty) {
      PrivacyMode.set(false);
      if (lockOnSessionEnd) lockMachine();
    }
  }

  // ---- In-session chat (works both directions over the control channel) ----
  final List<ChatMessage> chatMessages = [];
  int unreadChat = 0;

  /// True when there's a peer to chat with (viewing a host, or hosting with at
  /// least one connected viewer).
  bool get hasChatPeer => _viewerPeer != null || _hostPeers.isNotEmpty;

  /// Send a chat line to the connected peer (host<->viewer).
  void sendChat(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    chatMessages.add(ChatMessage(t, mine: true));
    final msg = jsonEncode({'k': 'chat', 't': t});
    if (_viewerPeer != null) {
      _viewerPeer!.sendData(msg);
    } else {
      for (final p in _hostPeers.values) {
        p.sendData(msg);
      }
    }
    notifyListeners();
  }

  void markChatRead() {
    if (unreadChat == 0) return;
    unreadChat = 0;
    notifyListeners();
  }

  void _onChat(Map<String, dynamic> m) {
    final t = (m['t'] as String?)?.trim();
    if (t == null || t.isEmpty) return;
    chatMessages.add(ChatMessage(t, mine: false));
    unreadChat++;
    notifyListeners();
  }

  /// Viewer: transmit text to be typed into the host's currently-focused field
  /// (e.g. a UAC / Windows login credential prompt). [tab] presses Tab after
  /// (to jump to the next field), [enter] submits. The host injects it through
  /// the SYSTEM helper so it reaches the secure desktop / elevated windows.
  void transmitText(String text, {bool tab = false, bool enter = false}) {
    if (text.isEmpty && !tab && !enter) return;
    _viewerPeer?.sendData(jsonEncode(
        {'k': 'type', 't': text, 'tab': tab, 'enter': enter}));
  }

  /// Viewer: toggle privacy mode on the host (blank its screen + block its
  /// local input while you control it).
  bool privacyMode = false;
  void setPrivacyMode(bool on) {
    privacyMode = on;
    _viewerPeer?.sendData(jsonEncode({'k': 'cmd', 'c': 'privacy', 'on': on}));
    notifyListeners();
  }

  // Windows viewer: seamless capture of OS-reserved key combos (Win+R, Alt+Tab…)
  // and forward them to the host. Only active while the app is focused.
  late final KeyboardHook _keyHook =
      KeyboardHook((hid, down) => sendViewerInput(InputEvent.key(hid, down)));
  bool keyboardCapture = false;
  bool get keyboardCaptureSupported => KeyboardHook.supported;
  void setKeyboardCapture(bool on) {
    keyboardCapture = on;
    _keyHook.setCapture(on);
    notifyListeners();
  }

  /// Temporarily silence the native key hook + input forwarding while an in-app
  /// text field needs the keyboard (chat, transmit-login dialog), WITHOUT
  /// changing the user's keyboardCapture preference. Restores it on release.
  void pauseKeyboardCapture(bool pause) {
    _keyHook.setCapture(pause ? false : keyboardCapture);
  }

  /// Viewer: ask the host to stream a different monitor.
  void setMonitor(String id) {
    _viewerPeer?.sendData(jsonEncode({'k': 'setmon', 'id': id}));
  }

  // ---- Stream quality presets (viewer-selected → host encoder) -------------
  // 0 = best quality, 1 = balanced, 2 = best performance.
  int _streamQuality = 1;
  int get streamQuality => _streamQuality;

  /// Viewer: pick a quality preset; the host caps its encoder accordingly.
  void setStreamQuality(int preset) {
    _streamQuality = preset.clamp(0, 2);
    notifyListeners();
    _viewerPeer?.sendData(jsonEncode({'k': 'quality', 'p': _streamQuality}));
  }

  // Host: map the viewer's preset to encoder limits and apply to every viewer.
  void _applyHostQuality(int preset) {
    int kbps;
    int fps;
    double scale;
    switch (preset) {
      case 0: // best quality
        kbps = 4000;
        fps = 30;
        scale = 1.0;
        break;
      case 2: // best performance
        kbps = 600;
        fps = 15;
        scale = 1.5;
        break;
      default: // balanced
        kbps = 1500;
        fps = 25;
        scale = 1.0;
    }
    for (final p in _hostPeers.values) {
      p.applyQuality(maxBitrateKbps: kbps, maxFps: fps, scaleDown: scale);
    }
  }

  // Host: re-capture the chosen monitor and hot-swap the video track on every
  // connected viewer (no renegotiation).
  Future<void> _switchMonitor(String? id) async {
    if (id == null) return;
    try {
      final stream = await _capture.startCapture(
          sourceId: id, fps: 30, maxWidth: 1920, maxHeight: 1200);
      final track = stream?.getVideoTracks().isNotEmpty == true
          ? stream!.getVideoTracks().first
          : _capture.videoTrack;
      if (track == null) return;
      for (final peer in _hostPeers.values) {
        await peer.replaceVideoTrack(track);
      }
    } catch (_) {}
  }

  Future<void> _onViewerMessage(SignalingMessage msg) async {
    switch (msg.type) {
      case SignalingMessageType.connect:
        // Server confirmed the request was accepted; await the host's offer.
        break;
      case SignalingMessageType.offer:
        await _answerHostOffer(msg);
        break;
      case SignalingMessageType.candidate:
        if (_viewerPeer != null && msg.payload != null) {
          await _viewerPeer!.addIceCandidate(_candidateFrom(msg.payload));
        }
        break;
      case SignalingMessageType.bye:
        await disconnectViewer();
        break;
      case SignalingMessageType.error:
        _viewerStatus = ViewerStatus.failed;
        _viewerError = msg.error ?? 'Connection rejected';
        notifyListeners();
        break;
      default:
        break;
    }
  }

  Future<void> _answerHostOffer(SignalingMessage msg) async {
    final hostId = msg.from;
    if (hostId == null || msg.payload == null) return;

    final peer = WebRTCService();
    _viewerPeer = peer;
    peer.onDataMessage = (raw) => _handleData(raw, isHost: false);
    peer.onRemoteStream = (stream) {
      _remoteStream = stream;
      _viewerStatus = ViewerStatus.connected;
      _startStatsTimer();
      _ensureClipboardSync();
      // Ask the host to apply our chosen quality preset once streaming starts.
      _viewerPeer?.sendData(jsonEncode({'k': 'quality', 'p': _streamQuality}));
      notifyListeners();
    };
    peer.onIceCandidate = (c) =>
        _viewerSignaling?.sendCandidate(hostId, _candidateMap(c));
    peer.onConnectionStateChange = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        if (_viewerStatus != ViewerStatus.idle) {
          _viewerStatus = ViewerStatus.failed;
          _viewerError = 'Connection failed';
          notifyListeners();
          // After a remote reboot this keeps re-dialing until the host is back.
          _maybeScheduleReconnect();
        }
      }
    };

    await peer.initialize(
      iceServers: _resolvedIce ?? iceServers,
      isOfferer: false,
    );
    await peer.setRemoteDescription(_sdpFrom(msg.payload));
    final answer = await peer.createAnswer();
    _viewerSignaling?.sendAnswer(hostId, _sdpMap(answer));
  }

  // =========================================================================
  // Stats
  // =========================================================================

  void _startStatsTimer() {
    _statsTimerMaybeStop();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final peer = _viewerPeer;
      if (peer == null) return;
      _stats = await peer.sampleStats();
      notifyListeners();
    });
  }

  void _statsTimerMaybeStop() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  // =========================================================================
  // Clipboard sync + data-channel routing
  // =========================================================================

  /// Routes an incoming data-channel message. Clipboard messages update the
  /// local clipboard on both roles; input events are injected on the host only.
  Future<void> _handleData(String raw, {required bool isHost}) async {
    Map<String, dynamic>? m;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) m = decoded;
    } catch (_) {}
    if (m == null) return;

    if (m['k'] == 'clip') {
      if (m['img'] == 1) {
        _recvClipImage(m);
        return;
      }
      final text = m['t'] as String?;
      if (text != null) {
        _lastClip = text; // avoid echoing it straight back
        await Clipboard.setData(ClipboardData(text: text));
        if (kRemoteVerboseLog) {
          debugPrint('[clip] received ${text.length} chars -> local clipboard');
        }
      }
      return;
    }

    // Host announces its OS so the viewer can map ⌘ ↔ Ctrl.
    if (m['k'] == 'os') {
      _remoteHostOs = m['v'] as String?;
      if (kRemoteVerboseLog) debugPrint('[os] remote host is $_remoteHostOs');
      notifyListeners();
      return;
    }

    // UAC secure-desktop stream (host -> viewer).
    if (m['k'] == 'uac') {
      _onUacMessage(m);
      return;
    }
    // UAC viewer input (viewer -> host) -> inject via the helper agent.
    if (m['k'] == 'uacin') {
      if (isHost) _onUacInput(m);
      return;
    }
    // File transfer (either direction).
    if (m['k'] == 'ft') {
      _files.handleMessage(m);
      return;
    }
    // Host command (viewer -> host), e.g. reboot.
    if (m['k'] == 'cmd') {
      if (isHost) _onHostCommand(m);
      return;
    }
    // Host's monitor list (host -> viewer).
    if (m['k'] == 'mons') {
      if (!isHost) {
        final l = (m['l'] as List?) ?? const [];
        hostMonitors = [
          for (final e in l)
            if (e is Map)
              {'id': '${e['id']}', 'n': '${e['n']}'}
        ];
        notifyListeners();
      }
      return;
    }
    // Viewer asked to switch the streamed monitor (viewer -> host).
    if (m['k'] == 'setmon') {
      if (isHost) _switchMonitor(m['id'] as String?);
      return;
    }
    // Viewer picked a quality preset (viewer -> host).
    if (m['k'] == 'quality') {
      if (isHost) _applyHostQuality((m['p'] as int?) ?? 1);
      return;
    }
    // In-session chat (either direction).
    if (m['k'] == 'chat') {
      _onChat(m);
      return;
    }
    // Transmit credentials: viewer sends text to type into the host's focused
    // field (UAC / login prompt). Routed through the SYSTEM helper so it reaches
    // the secure desktop / elevated windows.
    if (m['k'] == 'type') {
      if (isHost) {
        _uac.sendTypeText(
          (m['t'] as String?) ?? '',
          tab: m['tab'] == true,
          enter: m['enter'] == true,
        );
      }
      return;
    }

    if (isHost) {
      // NOTE: no host-side "control permission" gate here — it silently dropped
      // ALL input if the flag was ever false (a footgun that broke clicking).
      // View-only is enforced on the VIEWER side (it simply doesn't send input),
      // which is the reliable place for it.
      final event = InputEvent.decode(raw);
      if (event != null) {
        _trackHeldButton(event);
        _lastInputMs = _inputClock.elapsedMilliseconds;
        _logHostInput(event);
        _routeInput(event);
      }
    }
  }

  // Inject one host-side input event. Mouse MOVES always go to the fast in-app
  // injector: cursor positioning isn't integrity-blocked, and routing the
  // high-rate move stream through the SYSTEM helper (per-event desktop switch +
  // localhost hop) was stalling the cursor. Clicks/keys/wheel go through the
  // helper when connected so they still reach elevated windows. The click/key
  // route is only re-evaluated while nothing is held, so a drag doesn't split.
  void _routeInput(InputEvent event) {
    if (event.kind == 'mv') {
      _injector.inject(event);
      return;
    }
    if (_heldButtons.isEmpty) _routeToHelper = _uac.isConnected;
    if (_routeToHelper) {
      _uac.sendInput(event.data);
    } else {
      _injector.inject(event);
    }
  }

  // Viewer side: a UAC frame/state arrived from the host.
  void _onUacMessage(Map<String, dynamic> m) {
    final t = m['t'] as String?;
    if (t == 'active') {
      uacActive = true;
      uacW = (m['w'] as int?) ?? 0;
      uacH = (m['h'] as int?) ?? 0;
      uacKind = (m['kind'] as int?) ?? 0;
    } else if (t == 'frame') {
      final d = m['d'] as String?;
      if (d == null) return;
      final idx = m['i'] as int?;
      final total = m['n'] as int?;
      if (idx == null || total == null) {
        // Legacy single-message frame.
        uacFrame = base64Decode(d);
        uacActive = true;
      } else {
        if (idx == 0) {
          _uacChunkBuf.clear();
          _uacChunkNext = 0;
          _uacChunkTotal = total;
        }
        if (idx == _uacChunkNext && total == _uacChunkTotal) {
          _uacChunkBuf.write(d);
          _uacChunkNext++;
          if (_uacChunkNext == _uacChunkTotal) {
            try {
              uacFrame = base64Decode(_uacChunkBuf.toString());
              uacActive = true;
            } catch (_) {}
            _uacChunkBuf.clear();
            _uacChunkNext = 0;
          }
        } else {
          // A chunk arrived out of sequence — drop this partial frame and wait
          // for the next one to start fresh at idx 0.
          _uacChunkBuf.clear();
          _uacChunkNext = 0;
        }
        if (idx != _uacChunkTotal - 1) return; // no repaint mid-frame
      }
    } else if (t == 'gone') {
      uacActive = false;
      uacFrame = null;
      _uacChunkBuf.clear();
      _uacChunkNext = 0;
    }
    notifyListeners();
  }

  // Host side: a viewer's UAC click/key -> inject onto the secure desktop.
  void _onUacInput(Map<String, dynamic> m) {
    final a = m['a'] as String?;
    if (a == 'click') {
      _uac.sendClick((m['b'] as int?) ?? 0, (m['x'] as num?)?.toDouble() ?? 0,
          (m['y'] as num?)?.toDouble() ?? 0);
    } else if (a == 'key') {
      _uac.sendKey((m['vk'] as int?) ?? 0);
    }
  }

  /// Viewer: send a click on the UAC overlay (normalized 0..1) to the host.
  void sendUacClick(int button, double x, double y) {
    _viewerPeer?.sendData(
        jsonEncode({'k': 'uacin', 'a': 'click', 'b': button, 'x': x, 'y': y}));
  }

  /// Viewer: send a key (Win32 VK code) to the UAC prompt on the host.
  void sendUacKey(int vk) {
    _viewerPeer?.sendData(jsonEncode({'k': 'uacin', 'a': 'key', 'vk': vk}));
  }

  /// Viewer: APPROVE the UAC prompt. Uses the proven keyboard path — Left moves
  /// focus from the default No to Yes, then Enter activates it (200ms apart so
  /// the focus change registers). More reliable than a coordinate mouse click.
  void sendUacApprove() {
    _viewerPeer?.sendData(jsonEncode({'k': 'uacin', 'a': 'key', 'vk': 0x25})); // VK_LEFT
    Future.delayed(const Duration(milliseconds: 220), () {
      _viewerPeer?.sendData(jsonEncode({'k': 'uacin', 'a': 'key', 'vk': 0x0D})); // VK_RETURN
    });
  }

  /// Viewer: DECLINE the UAC prompt (Esc).
  void sendUacDecline() {
    _viewerPeer?.sendData(jsonEncode({'k': 'uacin', 'a': 'key', 'vk': 0x1B})); // VK_ESCAPE
  }

  // Host: wire the helper-agent UAC stream to all connected viewers.
  /// Whether the SYSTEM helper (and thus machine-wide multi-user access) is
  /// available on this host.
  bool get machineHelperSupported => _uac.isSupported;

  /// Fetch the machine-wide id + password from the SYSTEM helper, or null when
  /// the helper isn't reachable. Lets the UI show the shared credentials.
  Future<({String id, String password})?> fetchMachineCreds() =>
      _uac.fetchMachineCreds();

  /// Store [password] as the machine-wide password (shared by every account on
  /// this PC). No-op when the helper isn't present.
  void setMachinePassword(String password) =>
      _uac.setMachinePassword(password);

  void _setupUacBridge() {
    if (!_uac.isSupported) return;
    _uac.onActive = (w, h, kind) => _broadcastToPeers(
        jsonEncode({'k': 'uac', 't': 'active', 'w': w, 'h': h, 'kind': kind}));
    _uac.onFrame = _broadcastUacFrame;
    _uac.onGone = () => _broadcastToPeers(jsonEncode({'k': 'uac', 't': 'gone'}));
    _uac.start();
  }

  // Base64 a secure-desktop frame and send it in ordered chunks small enough for
  // one WebRTC data-channel message. A full-res frame base64s to ~300 KB, which
  // overran the ~256 KB per-message limit and was dropped whole — so a high-DPI
  // host's UAC prompt never appeared in the viewer.
  void _broadcastUacFrame(Uint8List png) {
    final b64 = base64Encode(png);
    const chunkLen = 48 * 1024; // 48 KB/message — safely under the DC limit
    final total = (b64.length / chunkLen).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < total; i++) {
      final start = i * chunkLen;
      final end = start + chunkLen < b64.length ? start + chunkLen : b64.length;
      _broadcastToPeers(jsonEncode({
        'k': 'uac',
        't': 'frame',
        'i': i,
        'n': total,
        'd': b64.substring(start, end),
      }));
    }
  }

  void _broadcastToPeers(String msg) {
    for (final peer in _hostPeers.values) {
      peer.sendData(msg);
    }
  }

  void _trackHeldButton(InputEvent e) {
    if (e.data['k'] != 'btn') return;
    final b = (e.data['b'] as int?) ?? 0;
    if (e.data['d'] == true) {
      _heldButtons.add(b);
    } else {
      _heldButtons.remove(b);
    }
  }

  void _startHostInputWatchdog() {
    _hostInputWatchdog?.cancel();
    _hostInputWatchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_heldButtons.isEmpty) return;
      if (_inputClock.elapsedMilliseconds - _lastInputMs < 1500) return;
      // Input went silent while a button was held — release it so the host's
      // mouse doesn't stay stuck (fixes the minimize/maximize freeze). Route it
      // the same way live input goes so the release reaches whichever injector
      // is holding the button.
      for (final b in _heldButtons.toList()) {
        _routeInput(InputEvent.button(b, false));
      }
      _heldButtons.clear();
    });
  }

  void _stopHostInputWatchdog() {
    _hostInputWatchdog?.cancel();
    _hostInputWatchdog = null;
    _heldButtons.clear();
  }

  // Host-side receive heartbeat: confirms whether input keeps arriving after a
  // click (host stops receiving = viewer/data-channel issue; host receives but
  // cursor frozen = native injection issue).
  int _hostMoveCount = 0;
  final Stopwatch _hostInputClock = Stopwatch()..start();
  int _hostInputHeartbeatMs = 0;
  void _logHostInput(InputEvent e) {
    if (!kRemoteVerboseLog) return;
    final kind = e.kind;
    if (kind == 'mv') {
      _hostMoveCount++;
      final now = _hostInputClock.elapsedMilliseconds;
      if (now - _hostInputHeartbeatMs >= 1000) {
        debugPrint('[host-input] moves received ~1s: $_hostMoveCount');
        _hostMoveCount = 0;
        _hostInputHeartbeatMs = now;
      }
    } else {
      debugPrint('[host-input] $kind ${e.data}');
    }
  }

  void _ensureClipboardSync() {
    if (_clipTimer != null) return;
    // Prime _lastClip so we don't immediately broadcast the existing clipboard.
    Clipboard.getData('text/plain').then((d) => _lastClip = d?.text);
    _clipTimer = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (_hostPeers.isEmpty && _viewerPeer == null) {
        _stopClipboardSync();
        return;
      }
      await _pollClipText();
      _clipTick++;
      if (_clipTick.isEven) await _pollClipImage(); // images ~every 1.2s
      if (_clipTick % 3 == 0) await _pollClipFiles(); // files ~every 1.8s
    });
  }

  Future<void> _pollClipText() async {
    String? text;
    try {
      final data = await Clipboard.getData('text/plain');
      text = data?.text;
    } catch (_) {
      return;
    }
    if (text == null || text.isEmpty || text == _lastClip) return;
    _lastClip = text;
    _broadcastClip(text);
  }

  Future<void> _pollClipImage() async {
    Uint8List? img;
    try {
      img = await Pasteboard.image;
    } catch (_) {
      return;
    }
    if (img == null || img.isEmpty) return;
    final h = _imgHash(img);
    if (h == _lastClipImgHash) return;
    _lastClipImgHash = h;
    _broadcastClipImage(img);
  }

  // Cheap change-detector for clipboard images (not cryptographic).
  int _imgHash(Uint8List b) {
    if (b.isEmpty) return 0;
    return b.length ^ (b.first << 8) ^ (b[b.length >> 1] << 16) ^ (b.last << 24);
  }

  void _broadcastClipImage(Uint8List bytes) {
    final b64 = base64Encode(bytes);
    const chunk = 48 * 1024;
    final total = (b64.length / chunk).ceil().clamp(1, 1 << 20);
    for (var i = 0; i < total; i++) {
      final start = i * chunk;
      final end = start + chunk < b64.length ? start + chunk : b64.length;
      final msg = jsonEncode({
        'k': 'clip',
        'img': 1,
        'i': i,
        'n': total,
        'd': b64.substring(start, end),
      });
      for (final peer in _hostPeers.values) {
        peer.sendData(msg);
      }
      _viewerPeer?.sendData(msg);
    }
  }

  void _recvClipImage(Map<String, dynamic> m) {
    final i = m['i'] as int?;
    final n = m['n'] as int?;
    final d = m['d'] as String?;
    if (i == null || n == null || d == null) return;
    if (i == 0) {
      _clipImgBuf.clear();
      _clipImgNext = 0;
      _clipImgTotal = n;
    }
    if (i == _clipImgNext && n == _clipImgTotal) {
      _clipImgBuf.write(d);
      _clipImgNext++;
      if (_clipImgNext == _clipImgTotal) {
        try {
          final bytes = base64Decode(_clipImgBuf.toString());
          _lastClipImgHash = _imgHash(bytes); // don't echo it straight back
          Pasteboard.writeImage(bytes);
        } catch (_) {}
        _clipImgBuf.clear();
        _clipImgNext = 0;
      }
    } else {
      _clipImgBuf.clear();
      _clipImgNext = 0;
    }
  }

  // Detect files freshly copied to the local clipboard and mirror them to the
  // peer's clipboard. Small files only (chunked base64 over the data channel).
  static const int _clipFileMaxBytes = 64 * 1024 * 1024; // 64 MB cap
  Future<void> _pollClipFiles() async {
    if (_clipFileSuppress > 0) {
      _clipFileSuppress--;
      return;
    }
    List<String> paths;
    try {
      // User-context agent first (reads the file clipboard even on a SYSTEM
      // host); fall back to the in-process clipboard when there's no agent.
      paths = await _clipAgent.readFiles() ?? await Pasteboard.files();
    } catch (_) {
      return;
    }
    if (paths.isEmpty) {
      _lastClipFiles = const [];
      return;
    }
    // Only react to a *change* (a fresh Ctrl+C), never re-send the same set.
    if (paths.length == _lastClipFiles.length) {
      var same = true;
      for (var i = 0; i < paths.length; i++) {
        if (paths[i] != _lastClipFiles[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _lastClipFiles = List.of(paths);
    for (final p in paths) {
      try {
        final bytes = await XFile(p).readAsBytes();
        if (bytes.length > _clipFileMaxBytes) continue; // too big to mirror
        final name = p.split(RegExp(r'[\\/]')).last;
        if (name.isEmpty) continue;
        // Reuse the reliable, flow-controlled file channel (not the control
        // channel) so large copies don't overrun the send buffer or stall input.
        await _files.sendFile(name, bytes, clipboard: true);
      } catch (_) {
        // Directory / unreadable — skip (folder copy isn't supported).
      }
    }
  }

  void _stopClipboardSync() {
    _clipTimer?.cancel();
    _clipTimer = null;
  }

  void _broadcastClip(String text) {
    final msg = jsonEncode({'k': 'clip', 't': text});
    for (final peer in _hostPeers.values) {
      peer.sendData(msg);
    }
    _viewerPeer?.sendData(msg);
  }

  // =========================================================================
  // Helpers
  // =========================================================================

  Map<String, dynamic> _sdpMap(RTCSessionDescription d) =>
      {'sdp': d.sdp, 'type': d.type};

  RTCSessionDescription _sdpFrom(dynamic p) =>
      RTCSessionDescription(p['sdp'] as String?, p['type'] as String?);

  Map<String, dynamic> _candidateMap(RTCIceCandidate c) => {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      };

  RTCIceCandidate _candidateFrom(dynamic p) => RTCIceCandidate(
        p['candidate'] as String?,
        p['sdpMid'] as String?,
        p['sdpMLineIndex'] as int?,
      );

  static const _kPersistentAgentId = 'persistentAgentId';

  /// Returns this install's stable agent ID, generating and persisting one the
  /// first time. Format matches the server's `%03d-%03d-%03d` (e.g. 123-456-789)
  /// so existing routing/UI conventions keep working.
  Future<String> _persistentAgentId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kPersistentAgentId);
    if (id == null || id.isEmpty) {
      id = _generateAgentId();
      await prefs.setString(_kPersistentAgentId, id);
    }
    return id;
  }

  String _generateAgentId() {
    final n = Random.secure().nextInt(1000000000); // 0 .. 999,999,999
    final s = n.toString().padLeft(9, '0');
    return '${s.substring(0, 3)}-${s.substring(3, 6)}-${s.substring(6, 9)}';
  }

  /// A best-effort hostname. The platform host name is only available via
  /// dart:io on native targets; to keep the orchestrator web-safe we derive a
  /// label from the platform instead.
  String _hostname() => '${_osName()}-host';

  String _osName() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return 'unknown';
    }
  }

  @override
  void dispose() {
    _statsTimerMaybeStop();
    _stopClipboardSync();
    _uac.dispose();
    stopHosting();
    disconnectViewer();
    super.dispose();
  }
}
