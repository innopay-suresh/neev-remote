import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// A capturable screen/window source on the host.
class CaptureSource {
  final String id;
  final String name;
  final SourceType type;

  const CaptureSource({
    required this.id,
    required this.name,
    required this.type,
  });
}

/// Real desktop screen capture backed by `flutter_webrtc`'s `desktopCapturer`
/// + `getDisplayMedia`. Works on Windows, macOS and Linux desktop builds.
///
/// macOS requires the user to grant Screen Recording permission the first
/// time capture starts (system TCC prompt).
class ScreenCaptureService {
  bool _isCapturing = false;
  MediaStream? _stream;

  bool get isCapturing => _isCapturing;
  MediaStream? get stream => _stream;

  /// Enumerates available screens (and windows) on the host.
  Future<List<CaptureSource>> getSources({bool includeWindows = false}) async {
    final types = <SourceType>[
      SourceType.Screen,
      if (includeWindows) SourceType.Window,
    ];
    final sources = await desktopCapturer.getSources(types: types);
    return sources
        .map((s) => CaptureSource(id: s.id, name: s.name, type: s.type))
        .toList();
  }

  /// Captures a specific screen by [sourceId]. When [sourceId] is null the
  /// primary screen is captured automatically (no picker dialog) — the
  /// behaviour an unattended host needs.
  Future<MediaStream?> startCapture({
    String? sourceId,
    int fps = 30,
    int? maxWidth,
    int? maxHeight,
  }) async {
    if (_isCapturing) {
      await stopCapture();
    }

    var id = sourceId;
    if (id == null) {
      final screens = await getSources();
      if (screens.isEmpty) {
        _isCapturing = false;
        return null;
      }
      id = screens.first.id;
    }

    final mandatory = <String, dynamic>{
      'frameRate': fps.toDouble(),
      if (maxWidth != null) 'maxWidth': maxWidth,
      if (maxHeight != null) 'maxHeight': maxHeight,
    };

    try {
      _stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'audio': false,
        'video': {
          'deviceId': {'exact': id},
          'mandatory': mandatory,
        },
      });
      _isCapturing = _stream!.getVideoTracks().isNotEmpty;
      return _isCapturing ? _stream : null;
    } catch (e) {
      _isCapturing = false;
      _stream = null;
      rethrow;
    }
  }

  MediaStreamTrack? get videoTrack {
    final tracks = _stream?.getVideoTracks();
    return (tracks != null && tracks.isNotEmpty) ? tracks.first : null;
  }

  Future<void> stopCapture() async {
    final stream = _stream;
    _stream = null;
    _isCapturing = false;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
  }

  Future<void> dispose() => stopCapture();
}
