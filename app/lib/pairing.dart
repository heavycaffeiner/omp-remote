// Parsing for the remote-omp:// pairing link. This link carries a
// credential and arrives from a camera or a tapped deep link, so every
// field is untrusted and validated before use.

import 'protocol.dart';

enum PairingTransport { direct, relay }

class PairingPayload {
  const PairingPayload({
    required this.transport,
    required this.url,
    required this.token,
    required this.role,
    this.agentId,
    this.name,
  });

  final PairingTransport transport;
  final Uri url;
  final String token;
  final ClientRole role;
  final String? agentId;
  final String? name;

  /// Parses and validates a `remote-omp://pair?...` link.
  ///
  /// Returns the payload on success, or a human readable error string
  /// naming exactly what is wrong with the input.
  static Object parse(String raw) {
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      return 'not a valid URI';
    }

    if (uri.scheme != 'remote-omp' || uri.host != 'pair') {
      return 'not a remote-omp pairing link';
    }

    final params = uri.queryParameters;

    final v = params['v'];
    if (v != '2') {
      return 'unsupported pairing version${v == null ? ' (missing v)' : ' ($v)'}';
    }

    final tRaw = params['t'];
    final PairingTransport transport;
    switch (tRaw) {
      case 'direct':
        transport = PairingTransport.direct;
        break;
      case 'relay':
        transport = PairingTransport.relay;
        break;
      default:
        return 'unknown transport type${tRaw == null ? ' (missing t)' : ' ($tRaw)'}';
    }

    final urlRaw = params['url'];
    if (urlRaw == null || urlRaw.isEmpty) {
      return 'missing url parameter';
    }
    final Uri url;
    try {
      url = Uri.parse(urlRaw);
    } on FormatException {
      return 'malformed url parameter';
    }
    if (url.scheme != 'ws' && url.scheme != 'wss') {
      return 'url must use ws or wss, got ${url.scheme.isEmpty ? '(none)' : url.scheme}';
    }

    final token = params['token'];
    if (token == null || token.isEmpty) {
      return 'missing token parameter';
    }

    final role = clientRoleFromJson(params['role']);
    if (role == null) {
      return 'role must be control or viewer';
    }

    final agentId = params['agent'];
    if (transport == PairingTransport.relay &&
        (agentId == null || agentId.isEmpty)) {
      return 'relay pairing requires an agent parameter';
    }

    final name = params['name'];

    return PairingPayload(
      transport: transport,
      url: url,
      token: token,
      role: role,
      agentId: transport == PairingTransport.relay ? agentId : null,
      name: (name == null || name.isEmpty) ? null : name,
    );
  }
}

// ---------------------------------------------------------------------------
// Pairing codes (docs/protocol.md, "Pairing codes")
// ---------------------------------------------------------------------------

/// Crockford base32 without I, L, O, and U: no two characters are
/// confusable when read off one screen and typed into another.
const String pairingCodeAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Result of validating and normalizing user-entered pairing code text.
/// Kept as its own type (rather than a bare `String`) because both a valid
/// code and an error message are strings; conflating them would make a
/// caller unable to tell success from failure.
class PairingCodeInput {
  const PairingCodeInput.valid(this.code) : error = null;
  const PairingCodeInput.invalid(this.error) : code = null;

  /// The normalized 6-character code, or null if invalid.
  final String? code;

  /// The reason the input was rejected, or null if valid.
  final String? error;

  bool get isValid => code != null;
}

/// Normalizes user-entered pairing code text: uppercases, then strips
/// spaces and dashes so a code copied with visual grouping still matches.
/// Validates against the pairing code alphabet before any network request
/// is made.
PairingCodeInput normalizePairingCode(String raw) {
  final normalized = raw.toUpperCase().replaceAll(RegExp('[ -]'), '');
  if (normalized.isEmpty) {
    return const PairingCodeInput.invalid('Code is required.');
  }
  if (normalized.length != 6) {
    return PairingCodeInput.invalid(
      'Code must be 6 characters, got ${normalized.length}.',
    );
  }
  for (final unit in normalized.codeUnits) {
    if (!pairingCodeAlphabet.codeUnits.contains(unit)) {
      return PairingCodeInput.invalid(
        'Code contains an invalid character: "${String.fromCharCode(unit)}". '
        'Use only 0-9 and A-Z, excluding I, L, O, and U.',
      );
    }
  }
  return PairingCodeInput.valid(normalized);
}
