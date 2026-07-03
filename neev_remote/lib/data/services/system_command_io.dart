import 'dart:io';

/// Reboots this machine. Desktop only. Windows/macOS interactive users can
/// normally restart without elevation; Linux uses logind/systemd.
Future<void> rebootMachine() async {
  try {
    if (Platform.isWindows) {
      await Process.run('shutdown', ['/r', '/t', '3', '/f']);
    } else if (Platform.isMacOS) {
      await Process.run(
          'osascript', ['-e', 'tell application "System Events" to restart']);
    } else if (Platform.isLinux) {
      final r = await Process.run('systemctl', ['reboot']);
      if (r.exitCode != 0) await Process.run('reboot', []);
    }
  } catch (_) {}
}
