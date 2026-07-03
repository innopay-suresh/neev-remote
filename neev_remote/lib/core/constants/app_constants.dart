/// App-wide constants
class AppConstants {
  static const String appName = 'Neev Remote';
  static const String appVersion = '1.0.0';

  // WebRTC ICE Servers
  static const List<Map<String, dynamic>> iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
  ];

  // Video encoding defaults
  static const int defaultVideoWidth = 1920;
  static const int defaultVideoHeight = 1080;
  static const int defaultFps = 30;
  static const int defaultBitrateKbps = 1500;
  static const int minBitrateKbps = 200;
  static const int maxBitrateKbps = 5000;
  static const int keyframeIntervalSeconds = 2;

  // Connection defaults
  static const Duration connectionTimeout = Duration(seconds: 30);
  static const Duration reconnectDelay = Duration(seconds: 3);
  static const int maxReconnectAttempts = 5;

  // Agent ID format: XXX-XXX-XXX
  static const String agentIdPattern = r'^\d{3}-\d{3}-\d{3}$';

  // UI constants
  static const double minWindowWidth = 800;
  static const double minWindowHeight = 600;
  static const double defaultWindowWidth = 1200;
  static const double defaultWindowHeight = 800;
}

/// WebRTC configuration
class WebRTCConfig {
  static const String videoCodec = 'H264';
  static const String audioCodec = 'opus';

  // Video constraints
  static const Map<String, dynamic> videoConstraints = {
    'width': 1920,
    'height': 1080,
    'frameRate': 30,
  };

  // ICE candidate gathering timeout
  static const Duration iceGatheringTimeout = Duration(seconds: 10);
}