import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/discovery_service.dart';
import '../../data/services/remote_service.dart';
import '../providers/app_providers.dart';
import '../widgets/file_transfer_panel.dart';
import '../widgets/remote_view_widget.dart';
import '../widgets/shortcuts_menu.dart';
import 'settings_page.dart';

/// Single-screen hub: "Share my screen" (host) on the left, "Connect to a
/// computer" (viewer) on the right. When a viewer session is active it takes
/// over the whole screen. Replaces the old Home/Agent/Viewer/Settings tabs.
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _autoStarted = false;
  int _section = 0; // selected sidebar section
  int _lastChatCount = 0; // for the incoming-chat notification

  @override
  void initState() {
    super.initState();
    // On desktop, start hosting automatically when the app opens so the
    // machine is immediately reachable (service-like). The browser web build
    // stays manual (each visitor shouldn't auto-share their screen).
    if (!kIsWeb) {
      Future.delayed(const Duration(milliseconds: 600), _autoStartHost);
    }
  }

  Future<void> _autoStartHost() async {
    if (_autoStarted || !mounted) return;
    final service = ref.read(remoteServiceProvider);
    if (service.isHosting) return;
    final settings = ref.read(settingsProvider);
    if (settings.relayUrl.isEmpty) return; // wait until the server is configured
    _autoStarted = true;
    try {
      await service.startHosting(
        relayUrl: settings.relayUrl,
        // Unattended: reuse the fixed password so the id+password stay stable
        // across restarts; otherwise a fresh one is generated.
        password: settings.unattendedPassword.isEmpty
            ? null
            : settings.unattendedPassword,
      );
    } catch (_) {
      // Surfaced on the Share card; user can fix the relay URL in Settings.
    }
  }

  @override
  void dispose() {
    _dismissChatToast();
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(remoteServiceProvider);
    final relayUrl = ref.watch(settingsProvider).relayUrl;
    // Keep LAN discovery alive for the whole app lifetime (not just while the
    // Discovery tab is open) so this machine is announcing + listening from
    // launch — otherwise two machines never see each other. No-op listener so
    // this doesn't rebuild the page on every device change.
    ref.listen(discoveryProvider, (_, __) {});

    // Pop a toast when a chat message arrives while the chat panel is closed —
    // works for both host (shell) and viewer (in-session), since this build
    // runs before either branch returns.
    ref.listen<RemoteService>(remoteServiceProvider, (prev, next) {
      final msgs = next.chatMessages;
      if (msgs.length > _lastChatCount) {
        final last = msgs.last;
        final chatOpen = ref.read(_chatOpenProvider);
        final onChatTab = _section == 5;
        if (!last.mine && !chatOpen && !onChatTab) {
          _notifyChat(last.text);
        }
      }
      _lastChatCount = msgs.length;
    });

    // Attended access: prompt on incoming connections unless unattended access
    // is enabled (then accept silently, AnyDesk-style).
    service.promptOnConnect = !ref.watch(settingsProvider).unattendedEnabled;

    // Show the consent prompt when a new incoming connection is pending.
    ref.listen<RemoteService>(remoteServiceProvider, (prev, next) {
      if (next.pendingConsent != null && prev?.pendingConsent == null) {
        _showConsentDialog(next.pendingConsent!);
      }
    });

    // Active remote session takes the whole window.
    if (service.viewerStatus == ViewerStatus.connected) {
      return _ConnectedSession(service: service);
    }

    // First run with no server baked in / saved: ask for the server once.
    if (relayUrl.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          title: Text('Neev Remote', style: AppTypography.heading2),
        ),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: SizedBox(width: 420, child: _ServerSetupCard(onSaved: () {
              _autoStarted = false;
              _autoStartHost();
            })),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(
        children: [
          _Sidebar(
            selected: _section,
            online: service.hostStatus == HostStatus.online,
            onSelect: (i) => setState(() => _section = i),
          ),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  service: service,
                  onSettings: () => setState(() => _section = 6),
                ),
                Expanded(child: _sectionContent(service)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _pickAndHome(String id) {
    _fillId(id);
    setState(() => _section = 0);
  }

  Widget _sectionContent(RemoteService service) {
    switch (_section) {
      case 6: // Settings
        return const SettingsPage();
      case 5: // Chat
        return _ChatSectionPage(service: service);
      case 4: // Discovery
        return _DiscoveryPage(onPick: _pickAndHome);
      case 2: // Recent
      case 3: // Favorites
        return _RecentPage(onPick: _pickAndHome);
      case 0: // Home
        return _HomeDashboard(
          service: service,
          idController: _idController,
          passwordController: _passwordController,
          onConnect: _connect,
          onPick: _fillId,
        );
      default: // Contacts — coming soon
        return _ComingSoon(item: _navItems[_section]);
    }
  }

  // Quick-connect from a recent: drop the id into the field and focus password.
  void _fillId(String id) {
    _idController.text = id;
    _passwordController.clear();
  }

  void _connect() {
    final id = _idController.text.trim();
    if (id.isEmpty) return;
    final relayUrl = ref.read(settingsProvider).relayUrl;
    // Remember this machine so it shows up under Recent connections.
    ref.read(recentConnectionsProvider.notifier).addConnection(
          RecentConnection(id: id, name: id, lastConnected: DateTime.now()),
        );
    ref.read(remoteServiceProvider).connectToHost(
          relayUrl: relayUrl,
          targetId: id,
          password: _passwordController.text,
        );
  }

  // A small toast anchored top-right (like a native notification), not a
  // full-width bar. Auto-dismisses; tap to open the chat.
  OverlayEntry? _chatToast;
  Timer? _chatToastTimer;

  void _notifyChat(String text) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _dismissChatToast();
    final preview = text.length > 90 ? '${text.substring(0, 90)}…' : text;
    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: 16,
        right: 16,
        child: _ChatToast(
          preview: preview,
          onOpen: () {
            _dismissChatToast();
            _openChatFromNotification();
          },
          onClose: _dismissChatToast,
        ),
      ),
    );
    _chatToast = entry;
    overlay.insert(entry);
    _chatToastTimer = Timer(const Duration(seconds: 5), _dismissChatToast);
  }

  void _dismissChatToast() {
    _chatToastTimer?.cancel();
    _chatToastTimer = null;
    _chatToast?.remove();
    _chatToast = null;
  }

  // AnyDesk-style incoming-connection consent with per-session permissions.
  Future<void> _showConsentDialog(ConsentRequest req) async {
    final service = ref.read(remoteServiceProvider);
    bool control = true, clipboard = true, files = true;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Row(children: [
            const Icon(Icons.shield_outlined, color: AppColors.primary),
            const SizedBox(width: 10),
            Text('Incoming connection', style: AppTypography.title),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Someone wants to connect to this computer. Choose what '
                  'they can do, then accept or dismiss.',
                  style: AppTypography.caption),
              const SizedBox(height: 8),
              _permSwitch('Control keyboard & mouse', Icons.mouse_outlined,
                  control, (v) => setDlg(() => control = v)),
              _permSwitch('Share clipboard', Icons.content_paste_outlined,
                  clipboard, (v) => setDlg(() => clipboard = v)),
              _permSwitch('Allow file transfer', Icons.folder_outlined, files,
                  (v) => setDlg(() => files = v)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Dismiss')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Accept'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true) {
      await service.acceptConnection(
          control: control, clipboard: clipboard, files: files);
    } else {
      service.rejectConnection();
    }
  }

  Widget _permSwitch(
      String label, IconData icon, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, size: 20, color: AppColors.textSecondary),
      title: Text(label, style: AppTypography.body),
    );
  }

  void _openChatFromNotification() {
    final service = ref.read(remoteServiceProvider);
    if (service.viewerStatus == ViewerStatus.connected) {
      // Viewer is in a live session → open the in-session chat panel.
      ref.read(_chatOpenProvider.notifier).state = true;
      service.pauseKeyboardCapture(true);
    } else {
      // Host (or idle viewer) → jump to the Chat sidebar section.
      setState(() => _section = 5);
    }
    service.markChatRead();
  }
}

