import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../control_pc/control_page.dart';
import '../../state/app_scope.dart';
import '../../state/settings_store.dart';

/// 设备列表页：LAN 组播发现（§6）+ 已配对设备。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  @override
  void initState() {
    super.initState();
    AppScope.read(context).devices.startDiscovery();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.devices,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(UuSpacing.lg),
        children: [
          UuSectionLabel(
            '局域网发现',
            trailing: TextButton.icon(
              onPressed: () => state.devices.startDiscovery(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ),
          if (state.devices.lanDevices.isEmpty)
            const UuCard(
              child: UuEmptyState(
                icon: Icons.wifi_tethering,
                text: '暂未发现设备',
                hint: '确认设备与本机在同一局域网\n组播 239.255.77.233:37723',
              ),
            )
          else
            UuGroup(
              children: [
                for (final d in state.devices.lanDevices)
                  _DeviceTile(
                    name: d.name.isEmpty ? d.deviceId : d.name,
                    subtitle: '${d.quicAddr} · ${d.deviceId}',
                    isPc: d.role == 'pc',
                    online: true,
                    onConnect: () => _connect(state,
                        d.address.isNotEmpty ? d.quicAddr : d.deviceId,
                        d.deviceId, d.name),
                  ),
              ],
            ),
          const SizedBox(height: UuSpacing.xl),
          UuSectionLabel(
            '已配对设备',
            trailing: Text(
              '${state.devices.paired.length} 台',
              style: const TextStyle(
                  fontSize: 12, color: UuColors.textTertiary),
            ),
          ),
          if (state.devices.paired.isEmpty)
            const UuCard(
              child: UuEmptyState(
                icon: Icons.link_off,
                text: '暂无已配对设备',
                hint: '在「配对」页输入对方 6 位配对码完成绑定',
              ),
            )
          else
            UuGroup(
              children: [
                for (final d in state.devices.paired)
                  _DeviceTile(
                    name: d.name,
                    subtitle: d.deviceId,
                    isPc: true,
                    online: false,
                    onConnect: () =>
                        _connect(state, d.lastAddr ?? d.deviceId, d.deviceId, d.name),
                    onRemove: () => state.settings.removePaired(d.deviceId),
                  ),
              ],
            ),
          const SizedBox(height: UuSpacing.xl),
          OutlinedButton.icon(
            onPressed: () async {
              await state.session.startMockController('mock://demo-pc');
              if (mounted) _openControl();
            },
            icon: const Icon(Icons.bolt_outlined, size: 18),
            label: const Text('使用演示通道连接（mock）'),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(AppState state, String addr, String pin, String name) async {
    final messenger = ScaffoldMessenger.of(context);
    await state.session.startController(addr, peerPin: pin);
    if (!mounted) return;
    state.settings.addPaired(PairedDevice(
        deviceId: pin, name: name.isEmpty ? pin : name, role: 'pc', lastAddr: addr));
    if (state.session.isActive) {
      _openControl();
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text(state.session.statusText.isEmpty
              ? '连接 $name 失败'
              : state.session.statusText)));
    }
  }

  /// 连接成功后进入全屏远程控制页（原底部「控制」标签已移除）。
  void _openControl() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('控制 PC')),
              body: const ControlPage(),
            )));
  }
}

class _DeviceTile extends StatelessWidget {
  final String name;
  final String subtitle;
  final bool isPc;
  final bool online;
  final VoidCallback onConnect;
  final VoidCallback? onRemove;

  const _DeviceTile({
    required this.name,
    required this.subtitle,
    required this.isPc,
    required this.online,
    required this.onConnect,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          UuIconBubble(
            isPc ? Icons.desktop_windows : Icons.phone_android,
            color: isPc ? UuColors.primary : UuColors.success,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge),
                    ),
                    const SizedBox(width: 6),
                    UuStatusChip(
                      online ? '在线' : '离线',
                      color: online ? UuColors.success : UuColors.textTertiary,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 34),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500),
            ),
            onPressed: onConnect,
            child: const Text('连接'),
          ),
          if (onRemove != null)
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  size: 20, color: UuColors.textTertiary),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
