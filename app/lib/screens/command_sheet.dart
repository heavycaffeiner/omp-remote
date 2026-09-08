import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';

/// The four things a phone can do to a session beyond prompting it.
///
/// The workstation has 84 slash commands; a phone can drive four of them,
/// because the rest need `AgentSession`, `Settings`, or
/// `ExtensionCommandContext`, none of which an extension can reach. Listing
/// all of them made the screen a catalogue of things that do not work, so
/// only these appear, each with the surface it actually needs. Picking a
/// model is a preference and lives in Settings, not here.
class CommandSheet extends StatefulWidget {
  const CommandSheet({
    required this.relayClient,
    required this.sessionStore,
    required this.canControl,
    super.key,
  });

  final RelayClient relayClient;
  final SessionStore sessionStore;
  final bool canControl;

  @override
  State<CommandSheet> createState() => _CommandSheetState();
}

class _CommandSheetState extends State<CommandSheet> {
  bool _busy = false;

  /// Set once a side task is launched, so the sheet stops being a menu and
  /// becomes the place its answer arrives. The workstation opens its own
  /// modal for these; on a phone the sheet you launched it from is where you
  /// are already looking.
  String? _watching;
  String? _asked;

  @override
  void initState() {
    super.initState();
    widget.sessionStore.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    widget.sessionStore.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted && _watching != null) setState(() {});
  }

  /// The newest run of the side task being watched, or null before its first
  /// frame arrives.
  SubagentEvent? get _sideRun {
    final name = _watching;
    if (name == null) return null;
    final matching = widget.sessionStore.subagents
        .where((a) => a.name == name)
        .toList();
    return matching.isEmpty ? null : matching.last;
  }

  Future<void> _send(CommandName cmd, Map<String, Object?> args) async {
    setState(() => _busy = true);
    try {
      await widget.relayClient.sendCommand(cmd, args: args);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Launches a side task and keeps the sheet open on its result.
  Future<void> _launch(CommandName cmd, String name, String text) async {
    setState(() {
      _busy = true;
      _watching = name;
      _asked = text;
    });
    try {
      await widget.relayClient.sendCommand(cmd, args: {'text': text});
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _watching = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Composes the text the command needs. The workstation opens its own
  /// modal for these; an extension cannot open or read that one, so the
  /// phone asks here and sends the result.
  Future<String?> _compose({
    required String title,
    required String label,
    required String hint,
    required String action,
    int minLines = 3,
  }) async {
    // The dialog owns its controller: disposing one here, the moment
    // `showDialog` returns, tears it down while the route is still animating
    // out and its field still depends on it.
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _ComposeDialog(
        title: title,
        label: label,
        hint: hint,
        action: action,
        minLines: minLines,
      ),
    );
    return (text == null || text.isEmpty) ? null : text;
  }

  Future<void> _btw() async {
    final text = await _compose(
      title: 'Side question',
      label: 'Question',
      hint: 'Something to ask against what is already in context',
      action: 'Ask',
    );
    if (text == null) return;
    await _launch(CommandName.btw, 'btw', text);
  }

  Future<void> _omfg() async {
    final text = await _compose(
      title: 'Complaint',
      label: 'What went wrong',
      hint: 'The behaviour that should stop happening',
      action: 'Forge a rule',
    );
    if (text == null) return;
    await _launch(CommandName.omfg, 'omfg', text);
  }

  Future<void> _compact() async {
    // A focus is optional: compacting with none summarises everything.
    final focus = await _compose(
      title: 'Compact',
      label: 'Focus (optional)',
      hint: 'What the summary should keep',
      action: 'Compact',
      minLines: 2,
    );
    await _send(
      CommandName.compact,
      focus == null ? const {} : {'instructions': focus},
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todos = widget.sessionStore.todos;
    final disabled = !widget.canControl || _busy;
    final watching = _watching;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: watching != null
            ? _buildResult(context, watching)
            : _buildMenu(context, theme, todos, disabled),
      ),
    );
  }

  /// What a launched side task is doing, and its answer when it lands.
  Widget _buildResult(BuildContext context, String name) {
    final theme = Theme.of(context);
    final run = _sideRun;
    final phase = run?.phase ?? 'running';
    final done = run?.isTerminal ?? false;
    final failed = phase == 'failed' || phase == 'aborted';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Semantics(
              header: true,
              child: Text(
                name == 'btw' ? 'Side question' : 'Rule',
                style: theme.textTheme.titleSmall,
              ),
            ),
            const Spacer(),
            if (!done)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_asked != null) ...[
          Text(_asked!, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
        ],
        // It runs in its own session, so the main transcript keeps streaming
        // behind this sheet and there is nothing to interrupt.
        if (!done)
          Text(
            'Answering in a separate session...',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: MarkdownText(
                text: run?.text ?? '(no answer)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: failed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() {
                _watching = null;
                _asked = null;
              }),
              child: const Text('Back'),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMenu(
    BuildContext context,
    ThemeData theme,
    List<TodoItem> todos,
    bool disabled,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Semantics(
              header: true,
              child: Text('Commands', style: theme.textTheme.titleSmall),
            ),
            const Spacer(),
            if (_busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        _CommandTile(
          icon: Icons.checklist,
          title: 'Todo',
          subtitle: todos.isEmpty
              ? 'No todos on this session'
              : '${todos.where((t) => t.status == 'completed').length} of ${todos.length} done, shown above the transcript',
          onTap: disabled ? null : () => Navigator.of(context).pop(),
        ),
        _CommandTile(
          icon: Icons.compress,
          title: 'Compact',
          subtitle: 'Summarise the conversation to free context',
          onTap: disabled ? null : _compact,
        ),
        _CommandTile(
          icon: Icons.help_outline,
          title: 'Btw',
          subtitle: 'Ask a side question against the current context',
          onTap: disabled ? null : _btw,
        ),
        _CommandTile(
          icon: Icons.gavel_outlined,
          title: 'Omfg',
          subtitle: 'Turn a complaint into a standing rule',
          onTap: disabled ? null : _omfg,
        ),
        if (!widget.canControl) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Read-only connection: none of these can run.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// One text field and two buttons, owning its controller so the controller
/// outlives the route's exit animation.
class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog({
    required this.title,
    required this.label,
    required this.hint,
    required this.action,
    required this.minLines,
  });

  final String title;
  final String label;
  final String hint;
  final String action;
  final int minLines;

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        minLines: widget.minLines,
        maxLines: 8,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '$title. $subtitle',
      child: ListTile(
        leading: Icon(icon, size: 20),
        title: Text(title),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
        enabled: onTap != null,
      ),
    );
  }
}
