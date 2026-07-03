import 'package:equatable/equatable.dart';

/// Connection state enumeration
enum ConnectionStateType {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

/// Connection state entity
class RemoteConnectionState extends Equatable {
  final ConnectionStateType state;
  final String? agentId;
  final String? errorMessage;
  final int? latencyMs;
  final int? bitrateKbps;
  final int? fps;

  const RemoteConnectionState({
    required this.state,
    this.agentId,
    this.errorMessage,
    this.latencyMs,
    this.bitrateKbps,
    this.fps,
  });

  const RemoteConnectionState.disconnected()
      : this(state: ConnectionStateType.disconnected);

  const RemoteConnectionState.connecting({required String agentId})
      : this(state: ConnectionStateType.connecting, agentId: agentId);

  const RemoteConnectionState.connected({
    required String agentId,
    int? latencyMs,
    int? bitrateKbps,
    int? fps,
  }) : this(
         state: ConnectionStateType.connected,
         agentId: agentId,
         latencyMs: latencyMs,
         bitrateKbps: bitrateKbps,
         fps: fps,
       );

  const RemoteConnectionState.failed({required String errorMessage})
      : this(state: ConnectionStateType.failed, errorMessage: errorMessage);

  bool get isConnected => state == ConnectionStateType.connected;
  bool get isConnecting => state == ConnectionStateType.connecting;
  bool get isDisconnected => state == ConnectionStateType.disconnected;

  @override
  List<Object?> get props => [state, agentId, errorMessage, latencyMs, bitrateKbps, fps];
}