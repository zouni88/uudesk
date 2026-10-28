import 'dart:async';

import 'package:flutter/material.dart';

import 'core/ui/theme.dart';
import 'features/be_controlled/be_controlled_page.dart';
import 'features/devices/devices_page.dart';
import 'features/files/files_page.dart';
import 'features/meeting/meeting_join_page.dart';
import 'features/meeting/meeting_room_page.dart';
import 'features/pairing/pairing_page.dart';
import 'features/settings/settings_page.dart';
import 'state/app_scope.dart';

/// 飞书风格浅色主题 + 底部导航外壳。
class UuDeskApp extends StatelessWidget {
  const UuDeskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UUDesk',
      debugShowCheckedModeBanner: false,
      theme: uuLightTheme(),
      home: const _Shell(),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> with WidgetsBindingObserver {
  int _index = 0;
  bool _restoringMeeting = false;

  // 「控制 PC」不再占用底部标签：设备/配对连接成功后 push 全屏 ControlPage。
  static const _pages = [
    MeetingJoinPage(),
    PairingPage(),
    DevicesPage(),
    BeControlledPage(),
    FilesPage(),
  ];

  static const _titles = ['会议', '配对', '设备', '被控', '文件'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 首帧后尝试恢复会议（进程被重建时内存状态已丢失）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreMeetingIfNeeded());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从屏幕共享授权页/系统设置返回时，Activity 可能已重建。
    if (state == AppLifecycleState.resumed) unawaited(_restoreMeetingIfNeeded());
  }

  /// 会话恢复：共享屏幕或切后台时 Android 可能重建 Activity 与 Flutter 引擎，
  /// 导致会议状态丢失（表现为“回到会议就重启”）。这里按持久化的会话
  /// 重新入会并自动回到会议页，同时还原入会前的麦克风/摄像头开关。
  Future<void> _restoreMeetingIfNeeded() async {
    if (!mounted || _restoringMeeting) return;
    final state = AppScope.read(context);
    final settings = state.settings;
    if (!settings.meetingActive || state.meeting.inMeeting) return;
    // 会议页已在栈顶（用户正在会中）时不重复入会。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final savedAt = settings.meetingSavedAt;
    final expired =
        savedAt <= 0 ||
        DateTime.now().difference(
              DateTime.fromMillisecondsSinceEpoch(savedAt),
            ) >
            const Duration(hours: 2);
    if (expired) {
      await settings.clearMeetingSession();
      return;
    }
    _restoringMeeting = true;
    var joined = false;
    try {
      await state.meeting.join(
        serverUrl: settings.meetingServer,
        room: settings.meetingRoom,
        identity: settings.deviceId,
        displayName: settings.meetingName.isEmpty
            ? settings.deviceId
            : settings.meetingName,
      );
      // join() 默认开麦；按离开前的状态还原。
      if (!settings.meetingMicOn) {
        try {
          await state.meeting.setMic(false);
        } catch (_) {}
      }
      if (settings.meetingCamOn) {
        try {
          await state.meeting.toggleCamera();
        } catch (_) {}
      }
      joined = true;
    } catch (e) {
      await settings.clearMeetingSession();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复会议失败：$e')),
        );
      }
    } finally {
      _restoringMeeting = false;
    }
    if (!joined || !mounted) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              Theme(data: uuDarkTheme(), child: const MeetingRoomPage()),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = AppScope.of(context).session;
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => session.isActive
                ? Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Center(
                      child: UuSessionPill(text: session.statusText),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 22),
            color: UuColors.textSecondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('设置')),
                      body: const SettingsPage(),
                    ))),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.videocam_outlined), selectedIcon: Icon(Icons.videocam), label: '会议'),
          NavigationDestination(icon: Icon(Icons.qr_code_2), label: '配对'),
          NavigationDestination(icon: Icon(Icons.devices_other_outlined), selectedIcon: Icon(Icons.devices_other), label: '设备'),
          NavigationDestination(icon: Icon(Icons.screen_share_outlined), selectedIcon: Icon(Icons.screen_share), label: '被控'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: '文件'),
        ],
      ),
    );
  }
}

/// 顶栏会话状态小胶囊。
class UuSessionPill extends StatelessWidget {
  final String text;

  const UuSessionPill({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: UuColors.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
                color: UuColors.success, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(text,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: UuColors.success)),
        ],
      ),
    );
  }
}
