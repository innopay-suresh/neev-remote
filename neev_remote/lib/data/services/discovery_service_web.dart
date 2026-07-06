import 'discovery_model.dart';

/// Web/no-op stub — LAN discovery needs raw UDP sockets (desktop only).
class DiscoveryService {
  bool get supported => false;
  String status = 'Not available on web';
  List<DiscoveredDevice> get devices => const [];
  void Function()? onChange;
  void start() {}
  void setId(String id) {}
  Future<void> refresh() async {}
  void stop() {}
  void dispose() {}
}
