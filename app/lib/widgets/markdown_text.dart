import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';

/// Every piece of model or user text the app shows, rendered as markdown.
/// Agent output is markdown by convention, so plain text turns headings into
/// stray hashes and code fences into stray backticks.
class MarkdownText extends StatelessWidget {
  const MarkdownText({required this.text, this.style, super.key});

  final String text;

  /// Base style for body text. Defaults to `bodyMedium`.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: text,
      // Not selectable per row. A selection region per row cost 1.7x on
      // first render of a replayed session (25ms to 42ms for 3200 entries).
      // The transcript is wrapped in one region instead, so copying still
      // works.
      selectable: false,
      styleSheet: _styleSheetFor(context, style),
    );
  }
}

/// One stylesheet per (brightness, base style).
///
/// Building it does not depend on the text, and rebuilding it per row per
/// frame cost 42ms against 25ms on first render and 34ms against 24ms on ten
/// drags. The key is deliberately cheap: hashing a whole `ThemeData` walks
/// every field it holds, which would spend on the lookup what the cache
/// saves on the build.
final Map<(Brightness, TextStyle?), MarkdownStyleSheet> _styleSheets = {};

MarkdownStyleSheet _styleSheetFor(BuildContext context, TextStyle? style) {
  final theme = Theme.of(context);
  final key = (theme.brightness, style);
  final cached = _styleSheets[key];
  if (cached != null) return cached;

  final scheme = theme.colorScheme;
  final body = style ?? theme.textTheme.bodyMedium;
  final mono = theme.textTheme.bodySmall?.copyWith(
    fontFamily: 'monospace',
    color: scheme.onSurface,
  );
  final sheet = MarkdownStyleSheet(
    p: body?.copyWith(height: 1.35),
    h1: theme.textTheme.titleLarge,
    h2: theme.textTheme.titleMedium,
    h3: theme.textTheme.titleSmall,
    h4: theme.textTheme.titleSmall,
    h5: theme.textTheme.labelLarge,
    h6: theme.textTheme.labelLarge,
    strong: body?.copyWith(fontWeight: FontWeight.w700),
    em: body?.copyWith(fontStyle: FontStyle.italic),
    a: body?.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
    ),
    code: mono?.copyWith(backgroundColor: scheme.surfaceContainerHighest),
    codeblockDecoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.small)),
    ),
    codeblockPadding: const EdgeInsets.all(AppSpacing.sm),
    blockquoteDecoration: BoxDecoration(
      color: scheme.surfaceContainerHigh,
      border: Border(left: BorderSide(color: scheme.outline, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.all(AppSpacing.sm),
    blockSpacing: AppSpacing.xs,
    listBullet: body,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outlineVariant)),
    ),
    tableHead: theme.textTheme.labelMedium,
    tableBody: theme.textTheme.bodySmall,
    tableBorder: TableBorder.all(color: scheme.outlineVariant),
    tableCellsPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.sm,
      vertical: AppSpacing.xs,
    ),
  );
  // Two themes (light and dark) and a handful of base styles, so this never
  // grows: it is a memo, not a leak.
  _styleSheets[key] = sheet;
  return sheet;
}
