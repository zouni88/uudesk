import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../../state/app_scope.dart';
import '../../state/file_transfer_store.dart';

/// 文件双向传输页（§3.6/§7）：file_offer/accept + 进度。
class FilesPage extends StatelessWidget {
  const FilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.files,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _pickAndOffer(state),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('发送文件到 PC'),
                  ),
                ),
                if (state.session.mockSimulator != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => state.session.mockSimulator!.sendDemoFile(),
                    child: const Text('演示来件'),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: state.files.tasks.isEmpty
                ? const UuEmptyState(
                    icon: Icons.folder_open,
                    text: '暂无传输任务',
                    hint: '选择文件发送到已连接的 PC，\nPC 发来的文件也会出现在这里',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: state.files.tasks.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UuSpacing.sm),
                    itemBuilder: (context, i) =>
                        _TaskCard(task: state.files.tasks[i], files: state.files),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndOffer(AppState state) async {
    if (!state.session.isActive) {
      await state.session.startMockController('mock://pc');
    }
    final picked = await FilePicker.pickFiles();
    if (picked.isEmpty) return;
    final path = picked.single.path;
    if (path == null) return;
    await state.files.offerFile(File(path));
  }
}

class _TaskCard extends StatelessWidget {
  final TransferTask task;
  final FileTransferStore files;

  const _TaskCard({required this.task, required this.files});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outgoing = task.direction == TransferDirection.outgoing;
    final (chipColor, chipText) = switch (task.state) {
      TransferState.offering => (UuColors.warning, '等待对方接受'),
      TransferState.waitingAccept => (UuColors.primary, '待接受'),
      TransferState.running => (UuColors.primary, '传输中'),
      TransferState.done => (UuColors.success, '已完成'),
      TransferState.rejected => (UuColors.textTertiary, '已拒绝'),
      TransferState.failed => (UuColors.danger, '失败'),
    };
    return UuCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UuIconBubble(
                outgoing ? Icons.upload : Icons.download,
                color: outgoing ? UuColors.primary : UuColors.success,
                size: 36,
              ),
              const SizedBox(width: UuSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(task.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text('${_fmt(task.transferred)} / ${_fmt(task.size)}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              UuStatusChip(chipText, color: chipColor),
            ],
          ),
          if (task.state == TransferState.running) ...[
            const SizedBox(height: UuSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                  value: task.progress, minHeight: 5),
            ),
          ],
          if (task.savePath != null) ...[
            const SizedBox(height: UuSpacing.sm),
            Row(
              children: [
                const Icon(Icons.save_alt,
                    size: 14, color: UuColors.textTertiary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(task.savePath!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: UuColors.textTertiary)),
                ),
              ],
            ),
          ],
          if (task.state == TransferState.waitingAccept) ...[
            const SizedBox(height: UuSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => files.rejectIncoming(task.id),
                    child: const Text('拒绝'),
                  ),
                ),
                const SizedBox(width: UuSpacing.md),
                Expanded(
                  child: FilledButton(
                    onPressed: () => files.acceptIncoming(task.id),
                    child: const Text('接收'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
