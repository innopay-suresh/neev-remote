/// One device found on the local network.
class DiscoveredDevice {
  final String id;
  final String name;
  final String os;
  final String ip;
  DateTime lastSeen;
  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.os,
    required this.ip,
    required this.lastSeen,
  });
}
