import 'package:flutter/material.dart';

import '../theme.dart';

/// The three ways to start a pairing, offered as one modal sheet instead of
/// three competing buttons on the home screen. The sheet only reports which
/// way the user picked; it knows nothing about profiles or the network, so
/// the caller keeps owning navigation and error display.
sealed class PairingChoice {
  const PairingChoice();
}

/// User picked "Scan a QR code".
class ScanQrChoice extends PairingChoice {
  const ScanQrChoice();
}

/// User picked "Enter a code".
class EnterCodeChoice extends PairingChoice {
  const EnterCodeChoice();
}

/// User picked "Paste a link" and typed or pasted the link text.
class PasteLinkChoice extends PairingChoice {
  const PasteLinkChoice(this.link);

  final String link;
}

/// Modal bottom sheet listing the three ways to pair. Pasting a link is
/// handled inline: the text field appears in the sheet itself rather than
/// navigating away to reveal it.
class PairingSheet extends StatefulWidget {
  const PairingSheet({super.key});

  /// Shows the sheet and returns the user's choice, or null if dismissed.
  static Future<PairingChoice?> show(BuildContext context) {
    return showModalBottomSheet<PairingChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const PairingSheet(),
    );
  }

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  bool _showLinkField = false;
  final _linkController = TextEditingController();

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  void _submitLink() {
    Navigator.of(context).pop(PasteLinkChoice(_linkController.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.md + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Text(
                'Add a connection',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
          _PairingOptionTile(
            icon: Icons.qr_code_scanner,
            title: 'Scan a QR code',
            subtitle: 'Point the camera at the code /remote prints.',
            onTap: () => Navigator.of(context).pop(const ScanQrChoice()),
          ),
          _PairingOptionTile(
            icon: Icons.dialpad,
            title: 'Enter a code',
            subtitle: 'Type the short code shown on the workstation.',
            onTap: () => Navigator.of(context).pop(const EnterCodeChoice()),
          ),
          _PairingOptionTile(
            icon: Icons.link,
            title: 'Paste a link',
            subtitle: 'Paste the whole remote-omp:// link.',
            onTap: () => setState(() => _showLinkField = !_showLinkField),
          ),
          if (_showLinkField) ...[
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              label: 'Pairing link',
              textField: true,
              child: TextField(
                controller: _linkController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Pairing link',
                  hintText: 'remote-omp://pair?v=2&...',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                maxLines: 2,
                minLines: 1,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitLink(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Semantics(
              button: true,
              label: 'Connect using this link',
              child: FilledButton(
                onPressed: _submitLink,
                child: const Text('Connect'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _PairingOptionTile extends StatelessWidget {
  const _PairingOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
      onTap: onTap,
    );
  }
}
