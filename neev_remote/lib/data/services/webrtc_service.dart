import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Lightweight stats snapshot surfaced to the UI.
class SessionStats {
  final int? bitrateKbps;
  final int? fps;
  final int? latencyMs;

  /// Negotiated video codec actually in use (e.g. "VP8", "H264") — for
  /// diagnosing the Windows→Windows blank-video issue.
  final String? codec;

  /// Total video frames decoded so far (viewer side). 0 = nothing rendered yet.
  final int? framesDecoded;

  const SessionStats({
    this.bitrateKbps,
    this.fps,
    this.latencyMs,
    this.codec,
    this.framesDecoded,
  });
}

/// Wraps a single `RTCPeerConnection`, abstracting the offerer (host) and
/// answerer (viewer) flows used by [RemoteService].
///
/// Responsibilities handled here that the previous version got wrong:
///  * ICE candidates that arrive before the remote description is applied are
///    queued and flushed afterwards (otherwise `addCandidate` throws).
///  * The offerer (host) owns the `control` data channel; the answerer
///    receives it via `onDataChannel`.
///  * `getStats` is parsed into a [SessionStats] for the status bar.
class WebRTCService {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _cursorChannel;
  RTCDataChannel? _fileChannel;
  MediaStream? _remoteStream;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  // For bitrate delta calculation.
  int _lastBytes = 0;
  DateTime? _lastStatsAt;

  // Callbacks wired by the orchestrator.
  void Function(MediaStream stream)? onRemoteStream;
  void Function(RTCIceCandidate candidate)? onIceCandidate;
  void Function(String message)? onDataMessage;
  void Function(RTCPeerConnectionState state)? onConnectionStateChange;
  void Function()? onDataChannelOpen;

  RTCPeerConnection? get peerConnection => _pc;
  MediaStream? get remoteStream => _remoteStream;
  bool get isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Creates the peer connection. The host passes [isOfferer] = true so it
  /// owns the control data channel.
  Future<void> initialize({
    required List<Map<String, dynamic>> iceServers,
    required bool isOfferer,
    bool forceRelay = false,
  }) async {
    final config = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'iceServers': iceServers,
      // When a reachable TURN relay is advertised, force all media through it.
      // A direct candidate pair can pass STUN connectivity checks yet silently
      // drop media (asymmetric NAT / firewall), leaving the session "connected"
      // at 0 kbps. Relay-only sidesteps that dead path.
      if (forceRelay) 'iceTransportPolicy': 'relay',
    };

    _pc = await createPeerConnection(config);

