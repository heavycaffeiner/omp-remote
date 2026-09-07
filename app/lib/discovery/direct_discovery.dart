// Finds live omp sessions on a host by sweeping the port range the plugin's
// local server scans forward from (docs/protocol.md, "Discovery"). There is
// no extra listener or protocol beyond `GET /pair`: a live session answers
// with its payload, a dead port times out or refuses.
//
// Only a single host, chosen by the user, is ever swept. A full subnet scan
// would be slow and looks hostile on a network, so it is deliberately not
// attempted.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

/// One live session found by sweeping a host's port range.
class DiscoveredSession {
  const DiscoveredSession({
    required this.host,
    required this.port,
    required this.url,
    required this.agent,
    required this.name,
    required this.cwd,
  });

  final String host;
  final int port;
  final Uri url;
  final String agent;
  final String name;
  final String cwd;

  /// Parses one `/pair` response body. Returns null for anything that does
  /// not look like a codeless direct-discovery payload: a wrong type or a
  /// missing field means skip this entry, never throw.
  static DiscoveredSession? fromJson(
    Object? json, {
    required String host,
    required int port,
  }) {
    final map = asMap(json);
    if (asInt(map['v']) != 2) return null;
    if (asString(map['t']) != 'direct') return null;
    final urlRaw = asString(map['url']);
    final agent = asString(map['agent']);
    final name = asString(map['name']);
    final cwd = asString(map['cwd']);
    if (urlRaw == null || agent == null || name == null || cwd == null) {
      return null;
    }
    final url = Uri.tryParse(urlRaw);
    if (url == null || (url.scheme != 'ws' && url.scheme != 'wss')) {
      return null;
    }
    return DiscoveredSession(
      host: host,
      port: port,
      url: url,
      agent: agent,
      name: name,
      cwd: cwd,
    );
  }
}

/// First port the plugin's local server tries, and the width of its scan
/// range (docs/protocol.md, "Discovery"): 8788 through 8803 inclusive.
const int discoveryPortStart = 8788;
const int discoveryPortCount = 16;

/// Sweeps `GET http://<host>:<port>/pair` over the plugin's port range in
/// parallel, keeping only replies that parse as a live direct session.
/// A short per-port timeout keeps a sweep against a mostly-empty range fast;
/// a refused or timed-out port is silently skipped, never surfaced as an
/// error, since an empty range is the common case.
Future<List<DiscoveredSession>> discoverSessions(
  String host, {
  Duration timeout = const Duration(milliseconds: 400),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final results = await Future.wait(
      List.generate(discoveryPortCount, (i) => discoveryPortStart + i).map(
        (port) => _probe(client, host, port, timeout),
      ),
    );
    return [for (final r in results) ?r];
  } finally {
    client.close(force: true);
  }
}

Future<DiscoveredSession?> _probe(
  HttpClient client,
  String host,
  int port,
  Duration timeout,
) async {
  try {
    final request = await client
        .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/pair'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);
    final decoded = jsonDecode(body);
    return DiscoveredSession.fromJson(decoded, host: host, port: port);
  } catch (_) {
    // Timeout, refused connection, malformed JSON: all mean "no live
    // session here", not an error worth surfacing during a sweep.
    return null;
  }
}
