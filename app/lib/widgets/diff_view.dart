import 'package:flutter/material.dart';

import '../theme.dart';

/// One line of a unified diff, classified by its leading marker.
enum DiffLineKind { added, removed, context, hunk, meta }

class DiffLine {
  const DiffLine({required this.kind, required this.text, this.lineNumber});

  final DiffLineKind kind;

  /// The line without its marker, so the marker can be drawn separately and
  /// left out of a copy.
  final String text;

  /// Line number, when the producer prefixed one. The edit tool emits
  /// `-2|beta` rather than a bare `-beta`, and a number belongs in its own
  /// column instead of running into the code.
  final int? lineNumber;
}

final RegExp _numberedLine = RegExp(r'^(\d+)\|');

DiffLine _classify(DiffLineKind kind, String body) {
  final match = _numberedLine.firstMatch(body);
  if (match == null) return DiffLine(kind: kind, text: body);
  return DiffLine(
    kind: kind,
    text: body.substring(match.end),
    lineNumber: int.parse(match.group(1)!),
  );
}

/// Splits a unified diff into classified lines. `---`/`+++` headers are
/// classified as meta rather than removals: they name files, not content.
List<DiffLine> parseUnifiedDiff(String diff) {
  final lines = <DiffLine>[];
  for (final raw in diff.split('\n')) {
    if (raw.startsWith('@@')) {
      lines.add(DiffLine(kind: DiffLineKind.hunk, text: raw));
    } else if (raw.startsWith('+++') || raw.startsWith('---')) {
      lines.add(DiffLine(kind: DiffLineKind.meta, text: raw));
    } else if (raw.startsWith('diff ') || raw.startsWith('index ')) {
      lines.add(DiffLine(kind: DiffLineKind.meta, text: raw));
    } else if (raw.startsWith('+')) {
      lines.add(_classify(DiffLineKind.added, raw.substring(1)));
    } else if (raw.startsWith('-')) {
      lines.add(_classify(DiffLineKind.removed, raw.substring(1)));
    } else {
      lines.add(
        _classify(
          DiffLineKind.context,
          raw.startsWith(' ') ? raw.substring(1) : raw,
        ),
      );
    }
  }
  // A trailing newline yields one empty context line; drop it.
  if (lines.isNotEmpty &&
      lines.last.kind == DiffLineKind.context &&
      lines.last.text.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

/// A unified diff, rendered with a tinted background and a `+`/`-` gutter per
/// line. The marker is drawn as its own column so a change reads without
/// relying on colour, and long lines wrap under the gutter rather than
/// running off the right edge.
class DiffView extends StatelessWidget {
  const DiffView({required this.diff, this.maxHeight = 320, super.key});

  final String diff;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final lines = parseUnifiedDiff(diff);
    if (lines.isEmpty) return const SizedBox.shrink();

    final added = lines.where((l) => l.kind == DiffLineKind.added).length;
    final removed = lines.where((l) => l.kind == DiffLineKind.removed).length;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: '$added lines added, $removed removed',
          child: Row(
            children: [
              Text(
                '+$added',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '-$removed',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.error,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.all(
                Radius.circular(AppRadius.small),
              ),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final line in lines) _DiffRow(line: line)],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DiffRow extends StatelessWidget {
  const _DiffRow({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      String marker,
      Color? background,
      Color foreground,
    ) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      DiffLineKind.removed => (
        '-',
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
      DiffLineKind.hunk => ('', scheme.surfaceContainerHigh, scheme.primary),
      DiffLineKind.meta => ('', null, scheme.onSurfaceVariant),
      DiffLineKind.context => (' ', null, scheme.onSurfaceVariant),
    };

    final style = theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      color: foreground,
      height: 1.25,
    );

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.lineNumber != null)
            SizedBox(
              width: 34,
              child: Text(
                '${line.lineNumber}',
                textAlign: TextAlign.right,
                style: style?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          SizedBox(width: 14, child: Text(marker, style: style)),
          // Wrapped, not scrolled sideways: a phone is narrower than almost
          // every code line, and a horizontal scroller hid the end of the
          // line behind a gesture nothing advertised. Continuation lands
          // under the text column, past the number and marker gutters.
          Expanded(child: Text(line.text, style: style)),
        ],
      ),
    );
  }
}
