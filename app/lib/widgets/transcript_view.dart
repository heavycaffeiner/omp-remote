import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../session_store.dart';
import '../theme.dart';
import 'diff_view.dart';
import 'markdown_text.dart';

/// Gap between transcript rows. One value, so the log has a single rhythm.
const double _rowGap = 10;

/// How close to the bottom still counts as following the tail.
const double _tailSlack = 48;

/// Size of the tiny uppercase role labels.
const double _labelSize = 10;

/// Renders the transcript as a log: a role label, then the content, at one
/// left edge. Only rebuilds the whole list when entries are added or removed
/// (driven by [SessionStore.transcriptRevision]); each row listens to its own
/// [TranscriptEntry.revision] so a streaming delta repaints just that row.
///
/// The view follows new output while the user is at the bottom and stops the
/// moment they scroll away, so reading back is never yanked out from under
/// them. A button appears to jump back.
class TranscriptView extends StatefulWidget {
  const TranscriptView({required this.sessionStore, super.key});

  final SessionStore sessionStore;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final ScrollController _scroll = ScrollController();

  /// True while the view should follow new output.
  bool _following = true;

  @override
  void initState() {
    super.initState();
    widget.sessionStore.transcriptRevision.addListener(_onTranscriptChanged);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.sessionStore.transcriptRevision.removeListener(_onTranscriptChanged);
    _scroll.dispose();
    super.dispose();
  }

  bool get _atBottom {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position.maxScrollExtent - position.pixels <= _tailSlack;
  }

  void _onScroll() {
    final atBottom = _atBottom;
    if (atBottom == _following) return;
    setState(() => _following = atBottom);
  }

