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

/// Locks this machine (Win+L equivalent). No elevation needed.
Future<void> lockMachine() async {
  try {
    if (Platform.isWindows) {
      await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
    } else if (Platform.isMacOS) {
      await Process.run('pmset', ['displaysleepnow']);
    } else if (Platform.isLinux) {
      final r = await Process.run('loginctl', ['lock-session']);
      if (r.exitCode != 0) await Process.run('xdg-screensaver', ['lock']);
    }
  } catch (_) {}
}

/// Signs the current user out (logs off). Desktop only.
Future<void> signOutMachine() async {
  try {
    if (Platform.isWindows) {
      await Process.run('shutdown', ['/l']);
    } else if (Platform.isMacOS) {
      await Process.run(
          'osascript', ['-e', 'tell application "System Events" to log out']);
    } else if (Platform.isLinux) {
      final r =
          await Process.run('gnome-session-quit', ['--logout', '--no-prompt']);
      if (r.exitCode != 0) {
        await Process.run('loginctl', ['terminate-user', '']);
      }
    }
  } catch (_) {}
}
