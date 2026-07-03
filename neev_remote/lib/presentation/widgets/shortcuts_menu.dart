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

/// A menu that sends system keyboard shortcuts (Win+R, Alt+Tab, …) to the
/// remote PC — shortcuts the local OS would otherwise swallow before the app
/// sees them.
class ShortcutsMenu extends StatelessWidget {
  final RemoteService service;
  const ShortcutsMenu({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<List<int>>(
      tooltip: 'Send a keyboard shortcut to the remote PC',
      icon: Icon(Icons.bolt_rounded,
          size: 20, color: Colors.white.withValues(alpha: 0.72)),
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
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
