import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol.dart';
import '../session_store.dart';
import '../theme.dart';

/// A prominent, pinned card for one pending interactive request. Dismissible
/// only by answering (or by the request timing out or being cancelled
/// server side, which removes it from the store). Every control meets the
/// 48dp touch target minimum and carries a screen reader label.
class InteractiveRequestCard extends StatefulWidget {
  const InteractiveRequestCard({
    required this.pending,
    required this.onAnswer,
    super.key,
  });

  final PendingRequestState pending;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  State<InteractiveRequestCard> createState() => _InteractiveRequestCardState();
}

class _InteractiveRequestCardState extends State<InteractiveRequestCard> {
  Timer? _tickTimer;
  Duration? _remaining;

  @override
  void initState() {
    super.initState();
    final timeoutMs = widget.pending.request.timeoutMs;
    if (timeoutMs != null) {
      final deadline = widget.pending.receivedAt.add(
        Duration(milliseconds: timeoutMs),
      );
      _remaining = deadline.difference(DateTime.now());
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final left = deadline.difference(DateTime.now());
        if (!mounted) return;
        setState(() => _remaining = left.isNegative ? Duration.zero : left);
      });
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  bool get _expired => _remaining != null && _remaining! <= Duration.zero;

  @override
  Widget build(BuildContext context) {
    final request = widget.pending.request;
    final theme = Theme.of(context);

    final Widget body;
    switch (request) {
      case SelectRequest():
        body = _SelectBody(
          request: request,
          disabled: _expired,
          onAnswer: widget.onAnswer,
        );
      case ConfirmRequest():
        body = _ConfirmBody(
          request: request,
          disabled: _expired,
          onAnswer: widget.onAnswer,
        );
      case InputRequest():
        body = _InputBody(
          request: request,
          disabled: _expired,
          onAnswer: widget.onAnswer,
        );
      case EditorRequest():
        body = _EditorBody(
          request: request,
          disabled: _expired,
          onAnswer: widget.onAnswer,
        );
      case ApprovalRequest():
        body = _ApprovalBody(
          request: request,
          disabled: _expired,
          onAnswer: widget.onAnswer,
        );
      case UnknownRequest():
        body = Text(
          'Unsupported request type: ${request.kind}. Update the app to answer this.',
        );
    }

    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        color: theme.colorScheme.primaryContainer,
        margin: const EdgeInsets.all(AppSpacing.md),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.large),
          side: BorderSide(color: theme.colorScheme.primary, width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.priority_high,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Agent needs an answer',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (_remaining != null)
                    Semantics(
                      label: _expired
                          ? 'Timed out'
                          : '${_remaining!.inSeconds} seconds remaining',
                      excludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _expired
                                ? Icons.timer_off_outlined
                                : Icons.timer_outlined,
                            size: 14,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            _expired ? 'expired' : '${_remaining!.inSeconds}s',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              body,
            ],
          ),
        ),
      ),
    );
  }
}

/// Card body text and answer buttons render on the surface color (not the
/// primary container background) so long content stays readable; only the
/// card chrome uses the attention-getting primary container.
class _BodySurface extends StatelessWidget {
  const _BodySurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: child,
    );
  }
}

class _SelectBody extends StatelessWidget {
  const _SelectBody({
    required this.request,
    required this.disabled,
    required this.onAnswer,
  });

