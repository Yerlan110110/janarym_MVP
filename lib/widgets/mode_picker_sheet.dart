import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:janarym_app2/l10n/app_localizations.dart';
import 'package:janarym_app2/main.dart';
import 'package:janarym_app2/runtime/mode_orchestrator.dart';

// ── PREMIUM MODE PICKER BOTTOM SHEET ─────────────────────────────────────────

class ModePickerSheet extends StatelessWidget {
  const ModePickerSheet({
    super.key,
    required this.menuItems,
    required this.currentMode,
    required this.appLanguage,
    required this.modeDescriptorFor,
    required this.onModeSelected,
    required this.onActionSelected,
  });

  final List<ModeMenuEntry> menuItems;
  final AssistantMode currentMode;
  final AppLanguage appLanguage;
  final ModeDescriptor Function(AssistantMode) modeDescriptorFor;
  final void Function(AssistantMode) onModeSelected;
  final void Function(String) onActionSelected;

  @override
  Widget build(BuildContext context) {
    final modeItems = menuItems.where((e) => e.isMode).toList();
    final actionItems = menuItems.where((e) => !e.isMode).toList();
    final isKk = appLanguage == AppLanguage.kk;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0A0F1E).withValues(alpha: 0.88),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Title
                  Text(
                    isKk ? 'Режимдер' : 'Режимы',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  Text(
                    isKk
                        ? 'Жұмыс режимін таңдаңыз'
                        : 'Выберите режим работы',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.52),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),
                  // Mode grid
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.9,
                    ),
                    itemCount: modeItems.length,
                    itemBuilder: (_, i) {
                      final entry = modeItems[i];
                      final mode = entry.mode!;
                      final desc = modeDescriptorFor(mode);
                      final accentColor = desc.ui.accentColor;
                      final isActive = currentMode == mode;
                      return GestureDetector(
                        onTap: () => onModeSelected(mode),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isActive
                                ? accentColor.withValues(alpha: 0.18)
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: isActive
                                  ? accentColor.withValues(alpha: 0.70)
                                  : Colors.white.withValues(alpha: 0.10),
                              width: isActive ? 1.5 : 1.0,
                            ),
                            boxShadow: isActive
                                ? [
                                    BoxShadow(
                                      color:
                                          accentColor.withValues(alpha: 0.18),
                                      blurRadius: 14,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Row(
                            children: [
                              // Mode icon
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(
                                    alpha: isActive ? 0.30 : 0.14,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  desc.ui.icon,
                                  size: 18,
                                  color: isActive
                                      ? accentColor
                                      : Colors.white.withValues(alpha: 0.65),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Mode label
                              Expanded(
                                child: Text(
                                  entry.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isActive
                                        ? Colors.white
                                        : Colors.white.withValues(alpha: 0.75),
                                    fontSize: 13,
                                    fontWeight: isActive
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  // Action items (e.g. "go home", "voice enrollment")
                  if (actionItems.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Divider(
                      color: Colors.white.withValues(alpha: 0.10),
                      height: 1,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: actionItems.map((entry) {
                        return GestureDetector(
                          onTap: () => onActionSelected(entry.actionId!),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.07),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.15),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  entry.icon,
                                  size: 16,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  entry.label,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
