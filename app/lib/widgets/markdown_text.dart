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
    final base = style ?? Theme.of(context).textTheme.bodyMedium;
    // Most rows carry no markdown at all: a typed prompt, a tool's one-line
    // result, a status note. Parsing those anyway is what a lazy list pays
    // again every time a row scrolls back into view, so plain text takes the
    // plain path.
    if (!_looksLikeMarkdown(text)) {
      return Text(text, style: base?.copyWith(height: 1.35));
    }
    return MarkdownBody(
      data: text,
      // Not selectable. A selectable markdown body installs a selection
      // region per row, and a replayed session is thousands of rows: that
      // alone made scrolling a long transcript cost hundreds of milliseconds
      // per drag. The transcript is selectable as a whole instead, from the
      // region the transcript view wraps it in.
      selectable: false,
      styleSheet: _styleSheetFor(context, style),
    );
  }
}

/// Whether [text] contains anything markdown would render differently from
/// plain text. Deliberately generous: a false positive costs one parse, a
/// false negative would show raw syntax.
bool _looksLikeMarkdown(String text) {
  for (var i = 0; i < text.length; i++) {
    switch (text.codeUnitAt(i)) {
      case 0x23: // #
      case 0x2a: // *
      case 0x5f: // _
      case 0x60: // `
      case 0x5b: // [
      case 0x5d: // ]
      case 0x3e: // >
      case 0x7c: // |
      case 0x7e: // ~
        return true;
      case 0x2d: // -
      case 0x2b: // +
        // A leading marker is a list; a hyphen inside a word is not.
        if (i == 0 || text.codeUnitAt(i - 1) == 0x0a) return true;
    }
  }
  return false;
}

/// One stylesheet per (theme, base style).
///
/// Building it is not free and it does not depend on the text, so rebuilding
/// it for every row of every frame was pure waste. Keyed by the theme object
/// and the base style, both of which are stable while a theme is in use.
final Map<(ThemeData, TextStyle?), MarkdownStyleSheet> _styleSheets = {};

MarkdownStyleSheet _styleSheetFor(BuildContext context, TextStyle? style) {
  final theme = Theme.of(context);
  final cached = _styleSheets[(theme, style)];
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
  _styleSheets[(theme, style)] = sheet;
  return sheet;
}
