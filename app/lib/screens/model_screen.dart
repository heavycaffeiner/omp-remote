import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../theme.dart';

/// The session's model settings: which model, how much thinking, fast mode.
///
/// Its own screen rather than a slash command or a cycle button: this is a
/// set of settings, and cycling through models blind is not choosing one.
class ModelScreen extends StatefulWidget {
  const ModelScreen({
    required this.relayClient,
    required this.canControl,
    required this.state,
    super.key,
  });

  final RelayClient relayClient;
  final bool canControl;

  /// The session's current model, thinking level, and fast mode, so the
  /// screen shows what is set rather than asking for it again.
  final StateSnapshot? state;

  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  List<ModelInfo> _models = const [];
  ModelInfo? _current;
  bool _loading = true;
  String? _error;
  String? _applying;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.relayClient.sendCommand(CommandName.models);
      final map = asMap(data);
      if (!mounted) return;
      setState(() {
        _models = [
          for (final entry in asList(map['models'])) ?ModelInfo.fromJson(entry),
        ];
        _current = ModelInfo.fromJson(map['current']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _apply(ModelInfo model) async {
    setState(() => _applying = model.label);
    try {
      await widget.relayClient.sendCommand(
        CommandName.setModel,
        args: {'provider': model.provider, 'id': model.id},
      );
      if (!mounted) return;
      setState(() {
        _current = model;
        _applying = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not switch model: $e')));
    }
  }

  Future<void> _send(CommandName cmd, Map<String, Object?> args) async {
    try {
      await widget.relayClient.sendCommand(cmd, args: args);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? _models
        : _models.where((m) => m.label.toLowerCase().contains(needle)).toList();
    final state = widget.state;
    final locked = !widget.canControl;

    return Scaffold(
      appBar: AppBar(
        title: Semantics(header: true, child: const Text('Model')),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (locked)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Text(
                  'Read-only connection: none of this can be changed.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            // Thinking and fast mode belong with the model: they are the same
            // decision about how much the session is allowed to spend.
            ListTile(
              leading: const Icon(Icons.psychology_outlined, size: 20),
              title: const Text('Thinking'),
              subtitle: Text(state?.thinkingLevel ?? 'unknown'),
              trailing: DropdownButton<String>(
                value: thinkingLevels.contains(state?.thinkingLevel)
                    ? state?.thinkingLevel
                    : null,
                hint: const Text('level'),
                onChanged: locked
                    ? null
                    : (value) {
                        if (value == null) return;
                        unawaited(
                          _send(CommandName.setThinking, {'level': value}),
                        );
                      },
                items: [
                  for (final level in thinkingLevels)
                    DropdownMenuItem(value: level, child: Text(level)),
                ],
              ),
            ),
            SwitchListTile(
              value: state?.fastMode?.enabled ?? false,
              onChanged: locked
                  ? null
                  : (value) => unawaited(
                      _send(CommandName.setFastMode, {'enabled': value}),
                    ),
              secondary: const Icon(Icons.bolt_outlined, size: 20),
              title: const Text('Fast mode'),
              subtitle: Text(
                state?.fastMode == null
                    ? 'unknown'
                    : (state!.fastMode!.active
                          ? 'On, active on this turn'
                          : (state.fastMode!.enabled
                                ? 'On, not active yet'
                                : 'Off')),
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Semantics(
                textField: true,
                label: 'Filter models',
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Filter models',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
            ),
            Expanded(child: _buildList(context, visible)),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context, List<ModelInfo> visible) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: () => unawaited(_load()),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _models.isEmpty ? 'No models available' : 'No match',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final model = visible[index];
        final selected = model.label == _current?.label;
        final busy = _applying == model.label;
        return ListTile(
          // Selection is the check icon plus the trailing word, never the
          // accent colour alone.
          leading: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
          ),
          title: Text(
            model.id,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monospaceStyle(context, fontSize: 13),
          ),
          subtitle: Text(model.provider, style: theme.textTheme.bodySmall),
          trailing: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (selected
                    ? Text('Current', style: theme.textTheme.labelSmall)
                    : null),
          onTap: (!widget.canControl || selected || _applying != null)
              ? null
              : () => unawaited(_apply(model)),
        );
      },
    );
  }
}
