import 'package:flutter/material.dart';

import 'theme.dart';

/// 白色圆角卡片（页面灰底上的分组容器，飞书风格）。
class UuCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;
  final double radius;
  final BorderRadius? borderRadius;

  const UuCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(UuSpacing.lg),
    this.onTap,
    this.color = UuColors.card,
    this.radius = UuRadius.lg,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(color: color, borderRadius: br),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// 分组列表：多个 tile 之间自动插入左缩进分隔线。
class UuGroup extends StatelessWidget {
  final List<Widget> children;
  final double indent;

  const UuGroup({super.key, required this.children, this.indent = 16});

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        items.add(Divider(height: 0.8, indent: indent, thickness: 0.8));
      }
      items.add(children[i]);
    }
    return UuCard(padding: EdgeInsets.zero, child: Column(children: items));
  }
}

/// 区块小标题（灰色 13px，飞书分组标题）。
class UuSectionLabel extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const UuSectionLabel(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: UuColors.textSecondary,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 状态胶囊（如「已连接」「传输中」）。
class UuStatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool dot;

  const UuStatusChip(this.label, {super.key, required this.color, this.dot = true});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(UuRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w500, color: color)),
        ],
      ),
    );
  }
}

/// 空态：圆形浅底图标 + 文案 + 可选操作。
class UuEmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? hint;
  final Widget? action;
  final Color iconColor;

  const UuEmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.hint,
    this.action,
    this.iconColor = UuColors.textTertiary,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UuSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(color: UuColors.fill, shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: iconColor),
            ),
            const SizedBox(height: UuSpacing.lg),
            Text(text,
                style: const TextStyle(
                    fontSize: 14, color: UuColors.textSecondary)),
            if (hint != null) ...[
              const SizedBox(height: UuSpacing.xs),
              Text(hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, color: UuColors.textTertiary)),
            ],
            if (action != null) ...[
              const SizedBox(height: UuSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 配对码分格显示：6 个独立数字格（验证码风格）。
class UuCodeBoxes extends StatelessWidget {
  final String code;
  final int length;

  const UuCodeBoxes({super.key, required this.code, this.length = 6});

  @override
  Widget build(BuildContext context) {
    final chars = code.padRight(length, ' ').split('').take(length).toList();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < chars.length; i++) ...[
          if (i > 0) SizedBox(width: i == 2 ? UuSpacing.lg : UuSpacing.sm),
          Container(
            width: 40,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: chars[i] == ' ' ? UuColors.fill : const Color(0xFFE1E8FF),
              borderRadius: BorderRadius.circular(UuRadius.md),
              border: Border.all(
                color: chars[i] == ' ' ? UuColors.lineLight : UuColors.primary,
              ),
            ),
            child: Text(
              chars[i] == ' ' ? '' : chars[i],
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: chars[i] == ' ' ? UuColors.textTertiary : UuColors.primaryDark,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 彩色圆形图标底（列表 leading，飞书设备/功能图标风格）。
class UuIconBubble extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const UuIconBubble(this.icon, {super.key, required this.color, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(UuRadius.md),
      ),
      child: Icon(icon, size: size * 0.5, color: color),
    );
  }
}