// ---------------------------------------------------------------------------

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.card,
      ),
      child: child,
    );
  }
}

/// Shared search text for filtering Recent connections (top bar -> list).
final _homeSearchProvider = StateProvider<String>((_) => '');

/// Whether the in-session chat panel is open.
final _chatOpenProvider = StateProvider<bool>((_) => false);

/// True while an in-app text field needs the keyboard (e.g. the transmit-login
/// dialog) — pauses remote key forwarding so typing lands in the field.
final _typingLockProvider = StateProvider<bool>((_) => false);

/// Remote video view mode: false = fit (letterbox), true = fill (cover).
final _fillModeProvider = StateProvider<bool>((_) => false);

/// Compact incoming-chat pop-up (top-right corner). Small, native-notification
/// styling — a fixed ~300px card, not a full-width bar.
class _ChatToast extends StatelessWidget {
  final String preview;
  final VoidCallback onOpen;
  final VoidCallback onClose;
  const _ChatToast(
      {required this.preview, required this.onOpen, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 300,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1D1D1F),
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(
                color: Color(0x33000000), blurRadius: 20, offset: Offset(0, 8)),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.chat_bubble_rounded,
                  color: AppColors.primary, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('New message',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 12.5)),
                      ),
                      InkWell(
                        onTap: onClose,
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(Icons.close,
                              color: Color(0xFF8A8A8E), size: 15),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFFCFCFCF), fontSize: 12, height: 1.3)),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: onOpen,
                    borderRadius: BorderRadius.circular(6),
                    child: const Text('Open chat',
                        style: TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 12)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- App shell: left icon sidebar ---------------------------------------

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

const List<_NavItem> _navItems = [
  _NavItem(Icons.home_rounded, 'Home'),
  _NavItem(Icons.contacts_outlined, 'Contacts'),
  _NavItem(Icons.history_rounded, 'Recent'),
  _NavItem(Icons.star_border_rounded, 'Favorites'),
  _NavItem(Icons.radar_rounded, 'Discovery'),
  _NavItem(Icons.chat_bubble_outline_rounded, 'Chat'),
  _NavItem(Icons.settings_outlined, 'Settings'),
];

