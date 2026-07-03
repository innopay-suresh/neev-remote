import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Signaling message types
enum SignalingMessageType {
  register,
  registered,
  connect,
  offer,
  answer,
  candidate,
  bye,
  error,
}

/// Signaling message
class SignalingMessage {
  final SignalingMessageType type;
  final String? from;
  final String? to;
  final dynamic payload;
  final String? error;

  SignalingMessage({
    required this.type,
    this.from,
    this.to,
    this.payload,
    this.error,
  });

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    return SignalingMessage(
      type: _parseType(json['type'] as String?),
      from: json['from'] as String?,
      to: json['to'] as String?,
      payload: json['payload'],
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': _typeToString(type),
    if (from != null) 'from': from,
    if (to != null) 'to': to,
    if (payload != null) 'payload': payload,
    if (error != null) 'error': error,
  };

  static SignalingMessageType _parseType(String? type) {
    switch (type) {
      case 'registered':
        return SignalingMessageType.registered;
      case 'connect':
        return SignalingMessageType.connect;
      case 'offer':
        return SignalingMessageType.offer;
      case 'answer':
        return SignalingMessageType.answer;
      case 'candidate':
        return SignalingMessageType.candidate;
      case 'bye':
        return SignalingMessageType.bye;
      case 'error':
        return SignalingMessageType.error;
      default:
        return SignalingMessageType.register;
    }
  }

  static String _typeToString(SignalingMessageType type) {
    switch (type) {
      case SignalingMessageType.register:
        return 'register';
      case SignalingMessageType.registered:
        return 'registered';
      case SignalingMessageType.connect:
        return 'connect';
      case SignalingMessageType.offer:
        return 'offer';
      case SignalingMessageType.answer:
        return 'answer';
      case SignalingMessageType.candidate:
        return 'candidate';
      case SignalingMessageType.bye:
        return 'bye';
      case SignalingMessageType.error:
        return 'error';
    }
  }
}

/// Signaling service for WebRTC negotiation
class SignalingService {
  WebSocketChannel? _channel;
  final String _serverUrl;
  final void Function(SignalingMessage) onMessage;
  final void Function() onConnected;
  final void Function() onDisconnected;

  bool _isConnected = false;
  String? _agentId;

  SignalingService({
    required String serverUrl,
    required this.onMessage,
    required this.onConnected,
    required this.onDisconnected,
  }) : _serverUrl = serverUrl;

  bool get isConnected => _isConnected;
  String? get agentId => _agentId;

  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      _isConnected = true;
      onConnected();

      _channel!.stream.listen(
        (data) {
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            final msg = SignalingMessage.fromJson(json);

            if (msg.type == SignalingMessageType.registered) {
              _agentId = msg.payload?['agent_id'] as String?;
            }

            onMessage(msg);
          } catch (e) {
            // Handle parse error
          }
        },
        onError: (error) {
          _isConnected = false;
          onDisconnected();
        },
        onDone: () {
          _isConnected = false;
          onDisconnected();
        },
      );
    } catch (e) {
      _isConnected = false;
      onDisconnected();
      rethrow;
    }
  }

  void send(SignalingMessage message) {
    if (_channel != null && _isConnected) {
      _channel!.sink.add(jsonEncode(message.toJson()));
    }
  }

  /// Registers this connection as a host agent with the signaling server.
  /// [passwordHash] must be the Argon2id `base64(salt):base64(hash)` string.
  void registerHost({
    required String passwordHash,
    String? agentId,
    String? hostname,
    String? os,
    String? version,
  }) {
    send(SignalingMessage(
      type: SignalingMessageType.register,
      payload: {
        'password_hash': passwordHash,
        if (agentId != null) 'agent_id': agentId,
        if (hostname != null) 'hostname': hostname,
        if (os != null) 'os': os,
        if (version != null) 'version': version,
      },
    ));
  }

  void sendOffer(String to, Map<String, dynamic> sdp) {
    send(SignalingMessage(
      type: SignalingMessageType.offer,
      to: to,
      payload: sdp,
    ));
  }

  void sendAnswer(String to, Map<String, dynamic> sdp) {
    send(SignalingMessage(
      type: SignalingMessageType.answer,
      to: to,
      payload: sdp,
    ));
  }

  void sendCandidate(String to, Map<String, dynamic> candidate) {
    send(SignalingMessage(
      type: SignalingMessageType.candidate,
      to: to,
      payload: candidate,
    ));
  }

  /// Requests a session with [targetAgentId]. The server's `ConnectPayload`
  /// verifies the supplied plaintext [password] against the stored Argon2id
  /// hash, so it is sent in the `password_hash` field by protocol convention.
  void sendConnect(String targetAgentId, String password) {
    send(SignalingMessage(
      type: SignalingMessageType.connect,
      payload: {'target_id': targetAgentId, 'password_hash': password},
    ));
  }

  void sendBye(String to) {
    send(SignalingMessage(
      type: SignalingMessageType.bye,
      to: to,
    ));
  }

  Future<void> disconnect() async {
    _isConnected = false;
    await _channel?.sink.close();
    _channel = null;
  }
}