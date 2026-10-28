import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/meeting/meeting_service.dart';
import '../../core/ui/theme.dart';
import '../../state/app_scope.dart';
import 'meeting_panels.dart';
import 'meeting_video_grid.dart';

/// 会议房间页（§10.3）：视频宫格/演讲者视图 + 控制条 + 聊天/成员抽屉。
class MeetingRoomPage extends StatefulWidget {
  const MeetingRoomPage({super.key});

  @override
  State<MeetingRoomPage> createState() => _MeetingRoomPageState();
}

class _MeetingRoomPageState extends State<MeetingRoomPage> {
  late final MeetingService _meeting;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _ticker;
  bool _chatOpen = false;
  int _lastUnread = 0;
  bool _leaving = false;
  bool _recBusy = false;

  static const _reactionEmojis = ['👍', '👏', '😂', '🎉'];

  @override
  void initState() {
    super.initState();
    _meeting = AppScope.read(context).meeting;
    _meeting.addListener(_onMeetingChanged);
    // 每秒刷新会议时长与反应浮层过期。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _meeting.removeListener(_onMeetingChanged);
    super.dispose();
  }

  void _onMeetingChanged() {
    if (!mounted) return;
    // 新未读消息且聊天面板未打开 → toast 提示。
    if (_meeting.unreadChat > _lastUnread && !_chatOpen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('收到新消息'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
    _lastUnread = _meeting.unreadChat;
    setState(() {});
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _toggleScreenShare() async {
    final state = AppScope.read(context);
    final projection = state.projection;
    // Android MediaProjection 同一时刻只允许一个采集者：被控采集进行中则互斥。
    if (state.session.projection.capturing) {
      _toast('被控端屏幕采集进行中，无法同时开启会议屏幕共享');
      return;
    }
    final turningOn = !_meeting.screenOn;
    // 共享前先起保活前台服务：Android 14+ 前置要求，且避免共享期间进程被回收。
    if (turningOn) await projection.startShareKeepAlive();
    try {
      await _meeting.toggleScreenShare();
    } catch (e) {
      if (turningOn) await projection.stopShareKeepAlive();
      _toast('屏幕共享失败：$e');
      return;
    }
    if (!_meeting.screenOn) await projection.stopShareKeepAlive();
  }

  Future<void> _leave() async {
    if (_leaving || !mounted) return;
    final state = AppScope.read(context);
    final settings = state.settings;
    final projection = state.projection;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开会议'),
        content: const Text('确定要离开当前会议吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('离开'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _leaving = true;
    await _meeting.leave();
    // 关闭共享保活前台服务，并清除可恢复会话：下次启动不再自动入会。
    await projection.stopShareKeepAlive();
    await settings.clearMeetingSession();
    if (mounted) Navigator.of(context).pop();
  }

  String _durationText() {
    final j = _meeting.joinedAt;
    if (j == null) return '--:--';
    final d = DateTime.now().difference(j);
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _meeting,
      builder: (context, _) {
        return PopScope(
          // 拦系统返回：先确认离开并真正断开，避免留下“幽灵参会者”
          canPop: _leaving,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _leave();
          },
          child: Scaffold(
            key: _scaffoldKey,
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _meeting.roomName.isEmpty ? '会议' : _meeting.roomName,
                    style: theme.textTheme.titleMedium,
                  ),
                  Row(
                    children: [
                      Text(
                        _meeting.reconnecting
                            ? '正在重连…'
                            : (_meeting.connected
                                  ? _durationText()
                                  : (_meeting.lastError ?? '连接中…')),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: UuColors.darkTextSecondary,
                        ),
                      ),
                      if (_meeting.recording) ...[
                        const SizedBox(width: 8),
                        const PulseDot(color: Color(0xFFFF1744)),
                        const SizedBox(width: 4),
                        Text(
                          'REC',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFFFF5252),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: _meeting.recording ? '停止录制' : '开始录制',
                  icon: _recBusy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _meeting.recording
                              ? Icons.fiber_manual_record
                              : Icons.trip_origin,
                        ),
                  onPressed: _recBusy
                      ? null
                      : () async {
                          setState(() => _recBusy = true);
                          try {
                            if (_meeting.recording) {
                              await _meeting.stopRecording();
                            } else {
                              await _meeting.startRecording();
                            }
                          } catch (e) {
                            _toast('录制操作失败：$e');
                          } finally {
                            if (mounted) setState(() => _recBusy = false);
                          }
                        },
                ),
              ],
            ),
            drawer: MeetingMembersPanel(service: _meeting),
            endDrawer: MeetingChatPanel(service: _meeting),
            onEndDrawerChanged: (open) {
              _chatOpen = open;
              if (open) _meeting.markChatRead();
            },
            body: Stack(
              children: [
                Column(
                  children: [
                    if (_meeting.screenOn &&
                        _meeting.controlRequests.isNotEmpty)
                      _controlRequestBanner(),
                    Expanded(
                      child: _meeting.inMeeting
                          ? MeetingVideoArea(
                              members: _meeting.members,
                              service: _meeting,
                            )
                          : Center(
                              child: Text(
                                _meeting.lastError ?? '已离开会议',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                    ),
                    _controlBar(context),
                  ],
                ),
                _reactionsOverlay(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 共享者侧：观看方请求控制屏幕的横幅（§10.4，同意/拒绝）。
  Widget _controlRequestBanner() {
    final entry = _meeting.controlRequests.entries.first;
    return Material(
      color: UuColors.primary,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.mouse, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${entry.value} 请求控制你的屏幕',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => _meeting.rejectControl(entry.key),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: UuColors.primary,
                ),
                onPressed: () => _meeting.grantControl(entry.key),
                child: const Text('同意'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 最近 4 秒内的表情反应浮层（左下角气泡）。
  Widget _reactionsOverlay() {
    final now = DateTime.now();
    final fresh = _meeting.reactions
        .where((r) => now.difference(r.ts).inMilliseconds < 4000)
        .toList();
    if (fresh.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      // 避开底部控制条与系统手势区，避免表情气泡压住按钮
      bottom: MediaQuery.paddingOf(context).bottom + 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in fresh.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${r.emoji} ${r.name}',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controlBar(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: UuColors.darkBar,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CtrlButton(
              icon: _meeting.micOn ? Icons.mic : Icons.mic_off,
              label: _meeting.micOn ? '静音' : '已静音',
              iconColor: _meeting.micOn ? null : UuColors.danger,
              onPressed: () async {
                try {
                  await _meeting.toggleMic();
                } catch (e) {
                  _toast('麦克风切换失败：$e');
                }
              },
            ),
            _CtrlButton(
              icon: _meeting.camOn ? Icons.videocam : Icons.videocam_off,
              label: _meeting.camOn ? '视频' : '已关闭',
              iconColor: _meeting.camOn ? null : UuColors.danger,
              onPressed: () async {
                if (!_meeting.camOn &&
                    !(await Permission.camera.request()).isGranted) {
                  _toast('未授予摄像头权限');
                  return;
                }
                try {
                  await _meeting.toggleCamera();
                } catch (e) {
                  _toast('摄像头切换失败：$e');
                }
              },
            ),
            _CtrlButton(
              icon: Icons.screen_share,
              label: '共享',
              bgColor: _meeting.screenOn ? UuColors.primary : null,
              onPressed: _toggleScreenShare,
            ),
            _CtrlButton(
              icon: Icons.back_hand,
              label: '举手',
              bgColor: _meeting.selfHandRaised ? UuColors.warning : null,
              iconColor: _meeting.selfHandRaised ? UuColors.textPrimary : null,
              onPressed: () async {
                try {
                  await _meeting.setHandRaised(!_meeting.selfHandRaised);
                } catch (e) {
                  _toast('举手失败：$e');
                }
              },
            ),
            _CtrlButton(
              icon: Icons.more_horiz,
              label: '更多',
              badge: _meeting.unreadChat,
              onPressed: _showMoreSheet,
            ),
            _CtrlButton(
              icon: Icons.call_end,
              label: '离开',
              bgColor: UuColors.danger,
              iconColor: Colors.white,
              onPressed: _leave,
            ),
          ],
        ),
      ),
    );
  }

  /// 更多面板：表情反应 + 聊天 + 成员（飞书式收纳）。
  void _showMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: UuColors.darkCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(UuRadius.xl)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final e in _reactionEmojis)
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _meeting.sendReaction(e);
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        color: UuColors.darkBg,
                        shape: BoxShape.circle,
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1, color: UuColors.darkLine),
            ListTile(
              leading: const Icon(
                Icons.chat_bubble_outline,
                color: UuColors.darkText,
              ),
              title: Text(
                _meeting.unreadChat > 0
                    ? '聊天（${_meeting.unreadChat} 条未读）'
                    : '聊天',
                style: const TextStyle(color: UuColors.darkText),
              ),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _scaffoldKey.currentState?.openEndDrawer();
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.groups_outlined,
                color: UuColors.darkText,
              ),
              title: Text(
                '成员（${_meeting.members.length}）',
                style: const TextStyle(color: UuColors.darkText),
              ),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _scaffoldKey.currentState?.openDrawer();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// 录制红点脉冲动画。
class PulseDot extends StatefulWidget {
  final Color color;
  const PulseDot({super.key, this.color = const Color(0xFFFF1744)});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.25, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 控制条圆角方形按钮（飞书式，可选中底色/未读角标）。
class _CtrlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;
  final Color? bgColor;
  final int badge;
  final VoidCallback onPressed;

  const _CtrlButton({
    required this.icon,
    required this.label,
    this.iconColor,
    this.bgColor,
    this.badge = 0,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: bgColor ?? UuColors.darkCard,
                borderRadius: BorderRadius.circular(UuRadius.lg),
              ),
              child: IconButton(
                iconSize: 22,
                padding: EdgeInsets.zero,
                splashColor: Colors.white12,
                highlightColor: Colors.white12,
                icon: Icon(icon, color: iconColor ?? UuColors.darkText),
                onPressed: onPressed,
              ),
            ),
            if (badge > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: UuColors.danger,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: UuColors.darkBar, width: 1.5),
                  ),
                  child: Text(
                    '$badge',
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: UuColors.darkTextSecondary,
          ),
        ),
      ],
    );
  }
}
