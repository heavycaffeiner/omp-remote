import 'dart:async';

import 'package:flutter/material.dart';

import '../protocol.dart';
import '../session_store.dart';

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
        color: theme.colorScheme.surfaceContainerHigh,
        margin: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.priority_high, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Agent needs an answer',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_remaining != null)
                    Text(
                      _expired ? 'expired' : '${_remaining!.inSeconds}s',
                      semanticsLabel: _expired
                          ? 'timed out'
                          : '${_remaining!.inSeconds} seconds remaining',
                      style: theme.textTheme.labelMedium,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              body,
            ],
          ),
        ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(request.title, style: Theme.of(context).textTheme.titleSmall),
        if (request.message.isNotEmpty) Text(request.message),
        const SizedBox(height: 8),
        for (var i = 0; i < request.options.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Semantics(
            button: true,
            label:
                request.options[i].label +
                (request.options[i].description != null
                    ? ', ${request.options[i].description}'
                    : ''),
            child: OutlinedButton(
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
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(request.title, style: Theme.of(context).textTheme.titleSmall),
        if (request.message.isNotEmpty) Text(request.message),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: 'Confirm ${request.title}',
                child: ElevatedButton(
                  onPressed: disabled
                      ? null
                      : () => onAnswer(confirmResponse(true)),
                  child: const Text('Yes'),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Semantics(
                button: true,
                label: 'Decline ${request.title}',
                child: OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => onAnswer(confirmResponse(false)),
                  child: const Text('No'),
                ),
              ),
            ),
          ],
        ),
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.request.title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (widget.request.message.isNotEmpty) Text(widget.request.message),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          enabled: !widget.disabled,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: widget.request.placeholder),
          onSubmitted: widget.disabled
              ? null
              : (value) => widget.onAnswer(valueResponse(value)),
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: 'Submit answer',
          child: ElevatedButton(
            onPressed: widget.disabled
                ? null
                : () => widget.onAnswer(valueResponse(_controller.text)),
            child: const Text('Submit'),
          ),
        ),
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.request.title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (widget.request.language != null)
          Text('Language: ${widget.request.language}'),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          enabled: !widget.disabled,
          maxLines: 8,
          minLines: 4,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          label: 'Submit edited text',
          child: ElevatedButton(
            onPressed: widget.disabled
                ? null
                : () => widget.onAnswer(valueResponse(_controller.text)),
            child: const Text('Submit'),
          ),
        ),
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Tool approval: ${request.toolName}',
          style: theme.textTheme.titleSmall,
        ),
        if (risk != null) Text('Risk: $risk'),
        if (request.input != null) ...[
          const SizedBox(height: 4),
          Text(
            '${request.input}',
            style: theme.textTheme.bodySmall,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 8),
        Text(
          'Deny actually blocks the tool. Allow and always do not approve it: '
          'the workstation still has to confirm this locally at the keyboard.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label: 'Deny this tool call. This actually blocks it.',
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                onPressed: disabled
                    ? null
                    : () => onAnswer(approvalResponse('deny')),
                child: const Text('Deny (blocks it)'),
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: 'Do not object once. The workstation still has to confirm this locally.',
              child: OutlinedButton(
                onPressed: disabled
                    ? null
                    : () => onAnswer(approvalResponse('allow')),
                child: const Text('Do not object'),
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: 'Do not object to this tool from now on. The workstation still has to confirm each time locally.',
              child: OutlinedButton(
                onPressed: disabled
                    ? null
                    : () => onAnswer(approvalResponse('always')),
                child: const Text('Do not object (always)'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
