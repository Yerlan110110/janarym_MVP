import 'dart:ui';

import 'package:flutter/material.dart';

import '../l10n/app_locale_controller.dart';
import '../runtime/mode_orchestrator.dart';

class ModeMenuEntry<T> {
  const ModeMenuEntry({
    required this.label,
    required this.icon,
    this.mode,
    this.actionId,
  });

  final String label;
  final IconData icon;
  final T? mode;
  final String? actionId;

  bool get isMode => mode != null;
}

class ModePickerSheet<T> extends StatelessWidget {
  const ModePickerSheet({
    super.key,
    required this.menuItems,
    required this.currentMode,
    required this.appLanguage,
    required this.modeDescriptorFor,
    required this.onModeSelected,
    required this.onActionSelected,
  });

  final List<ModeMenuEntry<T>> menuItems;
  final T currentMode;
  final AppLanguage appLanguage;
  final ModeDescriptor Function(T) modeDescriptorFor;
  final ValueChanged<T> onModeSelected;
  final ValueChanged<String> onActionSelected;

  @override
  Widget build(BuildContext context) {
    final modeItems = menuItems.where((e) => e.isMode).toList(growable: false);
    final actionItems = menuItems
        .where((e) => !e.isMode)
        .toList(growable: false);
    final isKk = appLanguage == AppLanguage.kk;

    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(30),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xCCF8FBFF).withValues(alpha: 0.18),
                const Color(0xCC0C1220).withValues(alpha: 0.68),
              ],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 32,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.30),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 15,
                        color: Colors.white.withValues(alpha: 0.86),
                      ),
                      Text(
                        isKk ? 'Жылдам ауысу' : 'Быстрое переключение',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.78),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  isKk ? 'Режимдер' : 'Режимы',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isKk
                      ? 'Көрініс ашық қалады, режимді бір қимылмен таңдаңыз'
                      : 'Экран остаётся видимым, выберите режим одним жестом',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 13,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final useWideCards = constraints.maxWidth >= 340;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                        childAspectRatio: useWideCards ? 1.36 : 1.18,
                      ),
                      itemCount: modeItems.length,
                      itemBuilder: (_, index) {
                        final entry = modeItems[index];
                        final mode = entry.mode as T;
                        final descriptor = modeDescriptorFor(mode);
                        final accent = descriptor.ui.accentColor;
                        final isActive = currentMode == mode;
                        return _ModeCard(
                          label: entry.label,
                          icon: descriptor.ui.icon,
                          accent: accent,
                          isActive: isActive,
                          onTap: () => onModeSelected(mode),
                        );
                      },
                    );
                  },
                ),
                if (actionItems.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: actionItems
                        .map((entry) {
                          return _ActionChip(
                            label: entry.label,
                            icon: entry.icon,
                            onTap: () => onActionSelected(entry.actionId!),
                          );
                        })
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.icon,
    required this.accent,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isActive
                  ? [
                      accent.withValues(alpha: 0.30),
                      accent.withValues(alpha: 0.12),
                    ]
                  : [
                      Colors.white.withValues(alpha: 0.10),
                      Colors.white.withValues(alpha: 0.05),
                    ],
            ),
            border: Border.all(
              color: isActive
                  ? accent.withValues(alpha: 0.68)
                  : Colors.white.withValues(alpha: 0.12),
              width: isActive ? 1.4 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: (isActive ? accent : Colors.black).withValues(
                  alpha: isActive ? 0.22 : 0.10,
                ),
                blurRadius: isActive ? 20 : 14,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? accent.withValues(alpha: 0.22)
                        : Colors.white.withValues(alpha: 0.10),
                    border: Border.all(
                      color: isActive
                          ? accent.withValues(alpha: 0.34)
                          : Colors.white.withValues(alpha: 0.10),
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: isActive
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.78),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(
                      alpha: isActive ? 0.96 : 0.88,
                    ),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Colors.white.withValues(alpha: 0.08),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 17,
                  color: Colors.white.withValues(alpha: 0.86),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.88),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
