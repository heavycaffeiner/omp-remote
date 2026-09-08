// Finds the omp sessions on a workstation by asking one port
// (docs/protocol.md, "Discovery"). The first session to bind that port hosts
// every other one on the machine, so a single `GET /pair` returns the whole
// roster: there is no scan, no extra listener, and no second protocol.
//
// Only a single host, chosen by the user, is ever contacted. A subnet scan
// would be slow and looks hostile on a network, so it is not attempted.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';

/// The port the plugin's local server binds (docs/protocol.md, "Direct").
const int discoveryPort = 8788;

/// Splits `host`, `host:port`, `[v6]`, or `[v6]:port` into a host and a
/// port, defaulting to the discovery port. Returns null when the text is
/// not an address at all.
({String host, int port})? parseAddress(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;

  if (text.startsWith('[')) {
    final end = text.indexOf(']');
    if (end < 2) return null;
    final host = text.substring(1, end);
    final rest = text.substring(end + 1);
    if (rest.isEmpty) return (host: host, port: discoveryPort);
    if (!rest.startsWith(':')) return null;
    final port = int.tryParse(rest.substring(1));
    if (port == null || port < 1 || port > 65535) return null;
    return (host: host, port: port);
  }

  final colon = text.lastIndexOf(':');
  // More than one colon and no brackets is a bare IPv6 literal, which has
  // no room for a port.
  if (colon < 0 || text.indexOf(':') != colon) {
    return (host: text, port: discoveryPort);
  }
  final host = text.substring(0, colon);
  if (host.isEmpty) return null;
  final port = int.tryParse(text.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return (host: host, port: port);
}

/// One session on a discovered workstation.
class DiscoveredSession {
  const DiscoveredSession({required this.agentId, required this.name});

  final String agentId;
  final String name;

  static DiscoveredSession? fromJson(Object? json) {
    final map = asMap(json);
    final agentId = asString(map['agentId']);
    if (agentId == null || agentId.isEmpty) return null;
    return DiscoveredSession(
      agentId: agentId,
      name: asString(map['name']) ?? agentId,
    );
  }
}

/// A workstation answering on the discovery port, and the sessions it serves.
class DiscoveredWorkstation {
  const DiscoveredWorkstation({
    required this.host,
    required this.port,
    required this.url,
    required this.name,
    required this.sessions,
  });

  final String host;
  final int port;
  final Uri url;
  final String name;
  final List<DiscoveredSession> sessions;

  /// Parses one `/pair` response body. Returns null for anything that does not
  /// look like a codeless discovery payload: a wrong type or a missing field
  /// means skip it, never throw.
  static DiscoveredWorkstation? fromJson(
    Object? json, {
    required String host,
    required int port,
  }) {
    final map = asMap(json);
    if (asInt(map['v']) != 2) return null;
    if (asString(map['t']) != 'direct') return null;

    final rawUrl = asString(map['url']);
    if (rawUrl == null) return null;
    final url = Uri.tryParse(rawUrl);
    if (url == null || (url.scheme != 'ws' && url.scheme != 'wss')) return null;

    // Older plugins answer with a single `agent` and no roster; treat that as a
    // workstation serving exactly one session so pairing still works.
    final sessions = <DiscoveredSession>[];
    for (final entry in asList(map['agents'])) {
      final session = DiscoveredSession.fromJson(entry);
      if (session != null) sessions.add(session);
    }
    if (sessions.isEmpty) {
      final agent = asString(map['agent']);
      if (agent == null || agent.isEmpty) return null;
      sessions.add(
        DiscoveredSession(agentId: agent, name: asString(map['name']) ?? agent),
      );
    }

    return DiscoveredWorkstation(
      host: host,
      port: port,
      url: url,
      name: asString(map['name']) ?? host,
      sessions: sessions,
    );
  }
}

/// Asks one workstation whether it is listening, and which sessions it
/// serves. [address] accepts `host` or `host:port`. A refused or timed-out
/// port means nothing is there, which is the common case and not an error
/// worth surfacing.
Future<DiscoveredWorkstation?> discoverWorkstation(
  String address, {
  Duration timeout = const Duration(milliseconds: 800),
}) async {
  final parsed = parseAddress(address);
  if (parsed == null) return null;
  final host = parsed.host;
  final port = parsed.port;
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client
        .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/pair'))
        .timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    return DiscoveredWorkstation.fromJson(
      jsonDecode(body),
      host: host,
      port: port,
    );
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