class _Sidebar extends StatelessWidget {
  final int selected;
  final bool online;
  final ValueChanged<int> onSelect;
  const _Sidebar(
      {required this.selected, required this.online, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppSpacing.md),
          for (var i = 0; i < _navItems.length; i++)
            _SidebarItem(
              item: _navItems[i],
              active: i == selected,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: online ? AppColors.success : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(online ? 'Online' : 'Offline',
                    style: AppTypography.label.copyWith(fontSize: 10)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final _NavItem item;
  final bool active;
  final VoidCallback onTap;
  const _SidebarItem(
      {required this.item, required this.active, required this.onTap});
  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final fg = active ? AppColors.accentDark : AppColors.textSecondary;
    final bg = active
        ? AppColors.primarySoft
        : (_hover ? AppColors.surfaceLight : Colors.transparent);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.item.label,
          waitDuration: const Duration(milliseconds: 500),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.item.icon, size: 21, color: fg),
                const SizedBox(height: 3),
                Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label.copyWith(
                      fontSize: 10,
                      color: fg,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Home section: the connect + share + recents + security cards.
class _HomeDashboard extends StatelessWidget {
  final RemoteService service;
  final TextEditingController idController;
  final TextEditingController passwordController;
  final VoidCallback onConnect;
  final void Function(String id) onPick;
  const _HomeDashboard({
    required this.service,
    required this.idController,
    required this.passwordController,
    required this.onConnect,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 860;
      final connect = _ConnectOutCard(
        service: service,
        idController: idController,
        passwordController: passwordController,
        onConnect: onConnect,
      );
      final thisPc = _ThisComputerCard(service: service);
      void soon(String f) => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$f is coming soon'),
              duration: const Duration(seconds: 2)));
      return SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160),
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (wide)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: connect),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(flex: 5, child: thisPc),
                  ],
                ),
              )
            else ...[
              connect,
              const SizedBox(height: AppSpacing.lg),
              thisPc,
            ],
            const SizedBox(height: AppSpacing.lg),
            // Feature tiles
            LayoutBuilder(builder: (context, fc) {
              final cols = fc.maxWidth > 720 ? 4 : 2;
              final tiles = [
                const _FeatureTile(
                    icon: Icons.lock_clock_rounded,
                    title: 'Unattended',
                    subtitle: 'Set a permanent password'),
                const _FeatureTile(
                    icon: Icons.shield_outlined,
                    title: 'Security',
                    subtitle: 'End-to-end encrypted'),
                _FeatureTile(
                    icon: Icons.radar_rounded,
                    title: 'Discovery',
                    subtitle: 'Find LAN devices',
                    onTap: () => soon('Discovery')),
                _FeatureTile(
                    icon: Icons.send_rounded,
                    title: 'Invite',
                    subtitle: 'Share an invitation',
                    onTap: () => soon('Invite')),
              ];
              return GridView.count(
                crossAxisCount: cols,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: AppSpacing.md,
                crossAxisSpacing: AppSpacing.md,
                childAspectRatio: 2.6,
                children: tiles,
              );
            }),
            const SizedBox(height: AppSpacing.lg),
            _RecentConnectionsCard(onPick: onPick),
          ],
            ),
          ),
        ),
      );
    });
  }
}

/// Small feature tile: coral-tint icon + title + subtitle (dashboard row 2).
class _FeatureTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  const _FeatureTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      this.onTap});
  @override
  State<_FeatureTile> createState() => _FeatureTileState();
}

class _FeatureTileState extends State<_FeatureTile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
                color: _hover ? AppColors.borderStrong : AppColors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(widget.icon, color: AppColors.accentDark, size: 20),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(widget.title, style: AppTypography.bodyStrong),
                    const SizedBox(height: 1),
                    Text(widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Recent / Favorites section — a full-width recent connections list.
class _RecentPage extends StatelessWidget {
  final void Function(String id) onPick;
  const _RecentPage({required this.onPick});
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _RecentConnectionsCard(onPick: onPick),
        ),
      ),
    );
  }
}

/// Placeholder for sections not yet built (Address book / Discovery / Chat).
class _ComingSoon extends StatelessWidget {
  final _NavItem item;
  const _ComingSoon({required this.item});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: _EmptyState(
          icon: item.icon,
          title: '${item.label} is coming soon',
          body: 'This section is on the roadmap and will light up in an '
              'upcoming update.',
        ),
      ),
    );
  }
}

/// Discovery section — machines running Neev Remote on the local network,
/// found over UDP broadcast. Tap Connect to drop the id into Home.
class _DiscoveryPage extends ConsumerWidget {
  final void Function(String id) onPick;
  const _DiscoveryPage({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final disc = ref.watch(discoveryProvider);
    final service = ref.watch(remoteServiceProvider);
    // Merge LAN broadcast (UDP) + server-assisted (relay) discovery, deduped by
    // id — the relay path finds machines even when the network blocks UDP.
    final byId = <String, DiscoveredDevice>{};
    for (final d in disc.devices) {
      byId[d.id] = d;
    }
    for (final d in service.serverPeers) {
      byId[d.id] = d;
    }
    final devices = byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: _Card(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  const Icon(Icons.radar_rounded,
                      color: AppColors.accentDark, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Discovery', style: AppTypography.title),
                  const Spacer(),
                  if (devices.isNotEmpty)
                    Text('${devices.length} found',
                        style: AppTypography.caption),
                ]),
                const SizedBox(height: 2),
                Text(disc.supported ? disc.status : 'LAN discovery runs on the '
                    'desktop app.', style: AppTypography.caption),
                const SizedBox(height: AppSpacing.md),
                if (!disc.supported)
                  const _EmptyState(
                    icon: Icons.wifi_off_rounded,
                    title: 'Not available here',
                    body: 'LAN discovery runs on the desktop app.',
                  )
                else if (devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
                    child: Column(children: [
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: AppColors.primary),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text('Searching your network…',
                          style: AppTypography.bodyStrong),
                      const SizedBox(height: 4),
                      Text(
                        'Other computers running Neev Remote on the same '
                        'network (and sharing) appear here automatically.',
                        textAlign: TextAlign.center,
                        style: AppTypography.caption,
                      ),
                    ]),
                  )
                else
                  for (final d in devices)
                    _DiscoveryRow(device: d, onConnect: () => onPick(d.id)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscoveryRow extends StatefulWidget {
  final DiscoveredDevice device;
  final VoidCallback onConnect;
  const _DiscoveryRow({required this.device, required this.onConnect});
  @override
  State<_DiscoveryRow> createState() => _DiscoveryRowState();
}

class _DiscoveryRowState extends State<_DiscoveryRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: _hover ? AppColors.surfaceLight : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.sm)),
            alignment: Alignment.center,
            child: const Icon(Icons.computer,
                size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, style: AppTypography.bodyStrong),
                Text('${d.id}   ·   ${d.ip}',
                    style: AppTypography.caption.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
          FilledButton(
            onPressed: widget.onConnect,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle:
                  AppTypography.caption.copyWith(fontWeight: FontWeight.w600),
            ),
            child: const Text('Connect'),
          ),
        ]),
      ),
    );
  }
}

