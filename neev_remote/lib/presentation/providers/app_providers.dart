import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/discovery_service.dart';
import '../../data/services/remote_service.dart';
import '../../data/services/startup.dart';

/// Build-time global server URL, baked into every installer via
///   flutter build <platform> --dart-define=RELAY_URL=ws://YOUR_SERVER_IP:8080/ws
/// Empty when not provided.
const String kBuiltInRelayUrl = String.fromEnvironment('RELAY_URL');

/// The signaling server URL to use by default.
///
/// Priority:
///  1. On web: the SAME origin the app was served from (so it always reaches
///     the server that delivered it — never the viewer's own "localhost").
///  2. A build-time `RELAY_URL` baked into the installer (zero-touch rollout).
///  3. Empty → the app shows a one-time "connect to your server" setup screen,
///     so the SAME installer works against any deployment.
///
/// A value saved in Settings takes precedence over all of these.
String defaultRelayUrl() {
  if (kIsWeb) {
    final base = Uri.base; // the page URL the app was loaded from
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return '$scheme://${base.authority}/ws';
  }
  return kBuiltInRelayUrl; // '' when not baked -> first-run setup
}

/// Turns a friendly server entry into a full relay WebSocket URL. Accepts:
///   "1.2.3.4", "1.2.3.4:8080", "remote.example.com", "ws://...", "wss://.../ws"
/// Rules: explicit scheme is kept; a bare domain defaults to wss (TLS); a bare
/// IP/host defaults to ws and port 8080; the "/ws" path is ensured.
String normalizeRelayUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';
  if (!s.contains('://')) {
    final hasPort = RegExp(r':\d+$').hasMatch(s);
    final looksDomain = RegExp(r'[A-Za-z]').hasMatch(s) && s.contains('.');
    final scheme = (looksDomain && !hasPort) ? 'wss' : 'ws';
    final hostPort = (looksDomain || hasPort) ? s : '$s:8080';
    s = '$scheme://$hostPort';
  }
  final uri = Uri.tryParse(s);
  if (uri == null) return s;
  final path = (uri.path.isEmpty || uri.path == '/') ? '/ws' : uri.path;
  return uri.replace(path: path).toString();
}

// --- Core session service ---

/// The single orchestrator that owns signaling, WebRTC and screen capture for
/// both host and viewer roles. Lives for the lifetime of the app.
final remoteServiceProvider = ChangeNotifierProvider<RemoteService>((ref) {
  final service = RemoteService();
  ref.onDispose(service.dispose);
  return service;
});

// --- LAN discovery ---

/// Owns the UDP LAN-discovery service and re-broadcasts the current hosting id.
class DiscoveryController extends ChangeNotifier {
  final DiscoveryService _svc = DiscoveryService();
  DiscoveryController() {
    _svc.onChange = notifyListeners;
    _svc.start();
  }
  bool get supported => _svc.supported;
  List<DiscoveredDevice> get devices => _svc.devices;
  void setId(String? id) => _svc.setId(id ?? '');
  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }
}

final discoveryProvider = ChangeNotifierProvider<DiscoveryController>((ref) {
  final c = DiscoveryController();
  // Announce whatever id the host is currently sharing, and follow changes.
  ref.listen<RemoteService>(remoteServiceProvider, (prev, next) {
    c.setId(next.agentId);
  }, fireImmediately: true);
  ref.onDispose(c.dispose);
  return c;
});

// --- Settings ---

class AppSettings {
  final String relayUrl;
  final int videoBitrate;
  final int videoFps;
  final bool autoAnswer;
  final bool startOnBoot;
  final bool viewOnly;
  // Unattended access: a fixed password (empty = rotate per session). When set
  // together with startOnBoot, the host auto-starts sharing on launch so it can
  // be reached after a reboot with the same id + password.
  final String unattendedPassword;