    _pc!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) onIceCandidate?.call(candidate);
    };

    _pc!.onConnectionState = (state) => onConnectionStateChange?.call(state);

    _pc!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        onRemoteStream?.call(_remoteStream!);
      }
    };

    if (isOfferer) {
      final ctrlInit = RTCDataChannelInit()
        ..ordered = true
        ..id = 1;
      _dataChannel = await _pc!.createDataChannel('control', ctrlInit);
      _bindDataChannel(_dataChannel!);

      // High-rate cursor MOVES go on a separate unreliable, unordered channel:
      // a delayed move is dropped (not retransmitted/queued), so the remote
      // cursor reflects the latest position with minimal lag and never
      // head-of-line-blocks clicks/keys on the reliable channel.
      final curInit = RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmits = 0
        ..id = 2;
      _cursorChannel = await _pc!.createDataChannel('cursor', curInit);
      _bindDataChannel(_cursorChannel!, isControl: false);

      // Reliable, ordered channel dedicated to file transfer, so large file
      // chunks never head-of-line-block latency-sensitive input on 'control'.
      final fileInit = RTCDataChannelInit()
        ..ordered = true
        ..id = 3;
      _fileChannel = await _pc!.createDataChannel('file', fileInit);
      _bindDataChannel(_fileChannel!, isControl: false);
    } else {
      _pc!.onDataChannel = (channel) {
        if (channel.label == 'cursor') {
          _cursorChannel = channel;
          _bindDataChannel(channel, isControl: false);
        } else if (channel.label == 'file') {
          _fileChannel = channel;
          _bindDataChannel(channel, isControl: false);
        } else {
          _dataChannel = channel;
          _bindDataChannel(channel);
        }
      };
    }
  }

  void _bindDataChannel(RTCDataChannel channel, {bool isControl = true}) {
    channel.onMessage = (msg) {
      if (!msg.isBinary) onDataMessage?.call(msg.text);
    };
    // Only the control channel drives the "open" callback (OS handshake +
    // clipboard sync) so it doesn't fire twice.
    if (!isControl) return;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onDataChannelOpen?.call();
      }
    };
    // The channel may already be open by the time we bind (offerer side).
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      onDataChannelOpen?.call();
    }
  }

  RTCRtpSender? _videoSender;

  /// Adds the captured screen stream (host side) to the connection, then
  /// restricts the video transceiver to VP8 so the generated offer is VP8-only.
  Future<void> addLocalStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      final sender = await _pc!.addTrack(track, stream);
      if (track.kind == 'video') _videoSender = sender;
    }
    await _forceVp8();
  }

  /// Swaps the streamed video track without renegotiating — used to switch which
  /// host monitor is being sent mid-session.
  Future<void> replaceVideoTrack(MediaStreamTrack track) async {
    await _videoSender?.replaceTrack(track);
  }

  /// Host side: cap the outgoing video encoding — used by the viewer's quality
  /// presets (best quality / balanced / best performance). No renegotiation.
  Future<void> applyQuality({
    required int maxBitrateKbps,
    required int maxFps,
    double scaleDown = 1.0,
  }) async {
    final sender = _videoSender;
    if (sender == null) return;
    try {
      final params = sender.parameters;
      var encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        encodings = [RTCRtpEncoding()];
      }
      for (final e in encodings) {
        e.maxBitrate = maxBitrateKbps * 1000;
        e.maxFramerate = maxFps;
        e.scaleResolutionDownBy = scaleDown;
      }
      params.encodings = encodings;
      await sender.setParameters(params);
    } catch (_) {}
  }

  Future<RTCSessionDescription> createOffer() async {
    final offer = await _pc!.createOffer();
    // setCodecPreferences (above) is the clean way to force VP8, but desktop
    // libwebrtc may no-op it. As a deterministic fallback, strip non-VP8 video
    // codecs from the OFFER so the answerer can only pick VP8 (fixes
    // Windows→Windows blank video). Only the OFFER is touched — munging the
    // ANSWER breaks the data channel/input on Windows, the offer does not.
    String sdp;
    try {
      sdp = _stripNonVp8FromOffer(offer.sdp);
    } catch (_) {
      sdp = offer.sdp ?? '';
    }
    final out = RTCSessionDescription(sdp, offer.type);
    await _pc!.setLocalDescription(out);
    return out;
  }

  Future<RTCSessionDescription> createAnswer() async {
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    return answer;
  }

  /// Restricts the sending video transceiver to VP8 (+ RTX/FEC) via the proper
  /// `setCodecPreferences` API on the host (offerer). This makes the OFFER
  /// VP8-only, so the answerer is forced to VP8 — fixing Windows→Windows blank
  /// video (H.264 negotiated but undecodable) — WITHOUT rewriting any SDP.
  /// SDP munging the answer broke the data channel (all input) on Windows, so
  /// this codec-preference approach is used instead. Best-effort: on failure it
  /// falls back to default negotiation.
  Future<void> _forceVp8() async {
    try {
      final caps = await getRtpSenderCapabilities('video');
      final codecs = caps.codecs ?? const <RTCRtpCodecCapability>[];
      bool keep(RTCRtpCodecCapability c) {
        final m = c.mimeType.toLowerCase();
        return m == 'video/vp8' ||
            m == 'video/rtx' ||
            m == 'video/red' ||
            m == 'video/ulpfec' ||
            m == 'video/flexfec-03';
      }

      final preferred = codecs.where(keep).toList();
      final hasVp8 =
          preferred.any((c) => c.mimeType.toLowerCase() == 'video/vp8');
      if (!hasVp8) return; // don't strip everything if VP8 isn't available

      for (final t in await _pc!.getTransceivers()) {
        if (t.sender.track?.kind == 'video') {
          await t.setCodecPreferences(preferred);
        }
      }
    } catch (_) {
      // Best-effort; leaves default codec negotiation in place.
    }
  }

  /// Removes non-VP8 video codecs (H.264/VP9/AV1/H.265 and their RTX) from the
  /// offer's m=video so the answerer is forced to VP8. Keeps VP8, VP8's RTX and
  /// FEC (red/ulpfec). Operates only on the video m-section — the data channel
  /// (m=application) and everything else are left byte-for-byte intact, so the
  /// SCTP/input channel is unaffected. Returns the SDP unchanged if VP8 isn't
  /// present or anything looks off.
  String _stripNonVp8FromOffer(String? sdp) {
    if (sdp == null || sdp.isEmpty) return sdp ?? '';
    final lines = sdp.split(RegExp(r'\r\n|\n'));
    final mIndex = lines.indexWhere((l) => l.startsWith('m=video'));
    if (mIndex == -1) return sdp;
    var endIndex = lines.length;
    for (var i = mIndex + 1; i < lines.length; i++) {
      if (lines[i].startsWith('m=')) {
        endIndex = i;
        break;
      }
    }

    final codecOf = <String, String>{}; // pt -> codec (lowercase)
    final aptOf = <String, String>{}; // rtx pt -> referenced pt
    final rtpmapRe = RegExp(r'^a=rtpmap:(\d+)\s+([A-Za-z0-9\-]+)/');
    final aptRe = RegExp(r'^a=fmtp:(\d+)\s+.*\bapt=(\d+)');
    for (var i = mIndex + 1; i < endIndex; i++) {
      final r = rtpmapRe.firstMatch(lines[i]);
      if (r != null) codecOf[r.group(1)!] = r.group(2)!.toLowerCase();
      final a = aptRe.firstMatch(lines[i]);
      if (a != null) aptOf[a.group(1)!] = a.group(2)!;
    }

    bool isFec(String c) =>
        c == 'red' || c == 'ulpfec' || c == 'flexfec-03';
    final keep = <String>{};
    codecOf.forEach((pt, c) {
      if (c == 'vp8' || isFec(c)) keep.add(pt);
    });
    codecOf.forEach((pt, c) {
      if (c == 'rtx' && codecOf[aptOf[pt]] == 'vp8') keep.add(pt);
    });

    if (!keep.any((pt) => codecOf[pt] == 'vp8')) return sdp; // VP8 absent

    final parts = lines[mIndex].split(' ');
    if (parts.length <= 3) return sdp;
    final keptPts = parts.sublist(3).where(keep.contains).toList();
    if (keptPts.isEmpty) return sdp;
    final removed =
        parts.sublist(3).where((p) => !keep.contains(p)).toSet();
    lines[mIndex] = [...parts.sublist(0, 3), ...keptPts].join(' ');

    final attrRe = RegExp(r'^a=(?:rtpmap|fmtp|rtcp-fb):(\d+)\b');
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > mIndex && i < endIndex) {
        final m = attrRe.firstMatch(lines[i]);
        if (m != null && removed.contains(m.group(1))) continue;
      }
      out.add(lines[i]);
    }
    return out.join('\r\n');
  }

  Future<void> setRemoteDescription(RTCSessionDescription sdp) async {
    await _pc!.setRemoteDescription(sdp);
    _remoteDescriptionSet = true;
    for (final c in _pendingCandidates) {
      await _pc!.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    await _pc!.addCandidate(candidate);
  }

  bool sendData(String data) {
    if (!isDataChannelOpen) return false;
    _dataChannel!.send(RTCDataChannelMessage(data));
    return true;
  }

  bool get isFileChannelOpen =>
      _fileChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Buffered bytes queued on the file channel — used to pace file sends so we
  /// don't overrun the send buffer. 0 if unknown/unsupported.
  int get fileChannelBufferedAmount => _fileChannel?.bufferedAmount ?? 0;

  /// Sends a file-transfer message on the dedicated 'file' channel (falls back
  /// to control if that channel isn't up), keeping file bytes off 'control'.
  bool sendFileData(String data) {
    final c = _fileChannel;
    if (c != null && c.state == RTCDataChannelState.RTCDataChannelOpen) {
      c.send(RTCDataChannelMessage(data));
      return true;
    }
    return sendData(data);
  }

  /// Sends a low-latency cursor move on the unreliable channel, falling back to
  /// the reliable control channel if the cursor channel isn't open yet.
  bool sendCursor(String data) {
    final c = _cursorChannel;
    if (c != null && c.state == RTCDataChannelState.RTCDataChannelOpen) {
      c.send(RTCDataChannelMessage(data));
      return true;
    }
    return sendData(data);
  }

  /// Samples inbound/outbound RTP stats. Bitrate is derived from the byte
  /// delta since the previous call.
  Future<SessionStats> sampleStats() async {
    if (_pc == null) return const SessionStats();
    final reports = await _pc!.getStats();
    int? fps;
    int? bytes;
    int? rttMs;
    int? framesDecoded;
    String? codecId;
    String? codec;

    for (final r in reports) {
      final v = r.values;
      if (r.type == 'inbound-rtp' && v['kind'] == 'video') {
        fps = (v['framesPerSecond'] as num?)?.round();
        bytes = (v['bytesReceived'] as num?)?.toInt();
        framesDecoded = (v['framesDecoded'] as num?)?.toInt();
        codecId ??= v['codecId'] as String?;
      } else if (r.type == 'outbound-rtp' && v['kind'] == 'video') {
        fps ??= (v['framesPerSecond'] as num?)?.round();
        bytes ??= (v['bytesSent'] as num?)?.toInt();
        codecId ??= v['codecId'] as String?;
      } else if (r.type == 'candidate-pair' &&
          (v['state'] == 'succeeded' || v['nominated'] == true)) {
        final rtt = v['currentRoundTripTime'] as num?;
        if (rtt != null) rttMs = (rtt * 1000).round();
      }
    }
    // Resolve the codec mimeType (e.g. "video/VP8" -> "VP8").
    if (codecId != null) {
      for (final r in reports) {
        if (r.type == 'codec' && r.id == codecId) {
          final mt = r.values['mimeType'] as String?;
          if (mt != null) codec = mt.split('/').last;
          break;
        }
      }
    }

    int? bitrateKbps;
    final now = DateTime.now();
    if (bytes != null && _lastStatsAt != null) {
      final seconds = now.difference(_lastStatsAt!).inMilliseconds / 1000.0;
      if (seconds > 0) {
        bitrateKbps = (((bytes - _lastBytes) * 8) / 1000 / seconds).round();
      }
    }
    if (bytes != null) {
      _lastBytes = bytes;
      _lastStatsAt = now;
    }

    return SessionStats(
      bitrateKbps: bitrateKbps,
      fps: fps,
      latencyMs: rttMs,
      codec: codec,
      framesDecoded: framesDecoded,
    );
  }

  Future<void> close() async {
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _lastBytes = 0;
    _lastStatsAt = null;
    await _dataChannel?.close();
    await _cursorChannel?.close();
    await _fileChannel?.close();
    await _pc?.close();
    _dataChannel = null;
    _cursorChannel = null;
    _fileChannel = null;
    _pc = null;
    // The capture service owns the local stream's lifecycle.
    _remoteStream = null;
  }
}
