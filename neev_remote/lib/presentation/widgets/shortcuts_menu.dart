import 'package:flutter/material.dart';

import '../../data/services/remote_service.dart';

class _Shortcut {
  const _Shortcut(this.label, this.keys);
  final String label;
  final List<int> keys; // USB HID usage codes
}

// HID usages: LGUI 0xE3, LCtrl 0xE0, LShift 0xE1, LAlt 0xE2; R 0x15, E 0x08,
// D 0x07, L 0x0F, Tab 0x2B, F4 0x3D, Esc 0x29.
const List<_Shortcut> _shortcuts = [
  _Shortcut('Windows key', [0xE3]),
  _Shortcut('Win + R  ·  Run', [0xE3, 0x15]),
  _Shortcut('Win + E  ·  File Explorer', [0xE3, 0x08]),
  _Shortcut('Win + D  ·  Show desktop', [0xE3, 0x07]),
  _Shortcut('Win + L  ·  Lock', [0xE3, 0x0F]),
  _Shortcut('Alt + Tab', [0xE2, 0x2B]),
  _Shortcut('Alt + F4', [0xE2, 0x3D]),
  _Shortcut('Task Manager  ·  Ctrl+Shift+Esc', [0xE0, 0xE1, 0x29]),
];

/// Actions the viewer can trigger on the remote (AnyDesk-style ⚡ menu). UI
/// feedback (toasts / confirms) is handled by the caller via [onAction].
enum RemoteAction {
  ctrlAltDel,
  lock,
  signOut,
  screenshot,
  insertClipboard,
  restart,
}

/// The ⚡ "Actions" menu: remote system actions plus a "send keystrokes"
/// section (Win+R, Alt+Tab, …) the local OS would otherwise swallow.
class ActionsMenu extends StatelessWidget {
  final RemoteService service;
  final void Function(RemoteAction) onAction;
  final Color color;
  const ActionsMenu({
    super.key,
    required this.service,
    required this.onAction,
    this.color = const Color(0xFF5B5B60),
  });

  @override
  Widget build(BuildContext context) {
    PopupMenuItem<void> action(RemoteAction a, IconData ic, String label,
            {bool danger = false}) =>
        PopupMenuItem<void>(
          onTap: () => onAction(a),
          child: Row(children: [
            Icon(ic,
                size: 18,
                color: danger ? const Color(0xFFE5484D) : const Color(0xFF5B5B60)),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: danger ? const Color(0xFFE5484D) : null)),
          ]),
        );
    return PopupMenuButton<void>(
      tooltip: 'Actions',
      icon: Icon(Icons.bolt_rounded, size: 19, color: color),
      iconSize: 19,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        const PopupMenuItem<void>(
            enabled: false,
            height: 28,
            child: Text('Actions',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        action(RemoteAction.ctrlAltDel, Icons.keyboard_alt_outlined,
            'Send Ctrl+Alt+Del'),
        action(RemoteAction.lock, Icons.lock_outline, 'Lock device'),
        action(RemoteAction.signOut, Icons.logout, 'Sign out user',
            danger: true),
        const PopupMenuDivider(),
        action(RemoteAction.screenshot, Icons.photo_camera_outlined,
            'Take screenshot'),
        action(RemoteAction.insertClipboard, Icons.content_paste_go_outlined,
            'Insert from clipboard'),
        const PopupMenuDivider(),
        action(RemoteAction.restart, Icons.restart_alt, 'Restart remote device',
            danger: true),
        const PopupMenuDivider(),
        const PopupMenuItem<void>(
            enabled: false,
            height: 28,
            child: Text('Send keystrokes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        for (final s in _shortcuts)
          PopupMenuItem<void>(
            onTap: () => service.sendKeyCombo(s.keys),
            child: Text(s.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }
}

/// A menu that sends system keyboard shortcuts (Win+R, Alt+Tab, …) to the
/// remote PC — shortcuts the local OS would otherwise swallow before the app
/// sees them.
class ShortcutsMenu extends StatelessWidget {
  final RemoteService service;
  final Color color;
  const ShortcutsMenu(
      {super.key, required this.service, this.color = const Color(0xFF5B5B60)});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<List<int>>(
      tooltip: 'Send a keyboard shortcut to the remote PC',
      icon: Icon(Icons.bolt_rounded, size: 19, color: color),
      iconSize: 19,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 38, minHeight: 40),
      position: PopupMenuPosition.under,
      onSelected: service.sendKeyCombo,
      itemBuilder: (_) => [
        const PopupMenuItem<List<int>>(
          enabled: false,
          height: 28,
          child: Text('Send to remote',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        for (final s in _shortcuts)
          PopupMenuItem<List<int>>(
            value: s.keys,
            child: Text(s.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
    );
  }
}
