import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/remote_service.dart';
import '../providers/app_providers.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Settings', style: AppTypography.heading1),
              const SizedBox(height: AppSpacing.xl),

              // Connection Settings
              _buildSectionHeader('Connection'),
              _buildSettingsCard([
                const _RelayUrlField(),
                const Divider(),
                _buildToggle(
                  label: 'View Only Mode',
                  subtitle: 'Disable keyboard and mouse input',
                  value: settings.viewOnly,
                  onChanged: (_) => ref.read(settingsProvider.notifier).toggleViewOnly(),
                ),
              ]),

              const SizedBox(height: AppSpacing.xl),

              // Security — incoming access + default permissions (AnyDesk parity)
              _buildSectionHeader('Security'),
              _buildSettingsCard([
                _buildToggle(
                  label: 'Ask before allowing connections',
                  subtitle:
                      'Show an Accept / Dismiss prompt for incoming sessions',
                  value: settings.askOnConnect,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setAskOnConnect(v),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Sound on incoming connection',
                  subtitle: 'Play a sound when someone connects',
                  value: settings.soundOnConnect,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setSoundOnConnect(v),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Allow control by default',
                  subtitle: 'Let viewers use the keyboard and mouse',
                  value: settings.defaultAllowControl,
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .setDefaultPermission(control: v),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Share clipboard by default',
                  subtitle: 'Sync text, images and files',
                  value: settings.defaultAllowClipboard,
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .setDefaultPermission(clipboard: v),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Allow file transfer by default',
                  subtitle: 'Export / Import and clipboard files',
                  value: settings.defaultAllowFiles,
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .setDefaultPermission(files: v),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Lock this device on session end',
                  subtitle: 'Lock the screen when the last viewer disconnects',
                  value: settings.lockOnSessionEnd,
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .setLockOnSessionEnd(v),
                ),
              ]),

              const SizedBox(height: AppSpacing.xl),

              // Video Settings
              _buildSectionHeader('Video'),
              _buildSettingsCard([
                _buildSlider(
                  label: 'Bitrate',
                  value: settings.videoBitrate.toDouble(),
                  min: 500,
                  max: 5000,
                  divisions: 9,
                  suffix: 'kbps',
                  onChanged: (v) => ref.read(settingsProvider.notifier).updateVideoBitrate(v.toInt()),
                ),
                const Divider(),
                _buildSlider(
                  label: 'Frame Rate',
                  value: settings.videoFps.toDouble(),
                  min: 15,
                  max: 60,
                  divisions: 3,
                  suffix: 'fps',
                  onChanged: (v) => ref.read(settingsProvider.notifier).updateVideoFps(v.toInt()),
                ),
              ]),

              const SizedBox(height: AppSpacing.xl),

              // Agent Settings
              _buildSectionHeader('Agent'),
              _buildSettingsCard([
                _buildToggle(
                  label: 'Auto Answer',
                  subtitle: 'Automatically accept incoming connections',
                  value: settings.autoAnswer,
                  onChanged: (_) => ref.read(settingsProvider.notifier).toggleAutoAnswer(),
                ),
                const Divider(),
                _buildToggle(
                  label: 'Start on Boot',
                  subtitle: 'Launch agent when system starts',
                  value: settings.startOnBoot,
                  onChanged: (_) => ref.read(settingsProvider.notifier).toggleStartOnBoot(),
                ),
              ]),

              const SizedBox(height: AppSpacing.xl),

              // About
              _buildSectionHeader('About'),
              _buildSettingsCard([
                _buildInfoRow('Version', '1.0.0'),
                const Divider(),
                _buildInfoRow('Flutter', 'Desktop'),
                const Divider(),
                _buildInfoRow('WebRTC', 'Native'),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm, bottom: AppSpacing.sm),
      child: Text(
        title,
        style: AppTypography.heading2.copyWith(color: AppColors.primary),
      ),
    );
  }

  Widget _buildSettingsCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildToggle({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.body),
                const SizedBox(height: AppSpacing.xs),
                Text(subtitle, style: AppTypography.caption),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String suffix,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: AppTypography.body),
              Text(
                '${value.toInt()} $suffix',
                style: AppTypography.caption.copyWith(color: AppColors.primary),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            // ignore: deprecated_member_use
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.body),
          Text(value, style: AppTypography.body.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

/// Relay server URL field with an explicit Save button. Persists via
/// SharedPreferences and reconnects the host with the new address.
class _RelayUrlField extends ConsumerStatefulWidget {
  const _RelayUrlField();

  @override
  ConsumerState<_RelayUrlField> createState() => _RelayUrlFieldState();
}

class _RelayUrlFieldState extends ConsumerState<_RelayUrlField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: ref.read(settingsProvider).relayUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = normalizeRelayUrl(_controller.text);
    if (url.isEmpty) return;
    _controller.text = url;
    ref.read(settingsProvider.notifier).updateRelayUrl(url);
    // Reconnect the host with the new server address so it takes effect now.
    final service = ref.read(remoteServiceProvider);
    if (service.isHosting || service.hostStatus == HostStatus.error) {
      try {
        await service.startHosting(relayUrl: url);
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Relay URL saved'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Relay Server URL', style: AppTypography.body),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Address of your signaling server, e.g. ws://192.168.1.10:8080/ws',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'ws://server-ip:8080/ws',
                  ),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}