  /// Re-pins the viewport to the bottom after the frame that changed its
  /// height. Sampling `_atBottom` before the rebuild is what keeps a user who
  /// scrolled up from being yanked back.
  ///
  /// One scheduling per frame without needing a guard: the row rebuilds at
  /// frame time, so deltas arriving faster than frames coalesce into one
  /// build. Measured at 300 schedulings for 600 deltas either way.
  void _pinTail() {
    if (!_following) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_following) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.position.pixels >= max) return;
      _scroll.jumpTo(max);
    });
  }

  void _onTranscriptChanged() {
    if (!_atBottom) return;
    _pinTail();
  }

  /// Returns the view to following the tail.
  ///
  /// The bottom is a moving target twice over: a lazy list revises its scroll
  /// extent as rows lay out, and the agent may still be talking. Animating to
  /// the extent sampled at the start lands short of both, and landing short
  /// clears `_following` again, which reads as the button doing nothing. So
  /// the remaining distance is re-read after the animation and closed until
  /// it stops moving.
  Future<void> _jumpToLatest() async {
    if (!_scroll.hasClients) return;
    setState(() => _following = true);
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    // Bounded: each pass either closes the gap or gives up, so a tail that
    // grows faster than this can close is left to `_pinTail` at the next
    // frame rather than spun on here.
    for (var pass = 0; pass < 5; pass++) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.position.pixels >= max) break;
      _scroll.jumpTo(max);
      await SchedulerBinding.instance.endOfFrame;
    }
    if (mounted && _atBottom && !_following) setState(() => _following = true);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.sessionStore.transcriptRevision,
      builder: (context, revision, _) {
        final entries = widget.sessionStore.entries;
        if (entries.isEmpty) return const _EmptyTranscript();
        return Stack(
          children: [
            // One selection region for the whole list instead of one per
            // row. Per-row regions cost 44ms against 22ms to first render a
            // replayed session; copying still works from this one.
            SelectionArea(
              // The scroll extent also changes with no scroll event and no
              // rebuild of the last row: rows laying out for the first time,
              // and a streaming row growing while the viewport is elsewhere.
              // A lazy list does not build the last row from the top of a
              // long transcript, so without this the tail is never pinned and
              // new output accumulates below the fold.
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  _pinTail();
                  return false;
                },
                child: ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.sm,
                    AppSpacing.md,
                    AppSpacing.lg,
                  ),
                  itemCount: entries.length,
                  separatorBuilder: (context, index) => SizedBox(
                    // Consecutive rows from the same speaker keep a tighter
                    // gap so they read as one block.
                    height: _startsRun(entries, index + 1)
                        ? _rowGap
                        : AppSpacing.xs,
                  ),
                  itemBuilder: (context, index) => _TranscriptRow(
                    key: ValueKey(entries[index].id),
                    entry: entries[index],
                    showLabel: _labelsRun(entries, index),
                    cwd: widget.sessionStore.state?.cwd,
                    // A streaming delta only bumps its own row's revision, so
                    // the last row re-pins the tail itself while it is built.
                    onGrew: index == entries.length - 1 ? _pinTail : null,
                  ),
                ),
              ),
            ),
            if (!_following)
              Positioned(
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: FloatingActionButton.small(
                  // The session screen owns no FAB, but a shared default hero
                  // tag would still throw across a route transition.
                  heroTag: null,
                  onPressed: _jumpToLatest,
                  tooltip: 'Jump to the latest output',
                  child: const Icon(Icons.keyboard_arrow_down),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Whether the entry at [index] starts a run: a stretch of consecutive
/// message rows from the same role. A tool card or a notice always breaks
/// one.
bool _startsRun(List<TranscriptEntry> entries, int index) {
  if (index <= 0 || index >= entries.length) return true;
  final entry = entries[index];
  final previous = entries[index - 1];
  if (entry.kind != TranscriptKind.message) return true;
  if (previous.kind != TranscriptKind.message) return true;
  return previous.role != entry.role;
}

/// Whether the entry at [index] draws its run's role label.
///
/// The label names a speaker for something they said, so it belongs on the
/// first row of the run that actually carries prose. Putting it on the first
/// row unconditionally loses it whenever a run opens with a thinking-only
/// row, which is what a turn that reasons before answering looks like.
bool _labelsRun(List<TranscriptEntry> entries, int index) {
  final entry = entries[index];
  if (entry.kind != TranscriptKind.message) return false;
  if (entry.text.trim().isEmpty) return false;
  for (var i = index - 1; i >= 0; i--) {
    if (_startsRun(entries, i + 1)) return true;
    if (entries[i].text.trim().isNotEmpty) return false;
  }
  return true;
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          'No activity yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Dispatches one entry to its renderer and repaints only on that entry's
/// own revision.
class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({
    required this.entry,
    required this.showLabel,
    this.cwd,
    this.onGrew,
    super.key,
  });

  final TranscriptEntry entry;

  /// Whether this row names its speaker.
  final bool showLabel;

  /// The session's working directory, used to print a path a phone can read:
  /// an absolute path spends its width on a prefix every row shares.
  final String? cwd;

  /// Called on every repaint of this row. Set only on the last row, whose
  /// height is what the viewport has to keep up with while it streams.
  final VoidCallback? onGrew;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: entry.revision,
      builder: (context, _) {
        onGrew?.call();
        return switch (entry.kind) {
          TranscriptKind.message => _MessageRow(
            entry: entry,
            showLabel: showLabel,
          ),
          TranscriptKind.tool => _ToolCard(entry: entry, cwd: cwd),
          TranscriptKind.notice => _NoticeLine(entry: entry),
          TranscriptKind.status ||
          TranscriptKind.system => _MarkerRow(text: entry.text),
        };
      },
    );
  }
}

/// Tiny uppercase label naming who produced the rows below it. A label costs
/// one 14dp line and no horizontal space, where a fixed gutter costs the
/// content width of every row in the transcript.
class _RoleLabel extends StatelessWidget {
  const _RoleLabel({
    required this.label,
    required this.color,
    this.wrap = false,
  });

  final String label;
  final Color color;

