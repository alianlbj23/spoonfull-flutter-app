import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'app_assets.dart';
import 'icons.dart';

enum ShellTab { capture, records, settings }

/// 側選單 (Spoonfull logo / 拍攝首頁 / 膳食攝影紀錄 / 設定 / 登出)。
class AppDrawerOverlay extends StatelessWidget {
  const AppDrawerOverlay({
    super.key,
    required this.animation,
    required this.current,
    required this.onSelect,
    required this.onLogout,
    required this.onDismiss,
  });

  final Animation<double> animation;
  final ShellTab current;
  final ValueChanged<ShellTab> onSelect;
  final VoidCallback onLogout;
  final VoidCallback onDismiss;

  static const double width = 462;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeOut.transform(animation.value);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('drawer-scrim'),
                onTap: onDismiss,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 6 * t, sigmaY: 6 * t),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.45 * t),
                  ),
                ),
              ),
            ),
            Positioned(
              left: -width * (1 - t),
              top: 0,
              bottom: 0,
              width: width,
              child: child!,
            ),
          ],
        );
      },
      child: _DrawerPanel(
        current: current,
        onSelect: onSelect,
        onLogout: onLogout,
      ),
    );
  }
}

class _DrawerPanel extends StatelessWidget {
  const _DrawerPanel({
    required this.current,
    required this.onSelect,
    required this.onLogout,
  });

  final ShellTab current;
  final ValueChanged<ShellTab> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.railGradient),
      padding: const EdgeInsets.fromLTRB(52, 56, 80, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: Image.asset(AppAssets.logo, width: 252)),
          const SizedBox(height: 6),
          Container(height: 1.2, color: Colors.white.withValues(alpha: 0.8)),
          const SizedBox(height: 56),
          _DrawerItem(
            key: const Key('menu-capture'),
            label: '拍攝首頁',
            selected: current == ShellTab.capture,
            icon: (c) => DomeIcon(size: 38, color: c),
            onTap: () => onSelect(ShellTab.capture),
          ),
          _DrawerItem(
            key: const Key('menu-records'),
            label: '膳食攝影紀錄',
            selected: current == ShellTab.records,
            icon: (c) => OnigiriIcon(size: 38, color: c),
            onTap: () => onSelect(ShellTab.records),
          ),
          _DrawerItem(
            key: const Key('menu-settings'),
            label: '設定',
            selected: current == ShellTab.settings,
            icon: (c) => c == Colors.white
                ? ColorFiltered(
                    colorFilter: const ColorFilter.matrix([
                      -1.095, 0, 0, 0, 293.3,
                      0, -0.734, 0, 0, 284.4,
                      0, 0, -0.074, 0, 267.4,
                      0, 0, 0, 1, 0,
                    ]),
                    child: Image.asset(AppAssets.gearDark, width: 34),
                  )
                : Image.asset(AppAssets.gearDark, width: 34),
            onTap: () => onSelect(ShellTab.settings),
          ),
          const Spacer(),
          _DrawerItem(
            key: const Key('menu-logout'),
            label: '登出',
            selected: false,
            icon: (c) => Transform.flip(
              flipX: true,
              child: Icon(Icons.logout_rounded, color: c, size: 40),
            ),
            onTap: onLogout,
          ),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    super.key,
    required this.label,
    required this.selected,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Widget Function(Color color) icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? AppColors.navy : Colors.white;
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                const SizedBox(width: 10),
                SizedBox(width: 44, child: Center(child: icon(fg))),
                const SizedBox(width: 18),
                Text(label, style: AppText.size(36, color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
