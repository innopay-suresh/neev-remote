import 'dart:io';

/// Registers/unregisters the app to launch at Windows login (per-user Run key).
/// Windows only for now; other desktops are a no-op.
Future<void> setAutoStart(bool enable) async {
  if (!Platform.isWindows) return;
  const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  const name = 'NeevRemote';
  try {
    if (enable) {
      final exe = Platform.resolvedExecutable;
      await Process.run(
          'reg', ['add', key, '/v', name, '/t', 'REG_SZ', '/d', exe, '/f']);
    } else {
      await Process.run('reg', ['delete', key, '/v', name, '/f']);
    }
  } catch (_) {}
}
