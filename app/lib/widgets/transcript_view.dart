import 'package:flutter/material.dart';

import '../session_store.dart';
import '../theme.dart';

/// Renders the transcript. Only rebuilds the whole list when entries are
/// added or removed (driven by [SessionStore.transcriptRevision]); each row
/// listens to its own [TranscriptEntry.revision] so a streaming delta
/// repaints just that row. Scroll position is pinned to the bottom only
/// when the user was already there before new content arrived.
class TranscriptView extends StatefulWidget {
  const TranscriptView({required this.sessionStore, super.key});

  final SessionStore sessionStore;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final ScrollController _scrollController = ScrollController();
  static const double _bottomThreshold = 64;

  bool get _isAtBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - _bottomThreshold;
  }

  @override
  void initState() {
    super.initState();
    widget.sessionStore.transcriptRevision.addListener(_onTranscriptChanged);
  }

  @override
  void dispose() {
    widget.sessionStore.transcriptRevision.removeListener(_onTranscriptChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onTranscriptChanged() {
    final wasAtBottom = _isAtBottom;
    if (!wasAtBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: widget.sessionStore.transcriptRevision,
      builder: (context, revision, _) {
        final entries = widget.sessionStore.entries;
        if (entries.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 40,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'No messages yet',
                    style: theme.textTheme.titleSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Type a message in the composer below and send it to '
                    'start the conversation.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          itemCount: entries.length,
          itemBuilder: (context, index) => _TranscriptRow(
            key: ValueKey(entries[index].id),
            entry: entries[index],
          ),
        );
      },
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.entry, super.key});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entry.revision,
      builder: (context, _) {
        switch (entry.kind) {
          case TranscriptKind.message:
            return _MessageRow(entry: entry);
          case TranscriptKind.tool:
            return _ToolCard(entry: entry);
          case TranscriptKind.notice:
            return _NoticeLine(entry: entry);
          case TranscriptKind.status:
          case TranscriptKind.system:
            return _SystemLine(entry: entry);
        }
      },
    );
  }
}

/// A block of text rendered monospace with horizontal scroll instead of
/// wrapping (for code, tool arguments, and tool output), and selectable.
/// Wrapping it in an unconstrained horizontal scroller keeps long single
/// lines intact instead of forcing them to break mid-token.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text, this.maxHeight});

  final String text;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(text, style: monospaceStyle(context)),
      ),
    );
    if (maxHeight == null) return box;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight!),
      child: SingleChildScrollView(child: box),
    );
  }
}

/// Renders a tool call's `input` payload as a short single-line summary for
/// the collapsed header row.
String _summarizeToolInput(Object? input) {
  if (input == null) return '';
  if (input is String) return input;
  if (input is Map) {
    return input.entries.map((e) => '${e.key}: ${e.value}').join(', ');
  }
  if (input is List) return input.join(', ');
  return input.toString();
}

/// Pretty-prints a tool's `input` payload for the expanded detail view.
String _formatToolInput(Object? input) {
  if (input == null) return '';
  if (input is String) return input;
  if (input is Map) {
    return input.entries.map((e) => '${e.key}: ${e.value}').join('\n');
  }
  if (input is List) return input.map((e) => '- $e').join('\n');
  return input.toString();
}

/// One piece of a message body: either prose someone wrote or a block the
/// harness wrapped in a tag. Tagged blocks arrive inline in the same text,
/// so without splitting them out they read as if the user had typed them.
class _Segment {
  const _Segment({required this.text, this.tag});

  final String text;

  /// The wrapper's tag name, or null for ordinary prose.
  final String? tag;
}

/// Any paired tag whose name is hyphen- or underscore-separated, plus a few
/// single-word ones the harness uses. The separator requirement is what
/// keeps ordinary markup in prose (`<div>`, `<b>`) from being treated as a
/// system block.
final RegExp _taggedBlock = RegExp(
  r'<([a-z][a-z0-9]*(?:[-_][a-z0-9]+)+|advisory|critical|instruction|important|reminder|thinking)\b[^>]*>([\s\S]*?)</\1\s*>',
  multiLine: true,
);

