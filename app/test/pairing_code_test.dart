// Covers the two hand-rolled parsers this feature adds: the pairing-code
// validator (must reject before any network request is made) and the
// /pair response parsers (must degrade on malformed input, never throw).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/discovery/direct_discovery.dart';
import 'package:remote_omp/discovery/pairing_code.dart';
import 'package:remote_omp/pairing.dart';

void main() {
  group('normalizePairingCode', () {
    test('strips spaces and dashes and uppercases before validating', () {
      final result = normalizePairingCode('hz-e6 vd');
      expect(result.isValid, isTrue);
      expect(result.code, 'HZE6VD');
    });

    test('rejects a code containing a character outside the alphabet, '
        'without needing a host or port to check against', () {
      // 'I' is deliberately excluded from the alphabet (confusable with 1).
      // normalizePairingCode takes no host/port/client: rejection here is
      // necessarily local, before any request could be made.
      final result = normalizePairingCode('HZEIVD');
      expect(result.isValid, isFalse);
      expect(result.error, contains('invalid character'));
      expect(result.error, contains('I'));
    });
  });

  group('DiscoveredWorkstation.fromJson', () {
    test('skips a payload with wrong-typed fields instead of throwing', () {
      final json = {
        'v': '2', // wrong type: string instead of int
        't': 'direct',
        'url': 'ws://100.64.0.3:8788',
        'name': 'omp-remote',
        'agent': 12345, // wrong type: int instead of string
      };
      expect(
        () => DiscoveredWorkstation.fromJson(json, host: '100.64.0.3', port: 8788),
        returnsNormally,
      );
      expect(
        DiscoveredWorkstation.fromJson(json, host: '100.64.0.3', port: 8788),
        isNull,
      );
    });

    test('reads every session the host serves', () {
      final json = {
        'v': 2,
        't': 'direct',
        'url': 'ws://100.64.0.3:8788',
        'name': 'omp-remote',
        'agent': 'laptop/proj#ab12',
        'agents': [
          {'agentId': 'laptop/proj#ab12', 'name': 'proj'},
          {'agentId': 'laptop/tmp#cd34', 'name': 'tmp'},
          {'agentId': 42}, // malformed entry is skipped, not fatal
        ],
      };
      final found = DiscoveredWorkstation.fromJson(json, host: '100.64.0.3', port: 8788);
      expect(found, isNotNull);
      expect(found!.sessions.map((s) => s.agentId), [
        'laptop/proj#ab12',
        'laptop/tmp#cd34',
      ]);
    });

    test('falls back to the single agent when no roster is present', () {
      final json = {
        'v': 2,
        't': 'direct',
        'url': 'ws://100.64.0.3:8788',
        'name': 'omp-remote',
        'agent': 'laptop/proj#ab12',
      };
      final found = DiscoveredWorkstation.fromJson(json, host: '100.64.0.3', port: 8788);
      expect(found?.sessions.single.agentId, 'laptop/proj#ab12');
    });
  });

  group('redeemPairingCode against a real HTTP server', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test("surfaces the server's 404 error message verbatim", () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"error":"unknown or expired pairing code"}');
        await request.response.close();
      });

      final outcome = await redeemPairingCode(
        host: server.address.address,
        port: server.port,
        code: 'HZE6VD',
      );

      expect(outcome, isA<PairingCodeRejected>());
      expect(
        (outcome as PairingCodeRejected).message,
        'unknown or expired pairing code',
      );
    });

    test('accepts a hub payload that carries no cwd', () async {
      // The host serves anyone who can reach the port, so it publishes no
      // filesystem paths. Requiring cwd here rejected every real redemption.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"v":2,"t":"direct","url":"ws://100.64.0.3:8788",'
          '"name":"omp-remote","agent":"laptop/proj#ab12",'
          '"role":"control","token":"0123456789abcdef"}',
        );
        await request.response.close();
      });

      final outcome = await redeemPairingCode(
        host: server.address.address,
        port: server.port,
        code: 'HZE6VD',
      );

      expect(outcome, isA<PairingCodeSuccess>());
      final success = outcome as PairingCodeSuccess;
      expect(success.agent, 'laptop/proj#ab12');
      expect(success.token, '0123456789abcdef');
      expect(success.cwd, isNull);
    });

    test('names the host and port on a connection failure', () async {
      // Bind and immediately close: guarantees nothing is listening on this
      // port, producing a real connection-refused failure.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);

      final outcome = await redeemPairingCode(
        host: InternetAddress.loopbackIPv4.address,
        port: port,
        code: 'HZE6VD',
        timeout: const Duration(seconds: 2),
      );

      expect(outcome, isA<PairingCodeNetworkError>());
      final error = outcome as PairingCodeNetworkError;
      expect(error.host, InternetAddress.loopbackIPv4.address);
      expect(error.port, port);
    });
  });
}
