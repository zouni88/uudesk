import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/protocol/control_messages.dart';
import '../../core/transport/uu_transport.dart';
import '../../core/ui/widgets.dart';
import '../../state/app_scope.dart';
import 'virtual_panel.dart';

/// 手机控 PC 页：远程画面（Texture）+ 触控手势转 §3.2 input 消息。
class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> {
  double _lastX = 0.5;
  double _lastY = 0.5;
  bool _panelVisible = true;
  int _framesShown = 0;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final session = state.session;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.isActive) {
          return _NoSession(onDemo: () => session.startMockController('mock://pc'));
        }
        final aspect = session.screenWidth == 0 || session.screenHeight == 0
            ? 16 / 9
            : session.screenWidth / session.screenHeight;
        return Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _Screen(
                      state: state,
                      onFrame: () => setState(() => _framesShown++),
                      child: _gestureArea(state),
                    ),
                  ),
                ),
              ),
            ),
            if (_panelVisible)
              VirtualPanel(
                onInput: (msg) => session.sendInput(msg),
                onClose: () => setState(() => _panelVisible = false),
                position: () => (_lastX, _lastY),
              )
            else
              TextButton.icon(
                onPressed: () => setState(() => _panelVisible = true),
                icon: const Icon(Icons.gamepad_outlined),
                label: const Text('显示虚拟面板'),
              ),
          ],
        );
      },
    );
  }

  /// 手势 → 归一化坐标 input 消息（§3.2）。
  Widget _gestureArea(AppState state) {
    return LayoutBuilder(builder: (context, box) {
      void norm(Offset pos) {
        _lastX = (pos.dx / box.maxWidth).clamp(0.0, 1.0);
        _lastY = (pos.dy / box.maxHeight).clamp(0.0, 1.0);
      }

      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          norm(e.localPosition);
          state.session.sendInput(UuMsg.inputDown(_lastX, _lastY));
          state.session.sendInput(UuMsg.inputMove(_lastX, _lastY));
        },
        onPointerMove: (e) {
          norm(e.localPosition);
          state.session.sendInput(UuMsg.inputMove(_lastX, _lastY));
        },
        onPointerUp: (e) {
          norm(e.localPosition);
          state.session.sendInput(UuMsg.inputUp(_lastX, _lastY));
        },
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            norm(e.localPosition);
            state.session.sendInput(UuMsg.inputScroll(
              _lastX, _lastY, 0, -e.scrollDelta.dy / 100.0,
            ));
          }
        },
        child: _screenContent(state),
      );
    });
  }

  Widget _screenContent(AppState state) {
    final textureId = state.decoder.textureId;
    if (textureId != null) {
      return Texture(textureId: textureId);
    }
    // 无原生解码器（mock/桌面）：占位画面。
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.desktop_mac_outlined, size: 48, color: Colors.white38),
          const SizedBox(height: 8),
          Text(
            '远程画面占位（${state.session.screenWidth}x${state.session.screenHeight}）\n'
            '帧计数: $_framesShown · ${state.session.usingMock ? 'mock 通道' : 'FFI 通道'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 画面容器：订阅视频帧流以驱动占位计数/解码。
class _Screen extends StatefulWidget {
  final AppState state;
  final VoidCallback onFrame;
  final Widget child;

  const _Screen({required this.state, required this.onFrame, required this.child});

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  StreamSubscription<UuDataFrame>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.state.session.transport?.videoFrames.listen((_) => widget.onFrame());
  }

  @override
  void didUpdateWidget(covariant _Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sub?.cancel();
    _sub = widget.state.session.transport?.videoFrames.listen((_) => widget.onFrame());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NoSession extends StatelessWidget {
  final VoidCallback onDemo;
  const _NoSession({required this.onDemo});

  @override
  Widget build(BuildContext context) {
    return UuEmptyState(
      icon: Icons.desktop_windows_outlined,
      text: '尚未建立控制会话',
      hint: '先在「设备」或「配对」页连接一台 PC，\n即可远程控制对方桌面',
      action: FilledButton.icon(
        onPressed: onDemo,
        icon: const Icon(Icons.play_arrow),
        label: const Text('连接演示 PC（mock）'),
      ),
    );
  }
}
