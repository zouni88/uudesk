// 入会排障日志直接打到控制台。
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/ui/theme.dart';
import '../../core/ui/widgets.dart';
import '../../state/app_scope.dart';
import 'meeting_room_page.dart';

/// 会议加入页（§10）：服务器地址（默认取设置）+ 房间号 + 显示名。
class MeetingJoinPage extends StatefulWidget {
  const MeetingJoinPage({super.key});

  @override
  State<MeetingJoinPage> createState() => _MeetingJoinPageState();
}

class _MeetingJoinPageState extends State<MeetingJoinPage> {
  final _serverCtrl = TextEditingController();
  final _roomCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  bool _prefilled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final settings = AppScope.of(context).settings;
    _serverCtrl.text = settings.serverUrl;
    _roomCtrl.text = 'test';
    _nameCtrl.text = settings.deviceName.isNotEmpty
        ? settings.deviceName
        : settings.deviceId;
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _roomCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final state = AppScope.of(context);
    final room = _roomCtrl.text.trim();
    final server = _serverCtrl.text.trim();
    final name = _nameCtrl.text.trim();
    if (room.isEmpty || server.isEmpty) {
      _toast('请填写服务器地址与房间号');
      return;
    }
    setState(() => _busy = true);
    try {
      // Android 运行时权限：入会默认开麦，麦克风必须授权；摄像头可拒绝（仅影响视频）。
      if (!(await Permission.microphone.request()).isGranted) {
        if (mounted) _toast('未授予麦克风权限，无法入会');
        return;
      }
      await Permission.camera.request();
      await state.meeting.join(
        serverUrl: server,
        room: room,
        identity: state.settings.deviceId,
        displayName: name.isEmpty ? state.settings.deviceId : name,
      );
      // 记录会话：共享屏幕/切后台可能导致 Activity 或 Flutter 引擎被系统重建，
      // 重建后由外壳自动重新入会并回到会议页。
      await state.settings.saveMeetingSession(
        room: room,
        server: server,
        name: name.isEmpty ? state.settings.deviceId : name,
        micOn: state.meeting.micOn,
        camOn: state.meeting.camOn,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => Theme(data: uuDarkTheme(), child: const MeetingRoomPage())));
    } catch (e) {
      print('[meeting] join page failed: $e');
      if (mounted) _toast('入会失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _backToRoom() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Theme(data: uuDarkTheme(), child: const MeetingRoomPage())));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meeting = AppScope.of(context).meeting;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(UuSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _HeroCard(),
          const SizedBox(height: UuSpacing.xl),
          UuCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _serverCtrl,
                  decoration: const InputDecoration(
                    labelText: '信令服务器地址',
                    prefixIcon: Icon(Icons.dns_outlined, size: 20),
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: UuSpacing.md),
                TextField(
                  controller: _roomCtrl,
                  decoration: const InputDecoration(
                    labelText: '房间号',
                    prefixIcon: Icon(Icons.meeting_room_outlined, size: 20),
                  ),
                ),
                const SizedBox(height: UuSpacing.md),
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '显示名',
                    prefixIcon: Icon(Icons.person_outline, size: 20),
                  ),
                ),
                const SizedBox(height: UuSpacing.lg),
                FilledButton.icon(
                  onPressed: _busy ? null : _join,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.videocam),
                  label: Text(_busy ? '连接中…' : '加入会议'),
                ),
              ],
            ),
          ),
          if (meeting.inMeeting) ...[
            const SizedBox(height: UuSpacing.md),
            UuCard(
              onTap: _backToRoom,
              padding: const EdgeInsets.symmetric(
                  horizontal: UuSpacing.lg, vertical: UuSpacing.sm),
              child: Row(
                children: [
                  const UuIconBubble(Icons.meeting_room,
                      color: UuColors.success, size: 36),
                  const SizedBox(width: UuSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('已在房间 ${meeting.roomName}',
                            style: theme.textTheme.bodyLarge),
                        Text(meeting.connected ? '通话进行中' : '连接中…',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const UuStatusChip('进行中', color: UuColors.success),
                  const SizedBox(width: UuSpacing.xs),
                  const Icon(Icons.chevron_right,
                      size: 20, color: UuColors.textTertiary),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 顶部品牌渐变头卡。
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UuSpacing.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UuRadius.lg),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3370FF), Color(0xFF5B8CFF)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(UuRadius.md),
                ),
                child: const Icon(Icons.videocam, color: Colors.white, size: 24),
              ),
              const SizedBox(width: UuSpacing.md),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('多人会议',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    SizedBox(height: 2),
                    Text('自托管 LiveKit · 无时长限制',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xCCFFFFFF))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UuSpacing.lg),
          Row(
            children: [
              for (final f in const [
                ('👥', '多人音视频'),
                ('🖥', '屏幕共享'),
                ('💬', '会中聊天'),
              ])
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(right: UuSpacing.sm),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(UuRadius.md),
                    ),
                    child: Column(
                      children: [
                        Text(f.$1, style: const TextStyle(fontSize: 16)),
                        const SizedBox(height: 2),
                        Text(f.$2,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xE6FFFFFF))),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