List<_Segment> _splitTagged(String text) {
  final segments = <_Segment>[];
  var cursor = 0;
  for (final match in _taggedBlock.allMatches(text)) {
    final before = text.substring(cursor, match.start).trim();
    if (before.isNotEmpty) segments.add(_Segment(text: before));
    final body = (match.group(2) ?? '').trim();
    if (body.isNotEmpty) {
      segments.add(_Segment(text: body, tag: match.group(1)));
    }
    cursor = match.end;
  }
  final rest = text.substring(cursor).trim();
  if (rest.isNotEmpty || segments.isEmpty) {
    segments.add(_Segment(text: segments.isEmpty ? text : rest));
  }
  return segments;
}

/// A tagged block, set apart from the prose around it. Known tags get their
/// own icon and accent; anything else falls back to the tag name with a
/// neutral tag icon, so a tag nobody anticipated still reads as a block
/// rather than as stray markup.
class _TaggedBlock extends StatelessWidget {
  const _TaggedBlock({required this.tag, required this.text});

  final String tag;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (String label, IconData icon, Color color) = switch (tag) {
      'advisory' => ('advisor', Icons.rate_review_outlined, scheme.tertiary),
      'system-reminder' || 'reminder' => (
        'reminder',
        Icons.push_pin_outlined,
        scheme.onSurfaceVariant,
      ),
      'system-notice' => ('notice', Icons.campaign_outlined, scheme.secondary),
      'system-directive' || 'system-interrupt' => (
        tag == 'system-interrupt' ? 'interrupt' : 'directive',
        Icons.gavel_outlined,
        scheme.error,
      ),
      'critical' || 'important' => (tag, Icons.priority_high, scheme.error),
      'instruction' || 'instructions' => (
        'instruction',
        Icons.menu_book_outlined,
        scheme.primary,
      ),
      'thinking' => ('thinking', Icons.psychology_outlined, scheme.tertiary),
      'tool_use_error' => ('tool error', Icons.error_outline, scheme.error),
      'user-prompt-submit-hook' ||
      'hook' => ('hook', Icons.link_outlined, scheme.secondary),
      'repo-rules' || 'workstation' || 'file' => (
        tag.replaceAll('-', ' '),
        Icons.folder_outlined,
        scheme.onSurfaceVariant,
      ),
      _ => (
        tag.replaceAll('-', ' ').replaceAll('_', ' '),
        Icons.sell_outlined,
        scheme.onSurfaceVariant,
      ),
    };

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.small)),
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// One log line: a gutter carrying the role, then the content. A transcript
/// reads top to bottom at a single left edge, so alternating alignment and
/// rounded bubbles only cost horizontal space and make long tool output
/// harder to scan.
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final role = entry.role;

    final (String label, IconData icon, Color color) = switch (role) {
      'user' => ('you', Icons.person_outline, scheme.primary),
      'assistant' => ('omp', Icons.smart_toy_outlined, scheme.onSurface),
      'system' => ('system', Icons.info_outline, scheme.onSurfaceVariant),
      _ => (role, Icons.chat_bubble_outline, scheme.onSurfaceVariant),
    };

    // A user line gets a tinted background so the eye can find the turn
    // boundaries in a long log without relying on colour alone: the gutter
    // label and icon differ too.
    final isUser = role == 'user';

    return Semantics(
      label: '$label${entry.open ? ", streaming" : ""}: ${entry.text}',
      child: Container(
        color: isUser ? scheme.surfaceContainerHighest : null,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Gutter(icon: icon, label: label, color: color),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (entry.thinking.isNotEmpty)
                    _ThinkingBlock(
                      text: entry.thinking,
                      color: scheme.onSurfaceVariant,
                    ),
                  for (final segment in _splitTagged(entry.text))
                    if (segment.tag != null)
                      _TaggedBlock(tag: segment.tag!, text: segment.text)
                    else if (segment.text.isNotEmpty)
                      SelectableText(
                        segment.text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                  if (entry.open) ...[
                    const SizedBox(height: AppSpacing.xs),
                    SizedBox(
                      width: 72,
                      height: 2,
                      child: LinearProgressIndicator(
                        minHeight: 2,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed-width left column naming who produced the line. Fixed so every row
/// aligns at the same content edge.
class _Gutter extends StatelessWidget {
  const _Gutter({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  static const double width = 68;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(top: 2, right: AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: color, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final quietColor = widget.color.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: _expanded ? 'Collapse thinking' : 'Expand thinking',
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: quietColor,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Icon(Icons.psychology_outlined, size: 14, color: quietColor),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    'Thinking',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: quietColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              top: AppSpacing.xs,
              bottom: AppSpacing.xs,
            ),
            child: SelectableText(
              widget.text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: quietColor, fontStyle: FontStyle.italic),
            ),
          ),
      ],
    );
  }
}

/// Compact card for one tool call: name, argument summary, and a
/// running/done/failed status with icon and word, always visible. Detail
/// (full arguments and output) is collapsed by default behind a bounded,
/// independently scrollable region so streaming output never resizes the
/// card itself and never disturbs the transcript's scroll position.
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.entry});

  final TranscriptEntry entry;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final ok = entry.toolOk;
    final IconData statusIcon;
    final Color statusColor;
    final String statusLabel;
    if (entry.open) {
      statusIcon = Icons.hourglass_top;
      statusColor = theme.colorScheme.tertiary;
      statusLabel = 'Running';
    } else if (ok == false) {
      statusIcon = Icons.error_outline;
      statusColor = theme.colorScheme.error;
      statusLabel = 'Failed';
    } else {
      statusIcon = Icons.check_circle_outline;
      statusColor = theme.colorScheme.primary;
      statusLabel = 'Done';
    }
    final name = entry.toolName ?? 'tool';
    final summary = _summarizeToolInput(entry.toolInput);
    final formattedInput = _formatToolInput(entry.toolInput);

    return Semantics(
      label:
          'Tool $name, $statusLabel${summary.isNotEmpty ? ', $summary' : ''}',
      child: Padding(
        padding: const EdgeInsets.only(
          left: _Gutter.width + AppSpacing.sm,
          right: AppSpacing.sm,
          top: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.medium),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        Icon(Icons.build_outlined, size: 18),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(name, style: theme.textTheme.titleSmall),
                              if (summary.isNotEmpty)
                                Text(
                                  summary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Icon(statusIcon, color: statusColor, size: 18),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusColor,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: AppSpacing.sm),
                    if (formattedInput.isNotEmpty) ...[
                      Text('Arguments', style: theme.textTheme.labelSmall),
                      const SizedBox(height: AppSpacing.xs),
                      _CodeBlock(text: formattedInput, maxHeight: 160),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (entry.text.isNotEmpty) ...[
                      Text('Output', style: theme.textTheme.labelSmall),
                      const SizedBox(height: AppSpacing.xs),
                      _CodeBlock(text: entry.text, maxHeight: 240),
                    ] else if (entry.open)
                      Text(
                        'Waiting for output...',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = entry.level ?? 'info';
    final Color color;
    final IconData icon;
    switch (level) {
      case 'error':
        color = theme.colorScheme.error;
        icon = Icons.error_outline;
        break;
      case 'warning':
        color = theme.colorScheme.tertiary;
        icon = Icons.warning_amber_outlined;
        break;
      default:
        color = theme.colorScheme.onSurfaceVariant;
        icon = Icons.info_outline;
    }
    return Semantics(
      label: 'Notice, $level: ${entry.text}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: SelectableText(
                entry.text,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: entry.text,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle_outlined,
                size: 10,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  entry.text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
