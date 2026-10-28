import 'package:flutter/material.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../../state/app_scope.dart';

/// 设置页：服务器地址、device_id/证书目录、剪贴板同步开关。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _server;
  late final TextEditingController _deviceId;
  late final TextEditingController _deviceName;
  late final TextEditingController _certDir;
  late bool _clipboardSync;

  @override
  void initState() {
    super.initState();
    final s = AppScope.read(context).settings;
    _server = TextEditingController(text: s.serverUrl);
    _deviceId = TextEditingController(text: s.deviceId);
    _deviceName = TextEditingController(text: s.deviceName);
    _certDir = TextEditingController(text: s.certDir);
    _clipboardSync = s.clipboardSync;
  }

  @override
  void dispose() {
    _server.dispose();
    _deviceId.dispose();
    _deviceName.dispose();
    _certDir.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(UuSpacing.lg),
      children: [
        const UuSectionLabel('连接配置'),
        UuGroup(
          children: [
            _FieldTile(
              label: '信令服务器地址',
              helper: '如 https://signal.example.com',
              controller: _server,
            ),
            SwitchListTile(
              title: const Text('剪贴板同步'),
              subtitle: const Text('§3.4 clip_set 双向同步'),
              value: _clipboardSync,
              onChanged: (v) => setState(() => _clipboardSync = v),
            ),
          ],
        ),
        const SizedBox(height: UuSpacing.xl),
        const UuSectionLabel('设备信息'),
        UuGroup(
          children: [
            _FieldTile(label: '设备名称', controller: _deviceName),
            _FieldTile(
              label: 'device_id',
              helper: '§1 base32(SHA256(SPKI)) 前 16 字符，证书由 uu-ffi 侧生成',
              controller: _deviceId,
            ),
            _FieldTile(
              label: '证书目录',
              helper: 'uu_ffi_new config.cert_dir',
              controller: _certDir,
            ),
          ],
        ),
        const SizedBox(height: UuSpacing.xl),
        FilledButton(
          onPressed: () {
            state.settings.update(
              serverUrl: _server.text.trim(),
              deviceId: _deviceId.text.trim(),
              deviceName: _deviceName.text.trim(),
              certDir: _certDir.text.trim(),
              clipboardSync: _clipboardSync,
            );
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('已保存')));
          },
          child: const Text('保存设置'),
        ),
      ],
    );
  }
}

/// 分组内文本输入行：左标签 + 输入框。
class _FieldTile extends StatelessWidget {
  final String label;
  final String? helper;
  final TextEditingController controller;

  const _FieldTile({
    required this.label,
    required this.controller,
    this.helper,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: UuColors.textPrimary)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: helper == null ? '请输入' : null,
              isDense: true,
              filled: true,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 6),
            Text(helper!,
                style: const TextStyle(
                    fontSize: 11, color: UuColors.textTertiary)),
          ],
        ],
      ),
    );
  }
}