/// Chat section — the conversation with the currently-connected peer.
class _ChatSectionPage extends StatefulWidget {
  final RemoteService service;
  const _ChatSectionPage({required this.service});
  @override
  State<_ChatSectionPage> createState() => _ChatSectionPageState();
}

class _ChatSectionPageState extends State<_ChatSectionPage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.service.markChatRead();
  }

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.service.sendChat(t);
    _ctrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (!service.hasChatPeer) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: const _EmptyState(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'No one connected',
            body: 'Chat is available during a session — connect to a computer '
                'or share your screen with someone.',
          ),
        ),
      );
    }
    final msgs = service.chatMessages;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: msgs.isEmpty
                      ? Center(
                          child: Text('No messages yet',
                              style: AppTypography.caption))
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(AppSpacing.md),
                          itemCount: msgs.length,
                          itemBuilder: (_, i) =>
                              _ChatLine(msg: msgs[i]),
                        ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                        hintText: 'Type a message…'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.icon(
                  onPressed: _send,
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatLine extends StatelessWidget {
  final ChatMessage msg;
  const _ChatLine({required this.msg});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: msg.mine ? AppColors.primary : AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(msg.text,
            style: AppTypography.body.copyWith(
                color: msg.mine ? Colors.white : AppColors.textPrimary)),
      ),
    );
  }
}

/// Top application toolbar: logo, connection status, search, notifications,
/// settings, user chip.
class _TopBar extends ConsumerWidget {
  final RemoteService service;
  final VoidCallback onSettings;
  const _TopBar({required this.service, required this.onSettings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = service.hostStatus == HostStatus.online;
    return Container(
      height: 60,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(Icons.hub_rounded, color: Colors.white, size: 19),
          ),
          const SizedBox(width: 10),
          Text('Neev Remote', style: AppTypography.title),
          const SizedBox(width: AppSpacing.md),
          _StatusPill(online: online),
          const Spacer(),
          SizedBox(width: 260, height: 40, child: _TopSearchField()),
          const SizedBox(width: AppSpacing.sm),
          _TopIconButton(
            icon: Icons.notifications_none_rounded,
            tooltip: 'Notifications',
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('You’re all caught up — no new notifications'),
                  duration: Duration(seconds: 2)),
            ),
          ),
          _TopIconButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onTap: onSettings),
          const SizedBox(width: AppSpacing.sm),
          _UserChip(),
        ],
      ),
    );
  }
}

class _TopSearchField extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextField(
      onChanged: (v) => ref.read(_homeSearchProvider.notifier).state = v,
      textAlignVertical: TextAlignVertical.center,
      style: AppTypography.body,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search recent connections',
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 38, minHeight: 38),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        fillColor: AppColors.surfaceLight,
      ),
    );
  }
}

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _TopIconButton(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onTap,
      style: IconButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        hoverColor: AppColors.surfaceLight,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm)),
      ),
    );
  }
}

class _UserChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
              color: AppColors.primary, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: const Icon(Icons.person, color: Colors.white, size: 15),
        ),
        const SizedBox(width: 8),
        Text('This PC', style: AppTypography.caption),
      ]),
    );
  }
}

/// Rounded connection-status pill (Online / Offline).
class _StatusPill extends StatelessWidget {
  final bool online;
  const _StatusPill({required this.online});

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.success : AppColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(online ? 'Online' : 'Offline',
            style: AppTypography.label.copyWith(color: color)),
      ]),
    );
  }
}

/// Left column: enter a partner ID + password to control another machine.
class _ConnectOutCard extends StatelessWidget {
  final RemoteService service;
  final TextEditingController idController;
  final TextEditingController passwordController;
  final VoidCallback onConnect;
  const _ConnectOutCard({
    required this.service,
    required this.idController,
    required this.passwordController,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    final connecting = service.viewerStatus == ViewerStatus.connecting;
    final failed = service.viewerStatus == ViewerStatus.failed;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _CardHeader(
            icon: Icons.cast_connected_rounded,
            title: 'Connect to a computer',
            subtitle: 'Enter the ID and password shared with you',
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: idController,
            decoration: InputDecoration(
              labelText: 'Partner ID',
              hintText: '123 456 789',
              prefixIcon: const Icon(Icons.link, size: 20),
              errorText: failed ? service.viewerError : null,
            ),
            style: AppTypography.body.copyWith(
                fontSize: 16, letterSpacing: 1, fontWeight: FontWeight.w600),
            onSubmitted: (_) => onConnect(),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              prefixIcon: Icon(Icons.lock_outline, size: 20),
            ),
            onSubmitted: (_) => onConnect(),
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton.icon(
            onPressed: connecting ? null : onConnect,
            icon: connecting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.arrow_forward_rounded, size: 20),
            label: Text(connecting ? 'Connecting…' : 'Connect'),
          ),
        ],
      ),
    );
  }
}