  const AppSettings({
    this.relayUrl = '',
    this.videoBitrate = 1500,
    this.videoFps = 30,
    this.autoAnswer = false,
    this.startOnBoot = false,
    this.viewOnly = false,
    this.unattendedPassword = '',
  });

  bool get unattendedEnabled => unattendedPassword.isNotEmpty;

  AppSettings copyWith({
    String? relayUrl,
    int? videoBitrate,
    int? videoFps,
    bool? autoAnswer,
    bool? startOnBoot,
    bool? viewOnly,
    String? unattendedPassword,
  }) {
    return AppSettings(
      relayUrl: relayUrl ?? this.relayUrl,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      videoFps: videoFps ?? this.videoFps,
      autoAnswer: autoAnswer ?? this.autoAnswer,
      startOnBoot: startOnBoot ?? this.startOnBoot,
      viewOnly: viewOnly ?? this.viewOnly,
      unattendedPassword: unattendedPassword ?? this.unattendedPassword,
    );
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(AppSettings(relayUrl: defaultRelayUrl())) {
    _load();
  }

  static const _kRelay = 'relayUrl';
  static const _kBitrate = 'videoBitrate';
  static const _kFps = 'videoFps';
  static const _kViewOnly = 'viewOnly';
  static const _kUnattended = 'unattendedPassword';
  static const _kStartOnBoot = 'startOnBoot';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(
      relayUrl: prefs.getString(_kRelay),
      videoBitrate: prefs.getInt(_kBitrate),
      videoFps: prefs.getInt(_kFps),
      viewOnly: prefs.getBool(_kViewOnly),
      unattendedPassword: prefs.getString(_kUnattended),
      startOnBoot: prefs.getBool(_kStartOnBoot),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRelay, state.relayUrl);
    await prefs.setInt(_kBitrate, state.videoBitrate);
    await prefs.setInt(_kFps, state.videoFps);
    await prefs.setBool(_kViewOnly, state.viewOnly);
    await prefs.setString(_kUnattended, state.unattendedPassword);
    await prefs.setBool(_kStartOnBoot, state.startOnBoot);
  }

  /// Set (or clear, with '') the fixed unattended password.
  void setUnattendedPassword(String password) {
    state = state.copyWith(unattendedPassword: password.trim());
    _save();
  }

  /// Enable/disable launch-at-login (writes the OS startup entry).
  Future<void> setStartOnBoot(bool on) async {
    state = state.copyWith(startOnBoot: on);
    _save();
    await setAutoStart(on);
  }

  void updateRelayUrl(String url) {
    state = state.copyWith(relayUrl: url);
    _save();
  }

  void updateVideoBitrate(int bitrate) {
    state = state.copyWith(videoBitrate: bitrate);
    _save();
  }

  void updateVideoFps(int fps) {
    state = state.copyWith(videoFps: fps);
    _save();
  }

  void toggleAutoAnswer() {
    state = state.copyWith(autoAnswer: !state.autoAnswer);
  }

  void toggleStartOnBoot() => setStartOnBoot(!state.startOnBoot);

  void toggleViewOnly() {
    state = state.copyWith(viewOnly: !state.viewOnly);
    _save();
  }
}

// --- Recent connections ---

class RecentConnection {
  final String id;
  final String name;
  final String? ipAddress;
  final DateTime lastConnected;

  RecentConnection({
    required this.id,
    required this.name,
    this.ipAddress,
    required this.lastConnected,
  });
}

final recentConnectionsProvider =
    StateNotifierProvider<RecentConnectionsNotifier, List<RecentConnection>>(
        (ref) {
  return RecentConnectionsNotifier();
});

class RecentConnectionsNotifier extends StateNotifier<List<RecentConnection>> {
  RecentConnectionsNotifier() : super([]);

  void addConnection(RecentConnection connection) {
    state = [
      connection,
      ...state.where((c) => c.id != connection.id),
    ].take(10).toList();
  }

  void removeConnection(String id) {
    state = state.where((c) => c.id != id).toList();
  }

  void clear() {
    state = [];
  }
}
