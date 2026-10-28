import 'package:flutter/material.dart';

import '../../core/meeting/meeting_models.dart';
import '../../core/meeting/meeting_service.dart';
import '../../core/ui/theme.dart';

/// 会中聊天面板：消息列表 + 输入框（§10.2 lk.chat）。
class MeetingChatPanel extends StatefulWidget {
  final MeetingService service;

  const MeetingChatPanel({super.key, required this.service});

  @override
  State<MeetingChatPanel> createState() => _MeetingChatPanelState();
}

class _MeetingChatPanelState extends State<MeetingChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onChanged);
    widget.service.markChatRead();
  }

  @override
  void dispose() {
    widget.service.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    widget.service.markChatRead();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    setState(() {});
    await widget.service.sendChat(text);
  }

  String _fmt(DateTime ts) =>
      '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 18),
                  const SizedBox(width: 8),
                  Text('聊天', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.service,
                builder: (context, _) {
                  final chats = widget.service.chats;
                  if (chats.isEmpty) {
                    return Center(
                      child: Text('暂无消息',
                          style: theme.textTheme.bodySmall),
                    );
                  }
                  return ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: chats.length,
                    itemBuilder: (context, i) =>
                        _ChatBubble(msg: chats[i], fmt: _fmt),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          hintText: '发送消息…',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.send),
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage msg;
  final String Function(DateTime) fmt;

  const _ChatBubble({required this.msg, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final align = msg.isSelf ? TextAlign.end : TextAlign.start;
    return Align(
      alignment: msg.isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: msg.isSelf
              ? theme.colorScheme.primaryContainer
              : UuColors.darkCard,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment:
              msg.isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              '${msg.name} · ${fmt(msg.ts)}',
              textAlign: align,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: UuColors.darkTextSecondary, fontSize: 10),
            ),
            const SizedBox(height: 2),
            Text(msg.text, textAlign: align),
          ],
        ),
      ),
    );
  }
}

/// 成员面板：举手置顶 + 发言高亮 + 麦/摄像头状态（§10.2）。
class MeetingMembersPanel extends StatelessWidget {
  final MeetingService service;

  const MeetingMembersPanel({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.groups_outlined, size: 18),
                  const SizedBox(width: 8),
                  Text('成员', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) {
                  final list = service.members.toList()
                    ..sort((a, b) => (b.handRaised ? 1 : 0)
                        .compareTo(a.handRaised ? 1 : 0));
                  if (list.isEmpty) {
                    return Center(
                        child:
                            Text('暂无成员', style: theme.textTheme.bodySmall));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final m = list[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: m.speaking
                              ? UuColors.success
                              : theme.colorScheme.surfaceContainerHighest,
                          child: Text(
                            m.name.isEmpty ? '?' : m.name.characters.first,
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(
                          m.isSelf ? '${m.name}（我）' : m.name,
                          style: m.speaking
                              ? theme.textTheme.bodyMedium
                                  ?.copyWith(color: const Color(0xFF81C784))
                              : null,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (m.handRaised)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Text('✋'),
                              ),
                            Icon(
                              m.micOn ? Icons.mic : Icons.mic_off,
                              size: 18,
                              color: m.micOn
                                  ? UuColors.darkText
                                  : UuColors.danger,
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              m.camOn ? Icons.videocam : Icons.videocam_off,
                              size: 18,
                              color: m.camOn
                                  ? UuColors.darkText
                                  : UuColors.darkTextSecondary,
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
