import 'package:flutter/material.dart';

import '../session_store.dart';

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
    return ValueListenableBuilder<int>(
      valueListenable: widget.sessionStore.transcriptRevision,
      builder: (context, revision, _) {
        final entries = widget.sessionStore.entries;
        if (entries.isEmpty) {
          return const Center(child: Text('No messages yet.'));
        }
        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            return _MessageBubble(entry: entry);
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = entry.role == 'user';
    final bubbleColor = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHigh;
    final textColor = isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;
    final roleLabel = isUser
        ? 'You'
        : (entry.role == 'assistant' ? 'Assistant' : entry.role);
    final streamingSuffix = entry.open ? ' (streaming)' : '';

    return Semantics(
      label: '$roleLabel$streamingSuffix: ${entry.text}',
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    roleLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: textColor,
                    ),
                  ),
                  if (entry.open) ...[
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: textColor,
                      ),
                    ),
                  ],
                ],
              ),
              if (entry.thinking.isNotEmpty)
                _ThinkingBlock(text: entry.thinking, color: textColor),
              const SizedBox(height: 4),
              SelectableText(
                entry.text,
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
              ),
            ],
          ),
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
                    size: 18,
                    color: widget.color,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'Thinking',
                    style: TextStyle(
                      color: widget.color,
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
            padding: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
            child: Text(
              widget.text,
              style: TextStyle(
                color: widget.color.withValues(alpha: 0.75),
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = entry.toolOk;
    final IconData icon;
    final Color color;
    final String statusLabel;
    if (entry.open) {
      icon = Icons.hourglass_top;
      color = theme.colorScheme.tertiary;
      statusLabel = 'running';
    } else if (ok == false) {
      icon = Icons.error_outline;
      color = theme.colorScheme.error;
      statusLabel = 'failed';
    } else {
      icon = Icons.check_circle_outline;
      color = theme.colorScheme.primary;
      statusLabel = 'done';
    }
    final name = entry.toolName ?? 'tool';

    return Semantics(
      label: 'Tool $name, $statusLabel',
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name, style: theme.textTheme.titleSmall),
                  ),
                  Text(
                    statusLabel,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                ],
              ),
              if (entry.text.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(entry.text, style: theme.textTheme.bodySmall),
              ],
            ],
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
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
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
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Text(
            entry.text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
