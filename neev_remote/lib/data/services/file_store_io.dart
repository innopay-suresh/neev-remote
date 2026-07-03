import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Writes received files into a "NeevRemote" folder under the user's Downloads
/// (Documents as fallback). Desktop only; the web build uses the no-op stub.
class FileStore {
  bool get supported => true;

  /// Saves [bytes] as [name] (sanitised, never overwriting) and returns the
  /// absolute path written.
  Future<String> saveToDownloads(String name, Uint8List bytes) async {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {}
    // When the host runs as SYSTEM (service / unattended mode),
    // getDownloadsDirectory resolves into the SYSTEM profile
    // (…\system32\config\systemprofile\Downloads) where no user can find the
    // file. Redirect to the all-users Public Downloads so received files are
    // always visible regardless of which account (or SYSTEM) is hosting.
    if (Platform.isWindows) {
      final p = base?.path.toLowerCase() ?? '';
      if (base == null ||
          p.contains('systemprofile') ||
          p.contains('system32')) {
        final pub = Platform.environment['PUBLIC'];
        if (pub != null && pub.isNotEmpty) {
          base = Directory('$pub${Platform.pathSeparator}Downloads');
        }
      }
    }
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}NeevRemote');
    if (!await dir.exists()) await dir.create(recursive: true);

    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    final cleaned = safe.isEmpty ? 'file' : safe;
    var path = '${dir.path}${Platform.pathSeparator}$cleaned';
    var i = 1;
    while (await File(path).exists()) {
      final dot = cleaned.lastIndexOf('.');
      final stem = dot > 0 ? cleaned.substring(0, dot) : cleaned;
      final ext = dot > 0 ? cleaned.substring(dot) : '';
      path = '${dir.path}${Platform.pathSeparator}$stem ($i)$ext';
      i++;
    }
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Writes [bytes] to a temp file (used for clipboard-file paste: the receiver
  /// stages the file, then puts its path on the clipboard so Ctrl+V pastes it).
  Future<String?> saveToTemp(String name, Uint8List bytes) async {
    try {
      final dir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}NeevRemote');
      if (!await dir.exists()) await dir.create(recursive: true);
      final safe =
          name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
      final cleaned = safe.isEmpty ? 'file' : safe;
      final path = '${dir.path}${Platform.pathSeparator}$cleaned';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }
}
