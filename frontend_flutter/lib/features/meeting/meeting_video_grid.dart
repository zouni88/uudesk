import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../core/meeting/meeting_models.dart';
import '../../core/meeting/meeting_service.dart';
import '../../core/protocol/control_messages.dart';
import '../../core/ui/theme.dart';

/// 会议画面区：有人共享屏幕 → 演讲者视图；否则成员视频宫格。
class MeetingVideoArea extends StatelessWidget {
  final List<MeetingMember> members;
  final MeetingService service;

  const MeetingVideoArea({
    super.key,
    required this.members,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    final share = members.firstWhereOrNull(
        (m) => m.shareTrack != null);
    if (share == null) return _grid(context);
    return _speakerView(context, share);
  }

  /// 自适应宫格：1 人 1 列，≤4 人 2 列，其余 3 列。
  Widget _grid(BuildContext context) {
    final cols = members.length <= 1
        ? 1
        : (members.length <= 4 ? 2 : 3);
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 3 / 4,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: members.length,
      itemBuilder: (context, i) => MemberTile(member: members[i]),
    );
  }

  /// 演讲者视图：大画面 = 共享流，底部小条 = 成员缩略，右上悬浮本端预览。
  Widget _speakerView(BuildContext context, MeetingMember sharer) {
    final self = members.where((m) => m.isSelf).firstOrNull;
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ShareTile(member: sharer, service: service),
              if (self != null)
                Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox(
                    width: 108,
                    height: 144,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: MemberTile(member: self, compact: true),
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            itemCount: members.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) => SizedBox(
              width: 72,
              child: MemberTile(member: members[i], compact: true),
            ),
          ),
        ),
      ],
    );
  }
}

/// 共享大画面格。含会中控制交互（§10.4）：
/// 观看方获授权后手势直接注入共享者；未获授权可「请求控制」。
class _ShareTile extends StatelessWidget {
  final MeetingMember member;
  final MeetingService service;

  const _ShareTile({required this.member, required this.service});

  @override
  Widget build(BuildContext context) {
    final controlling =
        !member.isSelf && service.controlSharer == member.identity;
    final grantedAsSharer = member.isSelf &&
        service.screenOn &&
        service.controlGranted.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: UuColors.darkCard,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoTrackRenderer(member.shareTrack!),
              if (controlling) _gestureLayer(),
              Positioned(
                left: 8,
                bottom: 8,
                child: _NameChip(
                    text: '屏幕共享 · ${member.name}', speaking: false),
              ),
              Positioned(
                left: 8,
                top: 8,
                child: _controlBadge(context, controlling, grantedAsSharer),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 手势 → 归一化坐标 input 消息（§3.2），经会中控制通道发往共享者。
  Widget _gestureLayer() {
    return LayoutBuilder(builder: (context, box) {
      double nx(Offset p) => (p.dx / box.maxWidth).clamp(0.0, 1.0);
      double ny(Offset p) => (p.dy / box.maxHeight).clamp(0.0, 1.0);
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          service.sendControlInput(UuMsg.inputDown(nx(e.localPosition), ny(e.localPosition)));
          service.sendControlInput(UuMsg.inputMove(nx(e.localPosition), ny(e.localPosition)));
        },
        onPointerMove: (e) => service
            .sendControlInput(UuMsg.inputMove(nx(e.localPosition), ny(e.localPosition))),
        onPointerUp: (e) => service
            .sendControlInput(UuMsg.inputUp(nx(e.localPosition), ny(e.localPosition))),
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            service.sendControlInput(UuMsg.inputScroll(
                nx(e.localPosition), ny(e.localPosition), 0, -e.scrollDelta.dy / 100.0));
          }
        },
        child: const SizedBox.expand(),
      );
    });
  }

  Widget _controlBadge(
      BuildContext context, bool controlling, bool grantedAsSharer) {
    if (controlling) {
      return _CtrlChip(
        text: '控制中',
        color: UuColors.success,
        actionLabel: '退出',
        onAction: service.releaseControl,
      );
    }
    if (grantedAsSharer) {
      return _CtrlChip(
        text: '${service.controlGranted.length} 人控制中',
        color: UuColors.warning,
        actionLabel: '收回',
        onAction: () {
          for (final v in service.controlGranted.toList()) {
            service.revokeControl(v);
          }
        },
      );
    }
    if (!member.isSelf) {
      return _CtrlChip(
        text: null,
        color: UuColors.primary,
        actionLabel: service.controlSharer == null ? '请求控制' : '等待授权…',
        onAction: service.controlSharer == null
            ? () => service.requestControl(member.identity)
            : null,
      );
    }
    return const SizedBox.shrink();
  }
}

/// 共享画面上的控制状态胶囊（状态文字 + 可选动作）。
class _CtrlChip extends StatelessWidget {
  final String? text;
  final Color color;
  final String actionLabel;
  final VoidCallback? onAction;

  const _CtrlChip({
    required this.text,
    required this.color,
    required this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (text != null) ...[
            Text(text!,
                style: const TextStyle(fontSize: 11, color: Colors.white)),
            const SizedBox(width: 6),
          ],
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              child: Text(actionLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个成员格：视频/头像 + 名字 + 麦克风/举手/发言状态。
class MemberTile extends StatelessWidget {
  final MeetingMember member;
  final bool compact;

  const MemberTile({
    super.key,
    required this.member,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final track = member.videoTrack;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: UuColors.darkCard,
          border: Border.all(
            color: member.speaking ? UuColors.success : Colors.transparent,
            width: 2,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (member.camOn && track != null)
              VideoTrackRenderer(track)
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: compact ? 16 : 28,
                      child: Text(
                        member.name.isEmpty ? '?' : member.name.characters.first,
                      ),
                    ),
                    if (!compact)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('摄像头已关闭',
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              ),
            Positioned(
              left: 4,
              bottom: 4,
              child: _NameChip(
                text: member.isSelf ? '${member.name}（我）' : member.name,
                speaking: member.speaking,
              ),
            ),
            Positioned(
              left: 4,
              top: 4,
              child: Icon(
                member.micOn ? Icons.mic : Icons.mic_off,
                size: compact ? 12 : 16,
                color: member.micOn ? Colors.white70 : const Color(0xFFFF5252),
              ),
            ),
            if (member.handRaised)
              Positioned(
                right: 4,
                top: 4,
                child: Text('✋', style: TextStyle(fontSize: compact ? 12 : 16)),
              ),
          ],
        ),
      ),
    );
  }
}

class _NameChip extends StatelessWidget {
  final String text;
  final bool speaking;
  const _NameChip({required this.text, required this.speaking});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: speaking ? const Color(0xFF81C784) : Colors.white),
      ),
    );
  }
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