/// Left column: recent machines, filterable from the top-bar search.
class _RecentConnectionsCard extends ConsumerWidget {
  final void Function(String id) onPick;
  const _RecentConnectionsCard({required this.onPick});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(_homeSearchProvider).trim().toLowerCase();
    final all = ref.watch(recentConnectionsProvider);
    final recents = query.isEmpty
        ? all
        : all
            .where((c) =>
                c.id.toLowerCase().contains(query) ||
                c.name.toLowerCase().contains(query))
            .toList();
    return _Card(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Recent connections', style: AppTypography.title),
              const Spacer(),
              if (all.isNotEmpty)
                TextButton(
                  onPressed: () =>
                      ref.read(recentConnectionsProvider.notifier).clear(),
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (recents.isEmpty)
            _EmptyState(
              icon: Icons.history_rounded,
              title: query.isEmpty
                  ? 'No recent connections yet'
                  : 'No matches',
              body: query.isEmpty
                  ? 'Machines you connect to will appear here for one-click access.'
                  : 'Try a different ID or name.',
            )
          else
            for (final c in recents) _RecentRow(conn: c, onPick: onPick),
        ],
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  final RecentConnection conn;
  final void Function(String id) onPick;
  const _RecentRow({required this.conn, required this.onPick});
  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onPick(widget.conn.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: _hover ? AppColors.surfaceLight : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: BorderRadius.circular(AppRadius.sm)),
                alignment: Alignment.center,
                child: const Icon(Icons.computer,
                    size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.conn.id,
                        style: AppTypography.bodyStrong.copyWith(
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    Text('Last connected recently',
                        style: AppTypography.caption),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: FilledButton(
                  onPressed: () => widget.onPick(widget.conn.id),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: AppTypography.caption
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Connect'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _EmptyState(
      {required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(AppRadius.md)),
            alignment: Alignment.center,
            child: Icon(icon, color: AppColors.textTertiary, size: 24),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(title, style: AppTypography.bodyStrong),
          const SizedBox(height: 4),
          Text(body,
              textAlign: TextAlign.center, style: AppTypography.caption),
        ],
      ),
    );
  }
}

/// Right column: this machine's own ID + password for incoming connections,
/// share state, and unattended access.
class _ThisComputerCard extends ConsumerWidget {
  final RemoteService service;
  const _ThisComputerCard({required this.service});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = service.hostStatus == HostStatus.online;
    final busy = service.hostStatus == HostStatus.starting;
    final card = _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _CardHeader(
                icon: Icons.desktop_windows_rounded,
                title: 'This computer',
                subtitle: 'Share these so someone can connect to you',
              ),
              const Spacer(),
              if (online)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill)),
                  child: Text('${service.connectedViewers} connected',
                      style: AppTypography.label
                          .copyWith(color: AppColors.success)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (online) ...[
            _Credential(label: 'ID', value: service.agentId ?? '…', big: true),
            const SizedBox(height: AppSpacing.sm),
            _Credential(label: 'Password', value: service.password ?? '…'),
            if (service.connectedViewers > 0) ...[
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FileShareButtons(service: service),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text('…or drag files onto this card to send them.',
                  style: AppTypography.caption),
            ],
            if (service.fileTransfers.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FileTransferList(service: service),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(remoteServiceProvider).stopHosting(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Stop sharing'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: const BorderSide(color: AppColors.error),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            const _UnattendedControls(),
          ] else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final s = ref.read(settingsProvider);
                        try {
                          await ref.read(remoteServiceProvider).startHosting(
                                relayUrl: s.relayUrl,
                                password: s.unattendedPassword.isEmpty
                                    ? null
                                    : s.unattendedPassword,
                              );
                        } catch (_) {}
                      },
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.wifi_tethering_rounded, size: 20),
                label: Text(busy ? 'Starting…' : 'Start sharing'),
              ),
            ),
          if (service.hostError != null) ...[
            const SizedBox(height: AppSpacing.md),
            _ErrorText(service.hostError!),
          ],
        ],
      ),
    );
    return card;
  }
}

class _UnattendedControls extends ConsumerWidget {
  const _UnattendedControls();

  Future<void> _enable(BuildContext context, WidgetRef ref) async {
    final pw = await _askPassword(context);
    if (pw == null || pw.trim().isEmpty) return;
    final notifier = ref.read(settingsProvider.notifier);
    notifier.setUnattendedPassword(pw.trim());
    await notifier.setStartOnBoot(true);
    final service = ref.read(remoteServiceProvider);
    // Multi-user: store the password machine-wide (via the SYSTEM helper) so
    // every account on this PC shares it and it survives user-switching.
    service.setMachinePassword(pw.trim());
    // Re-share so the new fixed password takes effect immediately.
    final relay = ref.read(settingsProvider).relayUrl;
    if (service.isHosting) {
      await service.stopHosting();
      await service.startHosting(relayUrl: relay, password: pw.trim());
    }
  }

  Future<void> _disable(WidgetRef ref) async {
    final notifier = ref.read(settingsProvider.notifier);
    notifier.setUnattendedPassword('');
    await notifier.setStartOnBoot(false);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final enabled = s.unattendedEnabled;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_clock, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Unattended access',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              Switch(
                value: enabled,
                onChanged: (v) => v ? _enable(context, ref) : _disable(ref),
              ),
            ],
          ),
          Text(
            enabled
                ? (s.startOnBoot
                    ? 'Fixed password set · starts with Windows and re-shares automatically.'
                    : 'Fixed password set · turn on "Start with Windows" to reconnect after a reboot.')
                : 'Set a permanent password so you can reconnect any time — no one needs to re-share, and it survives restarts.',
            style: AppTypography.caption,
          ),
          if (enabled) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => _enable(context, ref),
                  icon: const Icon(Icons.key, size: 16),
                  label: const Text('Change password'),
                ),
                const Spacer(),
                const Text('Start with Windows',
                    style: TextStyle(fontSize: 12)),
                Switch(
                  value: s.startOnBoot,
                  onChanged: (_) =>
                      ref.read(settingsProvider.notifier).toggleStartOnBoot(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

Future<String?> _askPassword(BuildContext context) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Set permanent password'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(
            hintText: 'Password for unattended access'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save')),
      ],
    ),
  );
}

