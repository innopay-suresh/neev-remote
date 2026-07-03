import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/file_transfer_service.dart';
import '../../data/services/remote_service.dart';

String _fmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

/// Opens a native file picker and sends the chosen file to the connected peer.
Future<void> pickAndSendFile(BuildContext context, RemoteService service) async {
  final XFile? file = await openFile();
  if (file == null) return;
  final bytes = await file.readAsBytes();
  final t = await service.sendFile(file.name, bytes);
  if (t == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File is too large (200 MB max)')),
    );
  }
}

/// Export (send a file to the other computer) + Import (ask the other computer
/// to send you a file) buttons.
class FileShareButtons extends StatelessWidget {
  final RemoteService service;
  final bool dense;
  const FileShareButtons({super.key, required this.service, this.dense = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Send a file to the connected computer',
          child: OutlinedButton.icon(
            onPressed: () => pickAndSendFile(context, service),
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Export'),
          ),
        ),
        SizedBox(width: dense ? 6 : 8),
        Tooltip(
          message: 'Ask the connected computer to send you a file',
          child: OutlinedButton.icon(
            onPressed: () {
              service.requestFileFromPeer();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Import requested — the other computer picks a file to send'),
                duration: Duration(seconds: 3),
              ));
            },
            icon: const Icon(Icons.download_for_offline_outlined, size: 18),
            label: const Text('Import'),
          ),
        ),
      ],
    );
  }
}

/// A floating card listing active + recent transfers. Renders nothing when
/// there are none, so it can be dropped into a Stack unconditionally.
class FileTransferList extends StatelessWidget {
  final RemoteService service;
  const FileTransferList({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final transfers = service.fileTransfers;
    if (transfers.isEmpty) return const SizedBox.shrink();
    final anyDone = transfers.any((t) => t.status != FileStatus.active);
    return Container(
      width: 320,
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
            child: Row(
              children: [
                const Icon(Icons.swap_vert, size: 16),
                const SizedBox(width: 6),
                const Text('File transfers',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const Spacer(),
                if (anyDone)
                  TextButton(
                    onPressed: service.clearFinishedTransfers,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28)),
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              itemCount: transfers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _TransferTile(t: transfers[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransferTile extends StatelessWidget {
  final FileTransfer t;
  const _TransferTile({required this.t});

  @override
  Widget build(BuildContext context) {
    final incoming = t.direction == FileDirection.incoming;
    final subtitle = switch (t.status) {
      FileStatus.error => t.error ?? 'Failed',
      FileStatus.done => incoming
          ? (t.savedPath != null ? 'Saved to Downloads/NeevRemote' : 'Received')
          : 'Sent',
      FileStatus.active =>
        '${_fmtBytes(t.transferred)} / ${_fmtBytes(t.size)}',
    };
    final subColor = t.status == FileStatus.error
        ? AppColors.error
        : AppColors.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(incoming ? Icons.download : Icons.upload,
            size: 16, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 3),
              if (t.status == FileStatus.active)
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                      value: t.size > 0 ? t.progress : null, minHeight: 4),
                ),
              const SizedBox(height: 2),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: subColor)),
            ],
          ),
        ),
      ],
    );
  }
}