  /// Whether a label too long for its row wraps rather than being cut. A
  /// speaker label is one short word and never needs it; a session marker
  /// names a model id and does.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      maxLines: wrap ? 3 : 1,
      overflow: TextOverflow.ellipsis,
      textAlign: wrap ? TextAlign.center : TextAlign.start,
      style: monospaceStyle(context, fontSize: _labelSize).copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        height: 1.4,
      ),
    );
  }
}

/// One turn's worth of text. A prompt someone typed sits on a rounded
/// surface so the turn boundary is obvious; agent output is deliberately
/// card-less, since it dominates the transcript and a card around every turn
/// would spend the phone's narrow content width on borders.
class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.entry, required this.showLabel});

  final TranscriptEntry entry;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final role = entry.role;

    final (String label, bool boxed) = switch (role) {
      'user' => ('you', true),
      'assistant' => ('omp', false),
      'system' => ('system', false),
      'custom' || 'custom_message' => ('note', false),
      'toolResult' => ('tool', false),
      _ => (role, false),
    };
    final labelColor = role == 'user'
        ? scheme.primary
        : scheme.onSurfaceVariant;

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) _RoleLabel(label: label, color: labelColor),
        if (entry.thinking.isNotEmpty)
          _ThinkingBlock(text: entry.thinking, open: entry.open),
        for (final segment in _splitTagged(entry.text))
          if (segment.tag != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: _TaggedBlock(tag: segment.tag!, text: segment.text),
            )
          else if (segment.text.isNotEmpty)
            MarkdownText(
              text: segment.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
        if (entry.open && entry.text.isEmpty) const _WorkingCursor(),
      ],
    );

    // The label names the speaker only. The text itself is already exposed
    // by the Text and markdown children below, so repeating it here both
    // duplicated what a screen reader announces and rebuilt a copy of every
    // message on every frame the row was built.
    return Semantics(
      container: true,
      label: '$label${entry.open ? ", streaming" : ""}',
      child: boxed
          ? Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(AppRadius.medium),
              ),
              child: body,
            )
          : body,
    );
  }
}

/// Blinking caret shown while a turn is open but has produced no text yet,
/// so an agent that is thinking never looks like an agent that has stalled.
class _WorkingCursor extends StatefulWidget {
  const _WorkingCursor();

  @override
  State<_WorkingCursor> createState() => _WorkingCursorState();
}

class _WorkingCursorState extends State<_WorkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Working',
      child: FadeTransition(
        opacity: _controller.drive(Tween<double>(begin: 0.25, end: 1)),
        child: Container(
          width: 8,
          height: 14,
          margin: const EdgeInsets.only(top: AppSpacing.xxs),
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// A block of text rendered monospace and selectable, wrapping long lines.
///
/// It scrolled horizontally once, to keep a long line intact. On a phone
/// that hid the end of every line behind a gesture nothing advertised, so it
/// wraps: nothing on screen is cut off, and the text is still selectable in
/// full.
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
        borderRadius: BorderRadius.circular(AppRadius.extraSmall),
      ),
      child: SelectableText(text, style: monospaceStyle(context)),
    );
    if (maxHeight == null) return box;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight!),
      child: SingleChildScrollView(child: box),
    );
  }
}

/// Renders a tool call's arguments as a short single-line summary for the
/// collapsed header row.
///
/// The plugin sends arguments already stringified, so a raw payload is
/// usually a JSON document. Printing that verbatim fills the header with
/// quotes and braces, so it is decoded and reduced to the one value that
/// actually identifies the call.
String _summarizeToolInput(Object? input) {
  if (input == null) return '';
  if (input is String) {
    final trimmed = input.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _summarizeToolInput(jsonDecode(trimmed));
      } on FormatException {
        // Truncated or not JSON after all; fall through to the raw text.
      }
    }
    return _oneLine(input);
  }
  if (input is Map) {
    // The most identifying argument first: a header reading `id: 3` when the
    // call also carries a path says nothing useful.
    for (final key in const [
      'path',
      'file',
      'command',
      'pattern',
      'query',
      'task',
      'url',
    ]) {
      final value = input[key];
      if (value is String && value.trim().isNotEmpty) return _oneLine(value);
    }
    // Nested structures belong in the expanded arguments block, not here.
    final scalars = input.entries
        .where((e) => e.value is String || e.value is num || e.value is bool)
        .map((e) => '${e.key}=${_oneLine(e.value.toString())}')
        .join(' ');
    if (scalars.isNotEmpty) return scalars;
    return input.keys.join(' ');
  }
  if (input is List) return _oneLine(input.map(_scalarOrType).join(', '));
  return _oneLine(input.toString());
}

