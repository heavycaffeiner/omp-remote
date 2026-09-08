import 'package:flutter/material.dart';

import '../settings_store.dart';
import '../theme.dart';

/// Appearance and behaviour preferences. Everything here is local to the
/// device: nothing in it reaches the workstation.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.settings,
    required this.dynamicColorAvailable,
    super.key,
  });

  final SettingsStore settings;

  /// Whether the platform actually supplied a wallpaper palette. Offering
  /// Material You on a device that has none would silently do nothing.
  final bool dynamicColorAvailable;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Semantics(header: true, child: const Text('Settings')),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.only(bottom: AppSpacing.xl),
            children: [
              const _SectionHeader('Appearance'),
              RadioGroup<AppThemeChoice>(
                groupValue: settings.themeChoice,
                onChanged: (choice) {
                  if (choice != null) settings.setThemeChoice(choice);
                },
                child: Column(
                  children: [
                    for (final choice in AppThemeChoice.values)
                      _ThemeOption(
                        choice: choice,
                        // The option stays visible but says why it cannot be
                        // picked, rather than vanishing on an older device.
                        unavailable:
                            choice.usesDynamicColor && !dynamicColorAvailable,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({required this.choice, required this.unavailable});

  final AppThemeChoice choice;

  /// True when the platform cannot honour this choice. The row stays but
  /// says so, since a missing option looks like a missing feature.
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = unavailable
        ? 'This device supplies no wallpaper palette'
        : choice.description;
    return RadioListTile<AppThemeChoice>(
      value: choice,
      enabled: !unavailable,
      title: Row(
        children: [
          Icon(
            choice.icon,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(choice.label)),
        ],
      ),
      subtitle: Text(
        description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: unavailable
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      controlAffinity: ListTileControlAffinity.trailing,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
    );
  }
}