/// (Ambient animated background removed — the redesigned home is minimal.)
class _CardHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _CardHeader(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.accent, AppColors.accentDark],
            ),
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: [
              BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.32),
                  blurRadius: 12,
                  offset: const Offset(0, 5)),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.heading2),
              const SizedBox(height: 2),
              Text(subtitle, style: AppTypography.caption),
            ],
          ),
        ),
      ],
    );
  }
}

class _Credential extends StatelessWidget {
  final String label;
  final String value;
  final bool big;
  const _Credential(
      {required this.label, required this.value, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 10, AppSpacing.sm, 10),
      decoration: BoxDecoration(
        color: big ? AppColors.accentSoft : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
            color: big ? AppColors.accent.withValues(alpha: 0.45)
                       : AppColors.border),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label.toUpperCase(),
                  style: AppTypography.label
                      .copyWith(color: AppColors.textTertiary)),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontSize: big ? 26 : 18,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: big ? AppColors.accentDark : AppColors.textPrimary,
                  letterSpacing: big ? 2 : 1,
                ),
              ),
            ],
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.content_copy_rounded, size: 18),
            tooltip: 'Copy $label',
            style: IconButton.styleFrom(
              foregroundColor: AppColors.accentDark,
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                side: const BorderSide(color: AppColors.border),
              ),
            ),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text('$label copied'),
                    duration: const Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final String message;
  const _ErrorText(this.message);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline, color: AppColors.error, size: 18),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(message,
              style: AppTypography.caption.copyWith(color: AppColors.error)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _ConnectedSession extends ConsumerWidget {
  final RemoteService service;
  const _ConnectedSession({required this.service});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewOnly =
        ref.watch(settingsProvider).viewOnly || service.viewerViewOnly;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F1A),
      // Slim persistent header (AnyDesk-style) above the remote view. Because
      // it's a layout row — not an overlay — it never covers the remote's own
      // taskbar, and the video fills everything below it.
      body: Column(
        children: [
          _SessionToolbar(service: service),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: RemoteViewWidget(
                    isConnected: true,
                    remoteStream: service.remoteStream,
                    viewOnly: viewOnly,
                    hostOs: service.remoteHostOs,
                    onInput: viewOnly
                        ? null
                        : (event) => ref
                            .read(remoteServiceProvider)
                            .sendViewerInput(event),
                    uacActive: service.uacActive,
                    uacFrame: service.uacFrame,
                    uacW: service.uacW,
                    uacH: service.uacH,
                    uacKind: service.uacKind,
                    fillMode: ref.watch(_fillModeProvider),
                    inputPaused: ref.watch(_chatOpenProvider) ||
                        ref.watch(_typingLockProvider),
                    onUacClick: (b, x, y) =>
                        ref.read(remoteServiceProvider).sendUacClick(b, x, y),
                    onUacApprove: () =>
                        ref.read(remoteServiceProvider).sendUacApprove(),
                    onUacDecline: () =>
                        ref.read(remoteServiceProvider).sendUacDecline(),
                  ),
                ),
                Positioned(
                  right: AppSpacing.lg,
                  bottom: AppSpacing.lg,
                  child: FileTransferList(service: service),
                ),
                if (ref.watch(_chatOpenProvider))
                  Positioned(
                    right: AppSpacing.lg,
                    top: AppSpacing.lg,
                    bottom: AppSpacing.lg,
                    child: _ChatPanel(
                      service: service,
                      onClose: () {
                        ref.read(_chatOpenProvider.notifier).state = false;
                        service.pauseKeyboardCapture(false);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// In-session chat panel (dark glass), floated on the right of the video.
class _ChatPanel extends StatefulWidget {
  final RemoteService service;
  final VoidCallback onClose;
  const _ChatPanel({required this.service, required this.onClose});
  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  void _send() {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    widget.service.sendChat(t);
    _ctrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final msgs = widget.service.chatMessages;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 300,
          decoration: BoxDecoration(
            color: const Color(0xFF181818).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
                child: Row(
                  children: [
                    const Icon(Icons.chat_bubble_outline_rounded,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 8),
                    const Text('Chat',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.white54,
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.08)),
              Expanded(
                child: msgs.isEmpty
                    ? Center(
                        child: Text('No messages yet',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.4),
                                fontSize: 12)),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(10),
                        itemCount: msgs.length,
                        itemBuilder: (_, i) => _ChatBubble(msg: msgs[i]),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        autofocus: true,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        cursorColor: AppColors.primary,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.08),
                          hintText: 'Message…',
                          hintStyle: TextStyle(
                              color: Colors.white.withValues(alpha: 0.4),
                              fontSize: 13),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(AppRadius.input),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.send_rounded, size: 18),
                      color: AppColors.primaryHover,
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage msg;
  const _ChatBubble({required this.msg});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: msg.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: msg.mine
              ? AppColors.primary
              : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(msg.text,
            style: TextStyle(
                color: msg.mine
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.92),
                fontSize: 13)),
      ),
    );
  }
}

/// Premium in-session control bar: a status/stats cluster on the left and
/// clearly-labeled, grouped controls on the right so every action is trackable
/// (the old bar was icon-only and ambiguous).
class _SessionToolbar extends ConsumerWidget {
  final RemoteService service;
  const _SessionToolbar({required this.service});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = service.stats;
    final win = service.remoteHostOs == 'windows';

    return Container(
      height: 48,
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F8),
        border: Border(
            bottom: BorderSide(color: Color(0xFFE3E3E6), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          _ConnectionBadge(id: service.targetId ?? '—'),
          const SizedBox(width: AppSpacing.md),
          _StatsStrip(stats: stats),
          const Spacer(),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                // --- Control group ---
                _ToolButton(
                  icon: service.viewerViewOnly
                      ? Icons.visibility_outlined
                      : Icons.ads_click,
                  label: service.viewerViewOnly ? 'View only' : 'Control',
                  tooltip: service.viewerViewOnly
                      ? 'View only — click to take control'
                      : 'Controlling — click for view only',
                  active: !service.viewerViewOnly,
                  onPressed: () => service.setViewOnly(!service.viewerViewOnly),
                ),
                if (service.keyboardCaptureSupported)
                  _ToolButton(
                    icon: service.keyboardCapture
                        ? Icons.keyboard_alt
                        : Icons.keyboard_alt_outlined,
                    label: 'Keyboard',
                    tooltip: service.keyboardCapture
                        ? 'Keyboard capture ON — Win+R, Alt+Tab etc. go to the '
                            'remote. Click away to stop.'
                        : 'Capture keyboard — send Win+R, Alt+Tab etc. by '
                            'pressing them',
                    active: service.keyboardCapture,
                    onPressed: () =>
                        service.setKeyboardCapture(!service.keyboardCapture),
                  ),
                ActionsMenu(
                  service: service,
                  onAction: (a) => _handleAction(context, ref, a, service),
                ),
                if (service.hostMonitors.length > 1)
                  _MonitorButton(service: service),
                _ToolButton(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: service.unreadChat > 0
                      ? 'Chat (${service.unreadChat})'
                      : 'Chat',
                  tooltip: 'Chat with the other computer',
                  active: ref.watch(_chatOpenProvider) || service.unreadChat > 0,
                  onPressed: () {
                    final open = !ref.read(_chatOpenProvider);
                    ref.read(_chatOpenProvider.notifier).state = open;
                    service.pauseKeyboardCapture(open);
                    if (open) service.markChatRead();
                  },
                ),
                _ToolButton(
                  icon: ref.watch(_fillModeProvider)
                      ? Icons.fit_screen_outlined
                      : Icons.aspect_ratio_rounded,
                  label: ref.watch(_fillModeProvider) ? 'Fill' : 'Fit',
                  tooltip: ref.watch(_fillModeProvider)
                      ? 'Filling the window — click to fit (letterbox)'
                      : 'Fit to window — click to fill',
                  active: ref.watch(_fillModeProvider),
                  onPressed: () => ref.read(_fillModeProvider.notifier).state =
                      !ref.read(_fillModeProvider),
                ),
                const _ToolDivider(),
                // --- Files group ---
                _ToolButton(
                  icon: Icons.upload_file,
                  label: 'Export',
                  tooltip: 'Send a file to the connected computer',
                  onPressed: () => pickAndSendFile(context, service),
                ),
                _ToolButton(
                  icon: Icons.download_for_offline_outlined,
                  label: 'Import',
                  tooltip: 'Ask the connected computer to send you a file',
                  onPressed: () {
                    service.requestFileFromPeer();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'Import requested — the other computer picks a file '
                          'to send'),
                      duration: Duration(seconds: 3),
                    ));
                  },
                ),
                const _ToolDivider(),
                // --- Session group ---
                if (win)
                  _ToolButton(
                    icon: Icons.password_rounded,
                    label: 'Login',
                    tooltip: 'Transmit a username + password to the remote '
                        'UAC / login prompt',
                    onPressed: () =>
                        _showTransmitCredentials(context, ref, service),
                  ),
                if (win)
                  _ToolButton(
                    icon: Icons.blur_on,
                    label: 'Privacy',
                    tooltip: service.privacyMode
                        ? 'Privacy ON — host screen blanked + its input blocked'
                        : 'Privacy mode — blank the host screen + block its '
                            'local input',
                    active: service.privacyMode,
                    onPressed: () =>
                        service.setPrivacyMode(!service.privacyMode),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _DisconnectButton(
            onPressed: () =>
                ref.read(remoteServiceProvider).disconnectViewer(),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(BuildContext context, WidgetRef ref,
      RemoteAction a, RemoteService service) async {
    void toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
    switch (a) {
      case RemoteAction.ctrlAltDel:
        service.sendCtrlAltDel();
        toast('Ctrl+Alt+Del sent to the remote');
        break;
      case RemoteAction.lock:
        service.lockRemote();
        toast('Lock command sent');
        break;
      case RemoteAction.signOut:
        final ok = await _confirm(context, 'Sign out the remote user?',
            'This logs the remote user off — unsaved work there will be lost.',
            'Sign out');
        if (ok) {
          service.signOutRemote();
          toast('Sign-out command sent');
        }
        break;
      case RemoteAction.screenshot:
        toast('Capturing screenshot…');
        final path = await service.captureRemoteScreenshot();
        toast(path != null
            ? 'Screenshot saved to $path'
            : 'Couldn\'t capture a screenshot');
        break;
      case RemoteAction.insertClipboard:
        final ok = await service.insertClipboardToRemote();
        toast(ok
            ? 'Clipboard text sent to the remote'
            : 'Your clipboard has no text to insert');
        break;
      case RemoteAction.restart:
        await _confirmRestart(context, service);
        break;
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body,
      String confirmLabel) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _confirmRestart(
      BuildContext context, RemoteService service) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restart remote PC?'),
        content: const Text(
            'The remote computer will reboot now. Neev Remote will keep trying '
            'to reconnect for a few minutes once it\'s back (the host must be '
            'set to start on boot).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restart')),
        ],
      ),
    );
    if (ok == true) service.rebootHost();
  }

  Future<void> _showTransmitCredentials(
      BuildContext context, WidgetRef ref, RemoteService service) async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    void toast(String msg) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 1)));
    // Pause remote key forwarding + native hook so typing lands in the fields.
    ref.read(_typingLockProvider.notifier).state = true;
    service.pauseKeyboardCapture(true);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.password_rounded,
              color: AppColors.accentDark, size: 20),
          const SizedBox(width: AppSpacing.sm),
          const Text('Transmit login'),
        ]),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sends your typed username / password to the remote so you '
                'never reveal them on screen. Click the target field on the '
                'remote first, then type or send both.',
                style: AppTypography.caption,
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person_outline)),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline)),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        service.transmitText(userCtrl.text);
                        toast('Username sent');
                      },
                      child: const Text('Type username'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        service.transmitText(passCtrl.text);
                        toast('Password sent');
                      },
                      child: const Text('Type password'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton.icon(
            onPressed: () {
              // Username ⇥ then password ⏎ — ordered/reliable channel keeps the
              // two type messages in sequence.
              service.transmitText(userCtrl.text, tab: true);
              service.transmitText(passCtrl.text, enter: true);
              Navigator.pop(ctx);
              toast('Login transmitted');
            },
            icon: const Icon(Icons.send_rounded, size: 18),
            label: const Text('Send user ⇥ pass ⏎'),
          ),
        ],
      ),
    );
    ref.read(_typingLockProvider.notifier).state = false;
    service.pauseKeyboardCapture(false);
  }
}

