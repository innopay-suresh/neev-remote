import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'discovery_model.dart';

/// LAN discovery over UDP broadcast (desktop). Each online device announces
/// its shareable id + name on a well-known port every few seconds; every
/// instance also listens and builds a live list of the others it hears.
class DiscoveryService {
  static const int _port = 47920;
  static const Duration _announceEvery = Duration(seconds: 3);
  static const Duration _staleAfter = Duration(seconds: 12);

  RawDatagramSocket? _sock;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  String _id = '';
  String _name = '';
  String _os = '';
  bool _stopped = false;

  final Map<String, DiscoveredDevice> _devices = {};

  /// Called whenever the discovered-device list changes.
  void Function()? onChange;

  bool get supported => true;
  List<DiscoveredDevice> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Begin listening + announcing. Name/OS are read from the machine itself.
  void start() {
    if (_sock != null || _stopped) return;
    try {
      _name = Platform.localHostname;
    } catch (_) {
      _name = 'PC';
    }
    _os = Platform.operatingSystem;
    _bind();
  }

  /// Set the shareable id to announce (empty = listen only). Call when the
  /// hosting id becomes available or changes.
  void setId(String id) => _id = id;

  Future<void> _bind() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port,
          reuseAddress: true, reusePort: false);
      s.broadcastEnabled = true;
      _sock = s;
      s.listen(_onEvent);
      _announceTimer =
          Timer.periodic(_announceEvery, (_) => _announce());
      _pruneTimer =
          Timer.periodic(const Duration(seconds: 4), (_) => _prune());
      _announce();
    } catch (_) {
      // Port busy / no network — retry shortly.
      if (!_stopped) Timer(const Duration(seconds: 5), _bind);
    }
  }

  void _announce() {
    final s = _sock;
    if (s == null || _id.isEmpty) return;
    final payload = utf8.encode(jsonEncode(
        {'neev': 1, 'id': _id, 'name': _name, 'os': _os}));
    try {
      s.send(payload, InternetAddress('255.255.255.255'), _port);
    } catch (_) {}
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _sock?.receive();
    if (dg == null) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m['neev'] != 1) return;
    final id = (m['id'] as String?)?.trim() ?? '';
    if (id.isEmpty || id == _id) return; // skip self / anonymous
    final existing = _devices[id];
    final wasNew = existing == null;
    _devices[id] = DiscoveredDevice(
      id: id,
      name: (m['name'] as String?) ?? id,
      os: (m['os'] as String?) ?? '',
      ip: dg.address.address,
      lastSeen: DateTime.now(),
    );
    if (wasNew) onChange?.call();
  }

  void _prune() {
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere((_, d) => now.difference(d.lastSeen) > _staleAfter);
    if (_devices.length != before) onChange?.call();
  }

  void stop() {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _announceTimer = null;
    _pruneTimer = null;
    _sock?.close();
    _sock = null;
    _devices.clear();
  }

  void dispose() {
    _stopped = true;
    stop();
  }
}
