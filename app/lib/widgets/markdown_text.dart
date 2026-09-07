import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';

/// Every piece of model or user text the app shows, rendered as markdown.
/// Agent output is markdown by convention, so plain text turns headings into
/// stray hashes and code fences into stray backticks. Selectable, because a
/// phone user's only way to copy an identifier is to select it.
class MarkdownText extends StatelessWidget {
  const MarkdownText({required this.text, this.style, super.key});

  final String text;

  /// Base style for body text. Defaults to `bodyMedium`.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = style ?? theme.textTheme.bodyMedium;
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: scheme.onSurface,
    );

    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: body,
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
          borderRadius: const BorderRadius.all(
            Radius.circular(AppRadius.small),
          ),
        ),
        codeblockPadding: const EdgeInsets.all(AppSpacing.sm),
        blockquoteDecoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          border: Border(left: BorderSide(color: scheme.outline, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.all(AppSpacing.sm),
        blockSpacing: AppSpacing.sm,
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
      ),
    );
  }
}
