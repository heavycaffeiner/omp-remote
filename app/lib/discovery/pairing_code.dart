// Redeems a six-character pairing code against a host's local server
// (docs/protocol.md, "Pairing codes"). Direct-only: a relayed client has no
// route to the workstation's local `/pair`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'direct_discovery.dart' show discoveryPort;

/// Outcome of one redemption attempt. A sealed result type rather than a
/// thrown exception, because the caller must render three cases
/// differently: success, the server's own rejection message, and a
/// transport failure naming the host and port that could not be reached.
sealed class PairingCodeOutcome {
  const PairingCodeOutcome();
}

class PairingCodeSuccess extends PairingCodeOutcome {
  const PairingCodeSuccess({
    required this.url,
    required this.token,
    required this.role,
    required this.agent,
    required this.name,
    this.cwd,
  });

  final Uri url;
  final String token;
  final ClientRole role;
  final String agent;
  final String name;
  /// Absent from a hub payload, which publishes no filesystem paths.
  final String? cwd;
}

/// The server understood the request but rejected the code: unknown,
/// reused, or expired. Carries the server's `error` message verbatim.
class PairingCodeRejected extends PairingCodeOutcome {
  const PairingCodeRejected(this.message);
  final String message;
}

/// The request never got a well-formed response: DNS failure, refused
/// connection, timeout, or a malformed body. Names the host and port that
/// failed, since a 404 rejection and an unreachable host need different
/// fixes from the user.
class PairingCodeNetworkError extends PairingCodeOutcome {
  const PairingCodeNetworkError({
    required this.host,
    required this.port,
    required this.reason,
  });
  final String host;
  final int port;
  final String reason;
}

/// Redeems [code] against `http://<host>:<port>/pair?code=<code>`. The
/// token is returned only in [PairingCodeSuccess] and must never be logged
/// or rendered by the caller.
Future<PairingCodeOutcome> redeemPairingCode({
  required String host,
  required int port,
  required String code,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final uri = Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: '/pair',
      queryParameters: {'code': code},
    );
    final HttpClientRequest request;
    final HttpClientResponse response;
    try {
      request = await client.getUrl(uri).timeout(timeout);
      response = await request.close().timeout(timeout);
    } catch (e) {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: _describeNetworkError(e),
      );
    }

    final String body;
    try {
      body = await response.transform(utf8.decoder).join().timeout(timeout);
    } catch (e) {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: _describeNetworkError(e),
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: 'the server returned a response that was not valid JSON',
      );
    }
    final map = asMap(decoded);

    if (response.statusCode == 404) {
      final message = asString(map['error']) ?? 'unknown or expired pairing code';
      return PairingCodeRejected(message);
    }
    if (response.statusCode != 200) {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: 'server returned HTTP ${response.statusCode}',
      );
    }

    if (asInt(map['v']) != 2 || asString(map['t']) != 'direct') {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: 'the server response was not a recognized pairing payload',
      );
    }
    final urlRaw = asString(map['url']);
    final token = asString(map['token']);
    final role = clientRoleFromJson(map['role']);
    final agent = asString(map['agent']);
    final name = asString(map['name']);
    final url = urlRaw == null ? null : Uri.tryParse(urlRaw);
    // No cwd: the host serves anyone who can reach the port, so it does not
    // publish filesystem paths. The agent id carries the project name.
    if (url == null ||
        (url.scheme != 'ws' && url.scheme != 'wss') ||
        token == null ||
        role == null ||
        agent == null ||
        name == null) {
      return PairingCodeNetworkError(
        host: host,
        port: port,
        reason: 'the server response was missing an expected field',
      );
    }
    return PairingCodeSuccess(
      url: url,
      token: token,
      role: role,
      agent: agent,
      name: name,
      cwd: asString(map['cwd']),
    );
  } finally {
    client.close(force: true);
  }
}

/// Redeems [code] against the workstation's single discovery port. One
/// session hosts that port for the whole machine, so there is nothing to
/// search: the host either recognizes the code or rejects it.
Future<PairingCodeOutcome> redeemPairingCodeOnHost({
  required String host,
  required String code,
  Duration timeout = const Duration(seconds: 10),
}) {
  return redeemPairingCode(
    host: host,
    port: discoveryPort,
    code: code,
    timeout: timeout,
  );
}

String _describeNetworkError(Object error) {
  if (error is TimeoutException) return 'the request timed out';
  if (error is SocketException) {
    final osMessage = error.osError?.message;
    if (osMessage != null && osMessage.isNotEmpty) return osMessage;
    return error.message;
  }
  if (error is HttpException) return error.message;
  return error.toString();
}
