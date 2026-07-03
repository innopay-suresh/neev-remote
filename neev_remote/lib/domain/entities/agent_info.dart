import 'package:equatable/equatable.dart';

/// Agent status enumeration
enum AgentStatus {
  offline,
  starting,
  online,
  error,
}

/// Agent info entity
class AgentInfo extends Equatable {
  final String id;
  final String name;
  final String? ipAddress;
  final AgentStatus status;
  final DateTime? lastConnected;
  final Map<String, dynamic>? capabilities;

  const AgentInfo({
    required this.id,
    required this.name,
    this.ipAddress,
    this.status = AgentStatus.offline,
    this.lastConnected,
    this.capabilities,
  });

  AgentInfo copyWith({
    String? id,
    String? name,
    String? ipAddress,
    AgentStatus? status,
    DateTime? lastConnected,
    Map<String, dynamic>? capabilities,
  }) {
    return AgentInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ipAddress: ipAddress ?? this.ipAddress,
      status: status ?? this.status,
      lastConnected: lastConnected ?? this.lastConnected,
      capabilities: capabilities ?? this.capabilities,
    );
  }

  bool get isOnline => status == AgentStatus.online;
  bool get isOffline => status == AgentStatus.offline;

  @override
  List<Object?> get props => [id, name, ipAddress, status, lastConnected, capabilities];
}