/// Green pulse dot + "Connected to <id>" pill.
class _ConnectionBadge extends StatelessWidget {
  final String id;
  const _ConnectionBadge({required this.id});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: const BoxDecoration(
              color: AppColors.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(id,
            style: const TextStyle(
              color: Color(0xFF1D1D1F),
              fontWeight: FontWeight.w700,
              fontSize: 14,
              letterSpacing: 0.2,
              fontFeatures: [FontFeature.tabularFigures()],
            )),
      ],
    );
  }
}

/// Compact live-stats strip (fps · latency · bitrate). Codec + decoded frames
/// are surfaced on hover so a blank session can still be diagnosed.
class _StatsStrip extends StatelessWidget {
  final dynamic stats;
  const _StatsStrip({required this.stats});

  @override
  Widget build(BuildContext context) {
    Widget item(IconData ic, String v) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(ic, size: 13, color: const Color(0xFFA0A0A5)),
            const SizedBox(width: 4),
            Text(v,
                style: const TextStyle(
                    color: Color(0xFF6B6B70),
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()])),
          ]),
        );
    return Tooltip(
      message:
          'Codec ${stats.codec ?? '—'} · ${stats.framesDecoded ?? 0} frames decoded',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        item(Icons.speed, '${stats.fps ?? 0} fps'),
        item(Icons.network_ping, '${stats.latencyMs ?? 0} ms'),
        item(Icons.bar_chart, '${stats.bitrateKbps ?? 0} kbps'),
      ]),
    );
  }
}

