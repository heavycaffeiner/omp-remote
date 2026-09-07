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
