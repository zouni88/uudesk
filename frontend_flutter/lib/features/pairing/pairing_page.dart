import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../control_pc/control_page.dart';
import '../../state/app_scope.dart';
import 'pairing_controller.dart';

/// 配对页：显示本机 6 位码 / 输入对方码连接（§8）。
class PairingPage extends StatefulWidget {
  const PairingPage({super.key});

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  late final PairingController _ctrl;
  late final AppState _state;
  final _codeInput = TextEditingController();
  bool _controlPushed = false;

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _ctrl = PairingController(settings: _state.settings, session: _state.session);
    _ctrl.refreshLocalCode();
    // 配对打洞/中继是异步完成的：会话就绪后进入全屏控制页。
    _state.session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (_controlPushed || !_state.session.isActive || !mounted) return;
    _controlPushed = true;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('控制 PC')),
              body: const ControlPage(),
            )));
  }

  @override
  void dispose() {
    _state.session.removeListener(_onSessionChanged);
    _ctrl.dispose();
    _codeInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.all(UuSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const UuSectionLabel('本机配对码'),
            UuCard(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: Column(
                children: [
                  _ctrl.busy && _ctrl.localCode.isEmpty
                      ? const SizedBox(
                          height: 52,
                          child: Center(child: CircularProgressIndicator()))
                      : UuCodeBoxes(code: _ctrl.localCode),
                  const SizedBox(height: UuSpacing.md),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_ctrl.status, style: theme.textTheme.bodySmall),
                      const SizedBox(width: UuSpacing.sm),
                      if (_ctrl.localCode.isNotEmpty)
                        TextButton(
                          onPressed: _ctrl.busy ? null : _ctrl.refreshLocalCode,
                          child: const Text('刷新'),
                        ),
                      if (_ctrl.localCode.isNotEmpty)
                        TextButton(
                          onPressed: _ctrl.revokeCode,
                          style: TextButton.styleFrom(
                              foregroundColor: UuColors.danger),
                          child: const Text('撤销'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (_ctrl.pendingInvite case final inv?) ...[
              const SizedBox(height: UuSpacing.md),
              UuCard(
                color: const Color(0xFFE1E8FF),
                padding: const EdgeInsets.all(UuSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const UuIconBubble(Icons.person_add_alt_1,
                            color: UuColors.primary, size: 36),
                        const SizedBox(width: UuSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('来自 ${inv['from']} 的连接请求',
                                  style: theme.textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                  '设备 ID：${inv['device_id'] ?? ''} · 将用于 SPKI pin 校验',
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UuSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _ctrl.answerInvite(false),
                            child: const Text('拒绝'),
                          ),
                        ),
                        const SizedBox(width: UuSpacing.md),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => _ctrl.answerInvite(true),
                            child: const Text('接受'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: UuSpacing.xl),
            const UuSectionLabel('连接对方设备'),
            UuCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _codeInput,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 4),
                    decoration: const InputDecoration(
                      labelText: '对方 6 位配对码',
                      counterText: '',
                      prefixIcon: Icon(Icons.key_outlined, size: 20),
                    ),
                  ),
                  const SizedBox(height: UuSpacing.lg),
                  FilledButton.icon(
                    onPressed: _ctrl.busy
                        ? null
                        : () => _ctrl.connectWithCode(_codeInput.text.trim()),
                    icon: const Icon(Icons.link),
                    label: const Text('配对并连接'),
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