/// Renders a list element as itself when it is a scalar, else as its shape.
String _scalarOrType(Object? value) => switch (value) {
  String() || num() || bool() => value.toString(),
  Map() => '{...}',
  List() => '[...]',
  _ => '',
};

/// Collapses whitespace so a multi-line argument fits on the header row.
String _oneLine(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Pretty-prints a tool's arguments for the expanded detail view. JSON is
/// indented rather than shown as one long line, which is the only form a
/// nested payload is readable in.
String _formatToolInput(Object? input) {
  if (input == null) return '';
  if (input is String) {
    final trimmed = input.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
      } on FormatException {
        // Truncated or not JSON after all; show it as it arrived.
      }
    }
    return input;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(input);
  } on JsonUnsupportedObjectError {
    return input.toString();
  }
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

/// A tagged block, set apart from the prose around it by a left rule and a
/// label. Known tags get their own icon and accent; anything else falls back
/// to the tag name with a neutral icon, so a tag nobody anticipated still
/// reads as a block rather than as stray markup.
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
      padding: const EdgeInsets.only(left: AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: AppSpacing.xs),
              _RoleLabel(label: label, color: color),
            ],
          ),
          MarkdownText(
            text: text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsed-by-default reasoning disclosure. Thinking is long and
/// low-signal, so it never opens on its own and its collapsed form is one
/// line: a chevron and a label, nothing else.
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.text, required this.open});

  final String text;

  /// True while the turn is still streaming, which is when the label says so.
  final bool open;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: _expanded ? 'Collapse thinking' : 'Expand thinking',
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            // 28dp rather than 48: this is an inline disclosure inside a
            // paragraph, and a 48dp row per thinking block would push the
            // agent's actual answer off a phone screen. The row spans the
            // full content width, so the target is easy to hit.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 28),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: color,
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  _RoleLabel(
                    label: widget.open ? 'thinking...' : 'thinking',
                    color: color,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              bottom: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: color, width: 2)),
            ),
            child: MarkdownText(
              text: widget.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// Rewrites a path inside [cwd] as a path relative to it, and leaves
/// anything else alone. Applied to a whole argument summary too, since a
/// `bash` command line is mostly absolute paths.
String? _relativeToCwd(String? text, String? cwd) {
  if (text == null || cwd == null || cwd.isEmpty || cwd == '/') return text;
  final prefix = cwd.endsWith('/') ? cwd : '$cwd/';
  if (!text.contains(prefix)) return text;
  return text.replaceAll(prefix, '');
}

/// One tool invocation: a dense one-line header, then whatever detail the
/// call produced. Built by hand rather than with `ExpansionTile`, which
/// forces 48dp list-tile metrics and would make a transcript of a dozen
/// calls unreadable on a phone.
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.entry, this.cwd});

  final TranscriptEntry entry;
  final String? cwd;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.entry;
    final failed = !entry.open && entry.toolOk == false;
    final diff = entry.diff;
    final hasDiff = diff != null && diff.isNotEmpty;

    // A `Material` rather than a decorated `Container`: ink is painted by the
    // nearest ancestor Material, so a container's clip cannot contain the
    // press highlight and it spills over the rounded corners.
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.small),
        side: BorderSide(color: failed ? scheme.error : scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: _header(context),
            ),
          ),
          if (hasDiff)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: DiffView(diff: diff, maxHeight: _expanded ? 420 : 180),
            ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: _detail(context),
            ),
        ],
      ),
    );
  }

  /// Status, name, argument summary, and the disclosure chevron, on one line
  /// at phone width.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.entry;
    final name = entry.toolName ?? 'tool';
    // When the call changed a file, that path identifies it better than any
    // argument does, and the collapsed card shows the path nowhere else.
    // Printed relative to the session's directory: the absolute form spent
    // most of a phone's width on a prefix every row shares, and then
    // ellipsized the filename, which is the part that identifies the call.
    final path = _relativeToCwd(entry.path, widget.cwd);
    // A call with no path to name, whose whole output is one short line, says
    // more with the result than with its arguments: `ask` collapsed to the
    // word "questions" and hid the answer that was the point of asking. It
    // never displaces the path, which is what identifies a file edit, and it
    // never displaces an argument summary that is longer than the result.
    final result = entry.text.trim();
    final argumentSummary =
        _relativeToCwd(_summarizeToolInput(entry.toolInput), widget.cwd) ?? '';
    final resultInstead =
        !entry.open &&
        entry.toolOk != false &&
        result.isNotEmpty &&
        !result.contains('\n') &&
        result.length <= 80 &&
        argumentSummary.length <= result.length;
    final summary = (path != null && path.isNotEmpty)
        ? path
        : (resultInstead ? result : argumentSummary);
    final statusLabel = entry.open
        ? 'running'
        : (entry.toolOk == false ? 'failed' : 'done');

    return Semantics(
      label:
          'Tool $name, $statusLabel'
          '${summary.isNotEmpty ? ', $summary' : ''}. '
          '${_expanded ? 'Collapse' : 'Expand'} detail',
      child: Row(
        children: [
          _StatusDot(open: entry.open, ok: entry.toolOk),
          const SizedBox(width: AppSpacing.sm),
          // The name and the summary share one Expanded slot. Two sibling
          // flexibles leave the slack at the end of the row, which floats the
          // chevron away from the edge by however long the name happens to be.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monospaceStyle(context, fontSize: 12).copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    flex: 3,
                    child: Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monospaceStyle(
                        context,
                        fontSize: 11,
                      ).copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.entry;
    final formattedInput = _formatToolInput(entry.toolInput);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (formattedInput.isNotEmpty) ...[
          _RoleLabel(label: 'arguments', color: scheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.xxs),
          _CodeBlock(text: formattedInput, maxHeight: 160),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (entry.text.isNotEmpty) ...[
          _RoleLabel(label: 'output', color: scheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.xxs),
          _CodeBlock(text: entry.text, maxHeight: 240),
        ] else if (entry.open)
          Text(
            'Waiting for output...',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

/// Tool status as a small dot, with the state also in the parent's
/// `Semantics` label so it never rests on colour alone.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.open, required this.ok});

  final bool open;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (open) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: scheme.tertiary,
        ),
      );
    }
    final failed = ok == false;
    return Icon(
      failed ? Icons.close : Icons.check,
      size: 12,
      color: failed ? scheme.error : scheme.primary,
    );
  }
}

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final level = entry.level ?? 'info';
    final (IconData icon, Color color) = switch (level) {
      'error' => (Icons.error_outline, scheme.error),
      'warning' => (Icons.warning_amber_outlined, scheme.tertiary),
      _ => (Icons.info_outline, scheme.onSurfaceVariant),
    };
    return Semantics(
      label: 'Notice, $level: ${entry.text}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: MarkdownText(
              text: entry.text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Centred hairline marker for session events: a compaction, a branch, a
/// model change. These are boundaries in the log, not messages in it.
class _MarkerRow extends StatelessWidget {
  const _MarkerRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const line = Expanded(child: Divider());
    return Semantics(
      label: text,
      child: Row(
        children: [
          line,
          // Flexible, not fixed: a marker naming a model id is longer than
          // the space two dividers leave it, and a fixed label overflowed
          // the row rather than giving any of it back.
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: _RoleLabel(
                label: text,
                color: scheme.onSurfaceVariant,
                wrap: true,
              ),
            ),
          ),
          line,
        ],
      ),
    );
  }
}
