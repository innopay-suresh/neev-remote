import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'file_store.dart';

enum FileDirection { incoming, outgoing }

enum FileStatus { active, done, error }

/// One file transfer, either being sent to or received from the remote peer.
class FileTransfer {
  FileTransfer({
    required this.id,
    required this.name,
    required this.size,
    required this.direction,
    this.transferred = 0,
    this.status = FileStatus.active,
    this.savedPath,
    this.error,
    this.clipboard = false,
  });

  final String id;
  final String name;
  final int size; // total bytes; 0 if unknown
  final FileDirection direction;
  int transferred; // bytes moved so far
  FileStatus status;
  String? savedPath; // where an incoming file landed
  String? error;
  // True when this transfer is a clipboard mirror (copy→paste): the receiver
  // stages it to temp and puts it on the OS clipboard instead of Downloads.
  bool clipboard;

  double get progress =>
      size > 0 ? (transferred / size).clamp(0.0, 1.0).toDouble() : 0.0;
}

class _Incoming {
  _Incoming(this.ft) : buf = BytesBuilder(copy: false);
  final FileTransfer ft;
  final BytesBuilder buf;
}

/// Chunked file transfer over a text data channel. Wire messages (all JSON):
///   {k:'ft', t:'offer', id, name, size}   announce a transfer
///   {k:'ft', t:'data',  id, seq, d}       base64 chunk (ordered)
///   {k:'ft', t:'end',   id}               transfer complete
///   {k:'ft', t:'cancel',id}               aborted
/// Phase 1 buffers each transfer in memory (see [maxFile]); streaming to disk
/// is a later refinement.
class FileTransferManager {
  FileTransferManager({
    required this.send,
    required this.buffered,
    required this.store,
    required this.onChange,
    this.onRequest,
    this.onClipboardFile,
  });

  /// Sends one JSON message on the peer's file channel.
  final void Function(String json) send;

  /// Current bytes queued on the file channel (for send pacing); 0 if unknown.
  final int Function() buffered;

  final FileStore store;
  final void Function() onChange;

  /// Called when the peer asks us to share a file (their "Import") — should open
  /// a picker and send the chosen file back.
  final Future<void> Function()? onRequest;

  /// Called when a *clipboard* file finishes arriving, with the staged temp
  /// path — the owner puts it on the OS clipboard so Ctrl+V pastes the file.
  final Future<void> Function(String stagedPath)? onClipboardFile;

  /// Raw bytes per 'data' message; base64 inflates 36 KB → 48 KB, well under
  /// the ~256 KB channel limit.
  static const int rawChunk = 36 * 1024;

  /// Pause sending while more than this many bytes are queued locally.
  static const int _highWater = 4 * 1024 * 1024;

  /// Phase-1 in-memory size cap (200 MB) to avoid OOM.
  static const int maxFile = 200 * 1024 * 1024;

  final _uuid = const Uuid();
  final List<FileTransfer> transfers = [];
  final Map<String, _Incoming> _incoming = {};

  /// Send [bytes] as [name] to the peer. Returns the transfer, or null if the
  /// file is too large.
  Future<FileTransfer?> sendFile(String name, Uint8List bytes,
      {bool clipboard = false}) async {
    if (bytes.length > maxFile) return null;
    final id = _uuid.v4();
    final t = FileTransfer(
        id: id,
        name: name,
        size: bytes.length,
        direction: FileDirection.outgoing,
        clipboard: clipboard);
    transfers.insert(0, t);
    onChange();

    send(jsonEncode({
      'k': 'ft',
      't': 'offer',
      'id': id,
      'name': name,
      'size': bytes.length,
      if (clipboard) 'clip': 1,
    }));

    var seq = 0;
    for (var off = 0; off < bytes.length; off += rawChunk) {
      if (t.status == FileStatus.error) return t; // cancelled
      final end = off + rawChunk < bytes.length ? off + rawChunk : bytes.length;
      // Encode just this slice so we never build a huge base64 string.
      final chunk = base64Encode(bytes.sublist(off, end));
      send(jsonEncode(
          {'k': 'ft', 't': 'data', 'id': id, 'seq': seq, 'd': chunk}));
      seq++;
      t.transferred = end;
      onChange();
      // Yield, and back off if the local send buffer is backing up.
      await Future<void>.delayed(Duration.zero);
      var guard = 0;
      while (buffered() > _highWater && guard < 4000) {
        await Future<void>.delayed(const Duration(milliseconds: 8));
        guard++;
      }
    }
    if (t.status == FileStatus.error) return t;
    send(jsonEncode({'k': 'ft', 't': 'end', 'id': id}));
    t.transferred = t.size;
    t.status = FileStatus.done;
    onChange();
    return t;
  }

  /// Handle an inbound {k:'ft', ...} message.
  void handleMessage(Map<String, dynamic> m) {
    final t = m['t'] as String?;
    if (t == 'request') {
      onRequest?.call();
      return;
    }
    final id = m['id'] as String?;
    if (id == null) return;
    switch (t) {
      case 'offer':
        final name = (m['name'] as String?) ?? 'file';
        final size = (m['size'] as int?) ?? 0;
        final ft = FileTransfer(
            id: id,
            name: name,
            size: size,
            direction: FileDirection.incoming,
            clipboard: m['clip'] == 1);
        if (size > maxFile) {
          ft.status = FileStatus.error;
          ft.error = 'File exceeds the ${maxFile ~/ (1024 * 1024)} MB limit';
          transfers.insert(0, ft);
          onChange();
          return;
        }
        transfers.insert(0, ft);
        _incoming[id] = _Incoming(ft);
        onChange();
        break;
      case 'data':
        final inc = _incoming[id];
        final d = m['d'] as String?;
        if (inc == null || d == null) return;
        final bytes = base64Decode(d);
        inc.buf.add(bytes);
        inc.ft.transferred += bytes.length;
        onChange();
        break;
      case 'end':
        final inc = _incoming.remove(id);
        if (inc != null) _finishIncoming(inc);
        break;
      case 'cancel':
        final inc = _incoming.remove(id);
        if (inc != null) {
          inc.ft.status = FileStatus.error;
          inc.ft.error = 'Cancelled by sender';
          onChange();
        }
        break;
    }
  }

  Future<void> _finishIncoming(_Incoming inc) async {
    try {
      final bytes = inc.buf.takeBytes();
      if (inc.ft.clipboard) {
        // Clipboard mirror: save to Downloads (ALWAYS visible + findable) AND
        // put it on the OS clipboard for Ctrl+V. Downloads is the reliable
        // fallback because CF_HDROP clipboard paste is fragile across the
        // SYSTEM / cross-user boundary, whereas a saved file always lands.
        String? path;
        if (store.supported) {
          path = await store.saveToDownloads(inc.ft.name, bytes);
        }
        inc.ft.savedPath = path;
        if (path != null) await onClipboardFile?.call(path);
      } else if (store.supported) {
        inc.ft.savedPath = await store.saveToDownloads(inc.ft.name, bytes);
      }
      inc.ft.transferred = inc.ft.size == 0 ? bytes.length : inc.ft.size;
      inc.ft.status = FileStatus.done;
    } catch (e) {
      inc.ft.status = FileStatus.error;
      inc.ft.error = e.toString();
    }
    onChange();
  }

  void clearFinished() {
    transfers.removeWhere((t) => t.status != FileStatus.active);
    onChange();
  }
}
