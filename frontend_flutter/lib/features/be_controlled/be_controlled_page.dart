import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../../state/app_scope.dart';
import '../../state/session_store.dart';

/// 被 PC 控页（Android）：MediaProjection 采集启停、无障碍注入状态、
/// cap_start/cap_stop 处理（§3.5，路由见 SessionStore）。
class BeControlledPage extends StatefulWidget {
  const BeControlledPage({super.key});

  @override
  State<BeControlledPage> createState() => _BeControlledPageState();
}

class _BeControlledPageState extends State<BeControlledPage> {
  bool _captureOn = false;
  String _captureMsg = '';

  @override
  void initState() {
    super.initState();
    AppScope.read(context).projection.watchAccessibility();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final session = state.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(UuSpacing.lg),
        children: [
          _StatusCard(
            title: '会话状态',
            icon: session.role == SessionRole.controlled
                ? Icons.screen_share
                : Icons.share_outlined,
            iconColor: session.role == SessionRole.controlled
                ? UuColors.success
                : UuColors.textTertiary,
            statusText: session.role == SessionRole.controlled ? '被控中' : '未开始',
            statusColor: session.role == SessionRole.controlled
                ? UuColors.success
                : UuColors.textTertiary,
            lines: [session.statusText],
          ),
          const SizedBox(height: UuSpacing.md),
          _StatusCard(
            title: '屏幕采集（MediaProjection）',
            icon: _captureOn
                ? Icons.screenshot_monitor
                : Icons.stop_screen_share_outlined,
            iconColor: _captureOn ? UuColors.primary : UuColors.textTertiary,
            statusText: _captureOn ? '采集中' : '未采集',
            statusColor: _captureOn ? UuColors.primary : UuColors.textTertiary,
            lines: [
              _captureMsg.isEmpty
                  ? (_captureOn ? '采集中，向 PC 推流' : '开始采集后可被 PC 端查看画面')
                  : _captureMsg
            ],
            action: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(88, 36),
                backgroundColor: _captureOn ? UuColors.danger : UuColors.primary,
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500),
              ),
              onPressed: () async {
                final ok = _captureOn
                    ? await state.projection.stopCapture()
                    : await state.projection.startCapture();
                setState(() {
                  _captureOn = ok;
                  _captureMsg = ok ? '' : '采集未授权（3001）或原生服务不可用';
                });
              },
              child: Text(_captureOn ? '停止' : '开始采集'),
            ),
          ),
          const SizedBox(height: UuSpacing.md),
          _StatusCard(
            title: '无障碍注入',
            icon: Icons.accessibility_new,
            iconColor: state.projection.accessibilityReady
                ? UuColors.success
                : UuColors.warning,
            statusText: state.projection.accessibilityReady ? '已就绪' : '未开启',
            statusColor: state.projection.accessibilityReady
                ? UuColors.success
                : UuColors.warning,
            lines: [
              state.projection.accessibilityReady
                  ? 'UuAccessibilityService 已就绪，可接收 PC 端手势注入'
                  : '未在系统设置中开启或原生服务未运行'
            ],
            action: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(72, 36),
                textStyle: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500),
              ),
              onPressed: () => setState(() {}),
              child: const Text('刷新'),
            ),
          ),
          const SizedBox(height: UuSpacing.lg),
          OutlinedButton.icon(
            onPressed: () => session.startControlled(),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('进入被控演示（mock 信令）'),
          ),
          const SizedBox(height: UuSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'PC 侧发送 cap_start/cap_stop 时自动启停采集；'
              'input 指令经无障碍服务 dispatchGesture 注入。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: UuColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final String statusText;
  final Color statusColor;
  final List<String> lines;
  final Widget? action;

  const _StatusCard({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.statusText,
    required this.statusColor,
    required this.lines,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UuCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          UuIconBubble(icon, color: iconColor),
          const SizedBox(width: UuSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 6),
                    UuStatusChip(statusText, color: statusColor),
                  ],
                ),
                const SizedBox(height: 3),
                for (final l in lines)
                  Text(l,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: UuColors.textSecondary)),
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: UuSpacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}