  final SelectRequest request;
  final bool disabled;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _BodySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(request.title, style: theme.textTheme.titleSmall),
          if (request.message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            SelectableText(request.message),
          ],
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < request.options.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            Semantics(
              button: true,
              label:
                  request.options[i].label +
                  (request.options[i].description != null
                      ? ', ${request.options[i].description}'
                      : ''),
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                ),
                onPressed: disabled ? null : () => onAnswer(selectResponse(i)),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(request.options[i].label),
                      if (request.options[i].description != null)
                        Text(
                          request.options[i].description!,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfirmBody extends StatelessWidget {
  const _ConfirmBody({
    required this.request,
    required this.disabled,
    required this.onAnswer,
  });

  final ConfirmRequest request;
  final bool disabled;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _BodySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(request.title, style: theme.textTheme.titleSmall),
          if (request.message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            SelectableText(request.message),
          ],
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Confirm ${request.title}',
                  child: FilledButton.icon(
                    onPressed: disabled
                        ? null
                        : () => onAnswer(confirmResponse(true)),
                    icon: const Icon(Icons.check),
                    label: const Text('Yes'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Decline ${request.title}',
                  child: OutlinedButton.icon(
                    onPressed: disabled
                        ? null
                        : () => onAnswer(confirmResponse(false)),
                    icon: const Icon(Icons.close),
                    label: const Text('No'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InputBody extends StatefulWidget {
  const _InputBody({
    required this.request,
    required this.disabled,
    required this.onAnswer,
  });

  final InputRequest request;
  final bool disabled;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  State<_InputBody> createState() => _InputBodyState();
}

class _InputBodyState extends State<_InputBody> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.request.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _BodySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.request.title, style: theme.textTheme.titleSmall),
          if (widget.request.message.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            SelectableText(widget.request.message),
          ],
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: '${widget.request.title} input field',
            textField: true,
            child: TextField(
              controller: _controller,
              enabled: !widget.disabled,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(hintText: widget.request.placeholder),
              onSubmitted: widget.disabled
                  ? null
                  : (value) => widget.onAnswer(valueResponse(value)),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            button: true,
            label: 'Submit answer',
            child: FilledButton.icon(
              onPressed: widget.disabled
                  ? null
                  : () => widget.onAnswer(valueResponse(_controller.text)),
              icon: const Icon(Icons.send),
              label: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorBody extends StatefulWidget {
  const _EditorBody({
    required this.request,
    required this.disabled,
    required this.onAnswer,
  });

  final EditorRequest request;
  final bool disabled;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  State<_EditorBody> createState() => _EditorBodyState();
}

class _EditorBodyState extends State<_EditorBody> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.request.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _BodySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.request.title, style: theme.textTheme.titleSmall),
          if (widget.request.language != null)
            Text(
              'Language: ${widget.request.language}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: '${widget.request.title} editor field',
            textField: true,
            child: TextField(
              controller: _controller,
              enabled: !widget.disabled,
              maxLines: 8,
              minLines: 4,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              style: monospaceStyle(context),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            button: true,
            label: 'Submit edited text',
            child: FilledButton.icon(
              onPressed: widget.disabled
                  ? null
                  : () => widget.onAnswer(valueResponse(_controller.text)),
              icon: const Icon(Icons.send),
              label: const Text('Submit'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalBody extends StatelessWidget {
  const _ApprovalBody({
    required this.request,
    required this.disabled,
    required this.onAnswer,
  });

  final ApprovalRequest request;
  final bool disabled;
  final void Function(Map<String, Object?> response) onAnswer;

  @override
  Widget build(BuildContext context) {
    final risk = request.risk;
    final theme = Theme.of(context);
    return _BodySurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.build_outlined,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'Tool approval: ${request.toolName}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (risk != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Icon(
                  Icons.warning_amber_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text('Risk: $risk', style: theme.textTheme.bodySmall),
              ],
            ),
          ],
          if (request.input != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.small),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  '${request.input}',
                  style: monospaceStyle(context),
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Deny actually blocks the tool. Allow and always do not approve it: '
            'the workstation still has to confirm this locally at the keyboard.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                button: true,
                label: 'Deny this tool call. This actually blocks it.',
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: disabled
                      ? null
                      : () => onAnswer(approvalResponse('deny')),
                  icon: const Icon(Icons.block),
                  label: const Text('Deny (blocks it)'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                button: true,
                label:
                    'Do not object once. The workstation still has to confirm this locally.',
                child: OutlinedButton.icon(
                  onPressed: disabled
                      ? null
                      : () => onAnswer(approvalResponse('allow')),
                  icon: const Icon(Icons.check),
                  label: const Text('Do not object'),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Semantics(
                button: true,
                label:
                    'Do not object to this tool from now on. The workstation still has to confirm each time locally.',
                child: OutlinedButton.icon(
                  onPressed: disabled
                      ? null
                      : () => onAnswer(approvalResponse('always')),
                  icon: const Icon(Icons.done_all),
                  label: const Text('Do not object (always)'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