/// A single labeled toolbar action: icon over a small caption, hover + active
/// states. Labels make every control immediately recognisable.
class _ToolButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final fg = active
        ? AppColors.primary
        : (_hover ? const Color(0xFF1D1D1F) : const Color(0xFF5B5B60));
    final bg = _hover ? const Color(0xFFEAEAEC) : Colors.transparent;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: SizedBox(
            width: 38,
            height: 40,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 34,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(widget.icon,
                      size: 19, color: fg, semanticLabel: widget.label),
                ),
                // AnyDesk-style active underline.
                if (active)
                  Positioned(
                    bottom: 1,
                    child: Container(
                      width: 20,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Monitor switcher styled as a [_ToolButton] with a dropdown.
class _MonitorButton extends StatelessWidget {
  final RemoteService service;
  const _MonitorButton({required this.service});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Switch monitor',
      position: PopupMenuPosition.under,
      onSelected: service.setMonitor,
      itemBuilder: (_) => [
        for (var i = 0; i < service.hostMonitors.length; i++)
          PopupMenuItem<String>(
            value: service.hostMonitors[i]['id'],
            child: Text(
              (service.hostMonitors[i]['n'] ?? '').isNotEmpty
                  ? service.hostMonitors[i]['n']!
                  : 'Monitor ${i + 1}',
              style: AppTypography.body,
            ),
          ),
      ],
      child: const SizedBox(
        width: 38,
        height: 40,
        child: Icon(Icons.monitor,
            size: 19,
            color: Color(0xFF5B5B60),
            semanticLabel: 'Switch monitor'),
      ),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        color: const Color(0xFFDDDDE0),
      );
}

/// Compact red pill for the one destructive action — sized for the slim bar.
class _DisconnectButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _DisconnectButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: SizedBox(
        height: 32,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.call_end_rounded, size: 16),
          label: const Text('End'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
            textStyle:
                const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

/// First-run card: ask for the server address so the same installer works
/// against any deployment. Shown only when no server is baked in or saved.
class _ServerSetupCard extends ConsumerStatefulWidget {
  final VoidCallback onSaved;
  const _ServerSetupCard({required this.onSaved});

  @override
  ConsumerState<_ServerSetupCard> createState() => _ServerSetupCardState();
}

class _ServerSetupCardState extends ConsumerState<_ServerSetupCard> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final url = normalizeRelayUrl(_controller.text);
    if (url.isEmpty) return;
    ref.read(settingsProvider.notifier).updateRelayUrl(url);
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.dns_outlined, color: AppColors.accent, size: 40),
          const SizedBox(height: AppSpacing.md),
          Text('Connect to your server', style: AppTypography.heading1),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Enter the address of your Neev Remote server (the one you '
            'downloaded this app from).',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'e.g. 192.168.1.10  or  remote.company.com',
              prefixIcon: Icon(Icons.public),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Save & Continue'),
            style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(AppSpacing.md)),
          ),
        ],
      ),
    );
  }
}

