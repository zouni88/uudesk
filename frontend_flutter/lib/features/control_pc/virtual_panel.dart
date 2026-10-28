import 'package:flutter/material.dart';

import '../../core/protocol/control_messages.dart';

/// 虚拟鼠标/键盘面板：右键/中键/滚轮 + 文本提交 + 常用键（附录 A VK 码）。
class VirtualPanel extends StatefulWidget {
  final void Function(Map<String, dynamic> msg) onInput;
  final VoidCallback onClose;
  final (double, double) Function() position;

  const VirtualPanel({
    super.key,
    required this.onInput,
    required this.onClose,
    required this.position,
  });

  @override
  State<VirtualPanel> createState() => _VirtualPanelState();
}

class _VirtualPanelState extends State<VirtualPanel> {
  final _textCtrl = TextEditingController();
  bool _keyboardOpen = false;

  // Windows 虚拟键码（附录 A）
  static const _keys = <String, int>{
    'Esc': 0x1B,
    'Tab': 0x09,
    'Win': 0x5B,
    '←': 0x25,
    '↑': 0x26,
    '↓': 0x28,
    '→': 0x27,
    'Enter': 0x0D,
    '⌫': 0x08,
  };

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _click(int btn) {
    final (x, y) = widget.position();
    widget.onInput(UuMsg.inputDown(x, y, btn: btn));
    widget.onInput(UuMsg.inputUp(x, y, btn: btn));
  }

  void _scroll(double dy) {
    final (x, y) = widget.position();
    widget.onInput(UuMsg.inputScroll(x, y, 0, dy));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_outlined),
                isSelected: _keyboardOpen,
                onPressed: () => setState(() => _keyboardOpen = !_keyboardOpen),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: widget.onClose,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ChipButton(label: '左键', onTap: () => _click(1)),
              _ChipButton(label: '右键', onTap: () => _click(2)),
              _ChipButton(label: '中键', onTap: () => _click(3)),
              _ChipButton(label: '滚↑', onTap: () => _scroll(3)),
              _ChipButton(label: '滚↓', onTap: () => _scroll(-3)),
            ],
          ),
          if (_keyboardOpen) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    decoration: const InputDecoration(
                      hintText: '输入文字提交到 PC（§3.2 text）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: _submitText,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => _submitText(_textCtrl.text), child: const Text('发送')),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _keys.entries
                  .map((e) => ActionChip(
                        label: Text(e.key),
                        onPressed: () => widget.onInput(UuMsg.inputKey(e.value, 'press')),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  void _submitText(String s) {
    if (s.isEmpty) return;
    widget.onInput(UuMsg.inputText(s));
    _textCtrl.clear();
  }
}

class _ChipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ChipButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}
