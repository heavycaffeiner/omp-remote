import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol.dart';
import '../relay_client.dart';
import '../session_store.dart';
import '../theme.dart';

/// The session's model settings: which model this session runs, how much
/// thinking, and which model each named role resolves to.
///
/// Its own screen rather than a slash command or a cycle button: this is a
/// set of settings, and cycling through models blind is not choosing one.
class ModelScreen extends StatefulWidget {
  const ModelScreen({
    required this.relayClient,
    required this.canControl,
    required this.sessionStore,
    super.key,
  });

  final RelayClient relayClient;
  final bool canControl;

  /// The live session state, listened to rather than sampled: a model or
  /// thinking change pushes a new snapshot at once, and this screen is where
  /// the user is looking when it arrives.
  final SessionStore sessionStore;

  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  List<ModelInfo> _models = const [];
  List<ModelRoleInfo> _roles = const [];
  ModelInfo? _current;
  bool _loading = true;
  String? _error;
  String? _applying;

  @override
  void initState() {
    super.initState();
    widget.sessionStore.addListener(_onStateChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.sessionStore.removeListener(_onStateChanged);
    super.dispose();
  }

  /// The workstation pushes a fresh snapshot the moment a model or thinking
  /// level changes, including a change made from another client.
  void _onStateChanged() {
    if (!mounted) return;
    final model = widget.sessionStore.state?.model;
    setState(() {
      if (model != null) _current = model;
    });
  }

  /// One round trip carries both halves: the authenticated models and the
  /// role assignments. Splitting them would let the screen render a role
  /// pointing at a model the list does not contain.
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
        _roles = ModelRoleInfo.listFromJson(map['roles']);
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

  /// Switches the model this session runs, which is what `/switch` does at
  /// the workstation. It takes hold on the next turn.
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

  /// Assigns or clears a role. The reply carries the whole role list back, so
  /// the screen shows what the workstation stored rather than what it hoped
  /// for: a preserved effort suffix shows up here.
  Future<void> _assignRole(String role, ModelInfo? model) async {
    setState(() => _applying = 'role:$role');
    try {
      final data = await widget.relayClient.sendCommand(
        CommandName.setModelRole,
        args: {'role': role, if (model != null) 'model': model.label},
      );
      if (!mounted) return;
      setState(() {
        _roles = ModelRoleInfo.listFromJson(asMap(data)['roles']);
        _applying = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not set $role: $e')));
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Semantics(header: true, child: const Text('Model')),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'This session'),
              Tab(text: 'Roles'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Reload',
              onPressed: _loading ? null : () => unawaited(_load()),
            ),
          ],
        ),
        body: SafeArea(
          child: TabBarView(
            children: [_buildSessionTab(context), _buildRolesTab(context)],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionTab(BuildContext context) {
    final state = widget.sessionStore.state;
    final locked = !widget.canControl;
    // The state snapshot names them for the model in use. The model list is
    // the fallback for a client that attached before the first snapshot, and
    // an empty result means this model takes no effort setting at all.
    final currentRow = _models.firstWhere(
      (m) => m.label == _current?.label,
      orElse: () => const ModelInfo(provider: '', id: ''),
    );
    final levels = state?.thinkingLevels ?? currentRow.thinking ?? const [];

    return Column(
      children: [
        if (locked) _readOnlyNote(context),
        // Thinking belongs with the model: it is the same decision about how
        // much the session is allowed to spend. The levels come from the
        // workstation per model, because `high` and `xhigh` exist on some
        // models and not others, and offering one the model rejects is worse
        // than not offering it.
        ListTile(
          leading: const Icon(Icons.psychology_outlined, size: 20),
          title: const Text('Thinking'),
          subtitle: Text(
            levels.isEmpty
                ? 'This model has no thinking control'
                : (state?.thinkingLevel ??
                      'not set for this session, using the workstation default'),
          ),
          trailing: DropdownButton<String>(
            value: levels.contains(state?.thinkingLevel)
                ? state?.thinkingLevel
                : null,
            hint: const Text('level'),
            onChanged: (locked || levels.isEmpty)
                ? null
                : (value) {
                    if (value == null) return;
                    unawaited(_send(CommandName.setThinking, {'level': value}));
                  },
            items: [
              for (final level in levels)
                DropdownMenuItem(value: level, child: Text(level)),
            ],
          ),
        ),
        // Fast mode, extended context, and the service tier are not here at
        // all: the extension API exposes the model, the thinking level, and
        // the role assignments, and nothing else about how a session spends.
        // A row that could never show a value or take one is worse than its
        // absence.
        const Divider(),
        Expanded(
          child: _ModelList(
            models: _models,
            loading: _loading,
            error: _error,
            onRetry: () => unawaited(_load()),
            selectedLabel: _current?.label,
            busyLabel: _applying,
            enabled: widget.canControl && _applying == null,
            onPick: (model) => unawaited(_apply(model)),
          ),
        ),
      ],
    );
  }

  Widget _buildRolesTab(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return _errorBody(context, error, () => unawaited(_load()));
    }

    return ListView(
      children: [
        if (!widget.canControl) _readOnlyNote(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Text(
            'A role is a named slot the workstation resolves as @role. '
            'These are settings shared by every session on the machine, '
            'not just this one, and they apply from the next turn.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final role in _roles) _buildRoleTile(context, role),
      ],
    );
  }

  Widget _buildRoleTile(BuildContext context, ModelRoleInfo role) {
    final theme = Theme.of(context);
    final busy = _applying == 'role:${role.role}';
    final assigned = role.configured;
    final resolved = role.resolved;

    // Three facts, in the order a reader needs them: what the slot is for,
    // what it holds, and what a turn would actually use when it holds
    // nothing.
    final lines = <String>[];
    if (role.purpose != null) lines.add(role.purpose!);
    if (assigned != null) {
      lines.add(assigned);
    } else if (resolved != null) {
      lines.add('unset, falls back to ${resolved.label}');
    } else {
      lines.add('unset');
    }
    if (role.source != null && assigned != null) {
      lines.add('from ${role.source}');
    }

    return ListTile(
      leading: Icon(
        assigned != null ? Icons.label : Icons.label_outline,
        size: 20,
      ),
      title: Text(role.role, style: monospaceStyle(context, fontSize: 13)),
      subtitle: Text(lines.join('\n'), style: theme.textTheme.bodySmall),
      isThreeLine: lines.length > 2,
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (assigned != null && widget.canControl
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    tooltip: 'Clear ${role.role}',
                    onPressed: () => unawaited(_assignRole(role.role, null)),
                  )
                : null),
      onTap: (!widget.canControl || _applying != null)
          ? null
          : () => unawaited(_pickForRole(role)),
    );
  }

  Future<void> _pickForRole(ModelRoleInfo role) async {
    final picked = await Navigator.of(context).push<ModelInfo>(
      MaterialPageRoute<ModelInfo>(
        builder: (_) => _RolePickerScreen(
          role: role.role,
          models: _models,
          selectedLabel: role.configured?.split(':').first,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _assignRole(role.role, picked);
  }

  Widget _readOnlyNote(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
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
    );
  }
}

Widget _errorBody(BuildContext context, String error, VoidCallback onRetry) {
  final theme = Theme.of(context);
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
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

/// The full authenticated model list, filtered in place. Hundreds of rows are
/// normal, so the list is built lazily and the filter matches the name as
/// well as the id: nobody searches for a date stamp.
class _ModelList extends StatefulWidget {
  const _ModelList({
    required this.models,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.selectedLabel,
    required this.busyLabel,
    required this.enabled,
    required this.onPick,
  });

  final List<ModelInfo> models;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;
  final String? selectedLabel;
  final String? busyLabel;
  final bool enabled;
  final void Function(ModelInfo model) onPick;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = _filter.trim().toLowerCase();
    final visible = needle.isEmpty
        ? widget.models
        : widget.models
              .where(
                (m) =>
                    m.label.toLowerCase().contains(needle) ||
                    (m.name ?? '').toLowerCase().contains(needle),
              )
              .toList();

    return Column(
      children: [
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
              decoration: InputDecoration(
                labelText: widget.models.isEmpty
                    ? 'Filter models'
                    : 'Filter ${widget.models.length} models',
                prefixIcon: const Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _filter = value),
            ),
          ),
        ),
        Expanded(child: _buildBody(context, visible, theme)),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<ModelInfo> visible,
    ThemeData theme,
  ) {
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = widget.error;
    if (error != null) return _errorBody(context, error, widget.onRetry);
    if (visible.isEmpty) {
      return Center(
        child: Text(
          widget.models.isEmpty ? 'No models available' : 'No match',
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
        final selected = model.label == widget.selectedLabel;
        final busy = widget.busyLabel == model.label;

        // What separates two rows: the provider, whether it reasons, and how
        // much context it holds. Without those the list is a wall of ids.
        final facts = <String>[model.provider];
        if (model.reasoning) facts.add('reasoning');
        if (model.image) facts.add('image');
        final window = model.contextWindow;
        if (window != null) facts.add('${(window / 1000).round()}K');

        return ListTile(
          // Selection is the check icon plus the trailing word, never the
          // accent colour alone.
          leading: Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            size: 20,
          ),
          title: Text(
            model.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${facts.join(', ')}\n${model.id}',
            style: monospaceStyle(context, fontSize: 11),
          ),
          isThreeLine: true,
          trailing: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : (selected
                    ? Text('Current', style: theme.textTheme.labelSmall)
                    : null),
          onTap: (!widget.enabled || selected)
              ? null
              : () => widget.onPick(model),
        );
      },
    );
  }
}

/// The same list, opened to fill one role, returning the chosen model.
class _RolePickerScreen extends StatelessWidget {
  const _RolePickerScreen({
    required this.role,
    required this.models,
    required this.selectedLabel,
  });

  final String role;
  final List<ModelInfo> models;
  final String? selectedLabel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Semantics(header: true, child: Text('Model for $role')),
      ),
      body: SafeArea(
        child: _ModelList(
          models: models,
          loading: false,
          error: null,
          onRetry: () {},
          selectedLabel: selectedLabel,
          busyLabel: null,
          enabled: true,
          onPick: (model) => Navigator.of(context).pop(model),
        ),
      ),
    );
  }
}
