import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Client for the SYSTEM helper's user-context clipboard agent
/// (127.0.0.1:47922). That agent runs AS THE LOGGED-IN USER, so it can read /
/// write the interactive file clipboard (CF_HDROP) that a SYSTEM host can't.
/// Every method fails soft (null / false) so callers fall back to Pasteboard
/// when no agent is present (e.g. attended install without the service).
///
/// Wire: [u32 len big-endian][u8 type][payload]. Requests: 'R' read files,
/// 'W' write files (payload = paths joined by '\n'). Replies: 'F' (files),
/// 'K' (write ok), 'E' (write failed).
class ClipAgentBridge {
  static const int _port = 47922;
  bool get supported => true;

  Future<List<String>?> readFiles() async {
    try {
      final sock = await Socket.connect('127.0.0.1', _port,
          timeout: const Duration(milliseconds: 400));
      try {
        _send(sock, 0x52, const []); // 'R'
        final reply = await _recv(sock).timeout(const Duration(seconds: 2));
        if (reply == null || reply.type != 0x46) return null; // 'F'
        final text = utf8.decode(reply.payload, allowMalformed: true);
        if (text.isEmpty) return const [];
        return text
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      } finally {
        sock.destroy();
      }
    } catch (_) {
      return null; // no agent → caller falls back to Pasteboard
    }
  }

  Future<bool> writeFiles(List<String> paths) async {
    if (paths.isEmpty) return false;
    try {
      final sock = await Socket.connect('127.0.0.1', _port,
          timeout: const Duration(milliseconds: 400));
      try {
        _send(sock, 0x57, utf8.encode(paths.join('\n'))); // 'W'
        final reply = await _recv(sock).timeout(const Duration(seconds: 3));
        return reply != null && reply.type == 0x4B; // 'K'
      } finally {
        sock.destroy();
      }
    } catch (_) {
      return false;
    }
  }

  void _send(Socket sock, int type, List<int> payload) {
    final len = 1 + payload.length;
    final header = ByteData(4)..setUint32(0, len, Endian.big);
    sock.add(header.buffer.asUint8List());
    sock.add([type]);
    if (payload.isNotEmpty) sock.add(payload);
  }

  Future<_ClipMsg?> _recv(Socket sock) async {
    final buf = BytesBuilder();
    await for (final chunk in sock) {
      buf.add(chunk);
      final bytes = buf.toBytes();
      if (bytes.length < 4) continue;
      final len = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      if (bytes.length < 4 + len) continue;
      final type = bytes[4];
      final payload = bytes.sublist(5, 4 + len);
      return _ClipMsg(type, payload);
    }
    return null;
  }
}

class _ClipMsg {
  final int type;
  final Uint8List payload;
  _ClipMsg(this.type, this.payload);
}
