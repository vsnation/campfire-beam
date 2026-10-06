// BeamExplorerClient against a fake HTTP layer: failover, timeouts, the
// status cache, stale explorers, Tor, URL building, and decoding of real
// responses (fixtures captured from the live explorers on 2026-10-06).
//
// Observed live while writing this: explorer-api.beamprivacy.com failed the
// TLS handshake ("unrecognized name"), explorer.0xmx.net timed out once at
// 10 s and answered in 1 s on retry, and BeamSmart.net:8000 answered in
// 0.2 s. Failover is not hypothetical.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/networking/http.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/explorer/explorer_table.dart';

const _dexCid =
    '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';

String _fixture(String name) =>
    File('test/beam/sync/fixtures/$name').readAsStringSync();

/// Real /status answer: height 4067918, timestamp 1791272258.0
/// (2026-10-06T07:37:38Z).
final _statusJson = _fixture('explorer_status.json');
final _statusTip = DateTime.utc(2026, 10, 6, 7, 37, 38);

typedef _Handler = Future<Response> Function(Uri url);

class _FakeHttp extends HTTP {
  _FakeHttp(this.handler);

  _Handler handler;
  final calls = <Uri>[];
  final proxies = <BeamProxyInfo?>[];

  @override
  Future<Response> get({
    required Uri url,
    Map<String, String>? headers,
    required ({InternetAddress host, int port})? proxyInfo,
    Duration? connectionTimeout,
  }) {
    calls.add(url);
    proxies.add(proxyInfo);
    return handler(url);
  }
}

Response _ok(String body, {DateTime? date}) => Response(
  utf8.encode(body),
  200,
  headers: {if (date != null) 'date': HttpDate.format(date)},
);

Response _code(int code) => Response(utf8.encode(''), code);

String _statusAt(int height, DateTime tip) => jsonEncode({
  'height': height,
  'hash': 'ab' * 32,
  'timestamp': tip.millisecondsSinceEpoch / 1000,
  'peers_count': 50,
});

void main() {
  // Device clock 2 minutes after the fixture's tip.
  var now = DateTime.utc(2026, 10, 6, 7, 39, 38);
  late _FakeHttp http;

  BeamExplorerClient client({
    BeamProxyInfoProvider? proxyInfo,
    Duration statusTimeout = const Duration(seconds: 6),
  }) => BeamExplorerClient(
    proxyInfo: proxyInfo ?? () => null,
    http: http,
    statusTimeout: statusTimeout,
    now: () => now,
  );

  setUp(() {
    now = DateTime.utc(2026, 10, 6, 7, 39, 38);
    http = _FakeHttp((_) async => _ok(_statusJson, date: now));
  });

  group('status()', () {
    test('decodes the real /status answer, float timestamp included', () async {
      final s = await client().status();
      expect(s.height, 4067918);
      expect(s.timestamp, _statusTip);
      expect(s.hash, hasLength(64));
      expect(s.peersCount, 69);
      expect(s.node, 'https://explorer.0xmx.net/api');
      expect(s.receivedAt, now);
      expect(s.serverTime, now);
      expect(s.deviceClockOffset, Duration.zero);
      expect(s.tipAgeAt(now), const Duration(minutes: 2));
      expect(
        http.calls.single.toString(),
        'https://explorer.0xmx.net/api/status',
      );
    });

    test('fails over: TLS error, then HTTP 503, then the third node', () async {
      http.handler = (url) async {
        if (url.host == 'explorer.0xmx.net') {
          throw const HandshakeException('unrecognized name');
        }
        if (url.host == 'explorer-api.beamprivacy.com') return _code(503);
        return _ok(_statusJson, date: now);
      };
      final c = client();
      final s = await c.status();
      expect(s.node, 'https://BeamSmart.net:8000');
      expect(http.calls.map((u) => u.host), [
        'explorer.0xmx.net',
        'explorer-api.beamprivacy.com',
        'beamsmart.net',
      ]);
      expect(http.calls.last.toString(), 'https://beamsmart.net:8000/status');

      // The node that answered is asked first next time.
      http.calls.clear();
      now = now.add(const Duration(seconds: 25));
      await c.status();
      expect(http.calls.map((u) => u.host), ['beamsmart.net']);
    });

    test('a hanging node is abandoned after the short timeout', () async {
      final never = Completer<Response>();
      http.handler = (url) => url.host == 'explorer.0xmx.net'
          ? never.future
          : Future.value(_ok(_statusJson, date: now));
      final s = await client(statusTimeout: const Duration(milliseconds: 50))
          .status();
      expect(s.node, 'https://explorer-api.beamprivacy.com');
    });

    test('all nodes down: BeamExplorerException naming each failure', () async {
      http.handler = (url) async {
        if (url.host == 'explorer.0xmx.net') {
          throw const SocketException('connection refused');
        }
        if (url.host == 'explorer-api.beamprivacy.com') {
          return Response(utf8.encode('<html>'), 200);
        }
        return _code(500);
      };
      final error = await client().status().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect(error, isA<BeamExplorerException>());
      final failures = (error! as BeamExplorerException).failures;
      expect(failures, hasLength(3));
      expect(failures['https://explorer.0xmx.net/api'], contains('network'));
      expect(
        failures['https://explorer-api.beamprivacy.com'],
        contains('not JSON'),
      );
      expect(failures['https://BeamSmart.net:8000'], 'HTTP 500');
    });

    test('valid JSON without a height counts as a failure', () async {
      http.handler = (url) async => url.host == 'explorer.0xmx.net'
          ? _ok('{"error":"busy"}')
          : _ok(_statusJson, date: now);
      final s = await client().status();
      expect(s.node, 'https://explorer-api.beamprivacy.com');
    });

    test('cached for 20 s; forceRefresh bypasses the cache', () async {
      final c = client();
      await c.status();
      now = now.add(const Duration(seconds: 19));
      await c.status();
      expect(http.calls, hasLength(1));
      await c.status(forceRefresh: true);
      expect(http.calls, hasLength(2));
      now = now.add(const Duration(seconds: 21));
      await c.status();
      expect(http.calls, hasLength(3));
    });

    test(
      'a device clock that jumps backwards does not pin the cache',
      () async {
        final c = client();
        await c.status();
        now = now.subtract(const Duration(hours: 1));
        await c.status();
        expect(http.calls, hasLength(2));
      },
    );

    test('concurrent callers share one request', () async {
      final gate = Completer<Response>();
      http.handler = (_) => gate.future;
      final c = client();
      final a = c.status();
      final b = c.status();
      gate.complete(_ok(_statusJson, date: now));
      expect((await a).height, (await b).height);
      expect(http.calls, hasLength(1));
    });

    test('a stale explorer is skipped for a fresh one', () async {
      http.handler = (url) async => url.host == 'explorer.0xmx.net'
          ? _ok(
              _statusAt(4067000, now.subtract(const Duration(hours: 15))),
              date: now,
            )
          : _ok(_statusJson, date: now);
      final s = await client().status();
      expect(s.height, 4067918);
      expect(http.calls, hasLength(2));
    });

    test('when every explorer is stale, the highest one is returned', () async {
      http.handler = (url) async {
        final height = switch (url.host) {
          'explorer.0xmx.net' => 4067000,
          'explorer-api.beamprivacy.com' => 4067500,
          _ => 4067100,
        };
        final tip = now.subtract(const Duration(hours: 1));
        return _ok(_statusAt(height, tip), date: now);
      };
      final s = await client().status();
      expect(s.height, 4067500);
      expect(s.tipAgeAt(now), const Duration(hours: 1));
      expect(http.calls, hasLength(3));
    });

    test('explorer age uses the server clock, so a wrong device clock does '
        'not make it look stale', () async {
      // Device is 1 h ahead; the server's Date header is right.
      final realNow = now;
      now = realNow.add(const Duration(hours: 1));
      http.handler = (_) async => _ok(_statusJson, date: realNow);
      final s = await client().status();
      expect(http.calls, hasLength(1), reason: 'first node accepted as fresh');
      expect(s.tipAgeAt(now), const Duration(minutes: 2));
      expect(s.deviceClockOffset, const Duration(hours: 1));
    });
  });

  group('Tor', () {
    test('the proxy from the provider is passed to every request', () async {
      final proxy = (host: InternetAddress.loopbackIPv4, port: 9050);
      await client(proxyInfo: () => proxy).status();
      expect(http.proxies.single, proxy);
    });

    test('Tor on but down: nothing is sent, no clearnet fallback', () async {
      final c = client(
        proxyInfo: () => throw Exception('Tor is not connected'),
      );
      await expectLater(c.status(), throwsA(isA<BeamExplorerException>()));
      await expectLater(
        c.contract(_dexCid),
        throwsA(isA<BeamExplorerException>()),
      );
      expect(http.calls, isEmpty);
    });
  });

  group('contract() and asset()', () {
    test('builds the URL under the /api base path', () async {
      http.handler = (_) async => _ok(_fixture('explorer_contract_dex.json'));
      await client().contract(_dexCid, state: true, nMaxTxs: 5);
      expect(
        http.calls.single.toString(),
        'https://explorer.0xmx.net/api/contract'
        '?id=$_dexCid&state=1&nMaxTxs=5',
      );
    });

    test('decodes the real DEX contract answer', () async {
      http.handler = (_) async => _ok(_fixture('explorer_contract_dex.json'));
      final c = await client().contract(_dexCid, state: true, nMaxTxs: 5);
      expect(c['kind'], 'DEX v0');
      expect(c['h'], 4067912);
      final state = c['State']! as Map<String, Object?>;
      final pools = ExplorerTable.parse(state['Pools']);
      expect(pools.rows.any((r) => r.intOf('Aid2') == 174), isTrue);
      expect(ExplorerTable.parse(c['Calls history']).moreHMax, 4067909);
    });

    test('a node answering with a non-object fails over', () async {
      http.handler = (url) async => url.host == 'explorer.0xmx.net'
          ? _ok('[]')
          : _ok(_fixture('explorer_contract_dex.json'));
      final c = await client().contract(_dexCid);
      expect(c['kind'], 'DEX v0');
      expect(http.calls, hasLength(2));
      expect(http.calls.last.queryParameters, {'id': _dexCid});
    });

    test('an invalid contract id is refused before any request', () {
      final c = client();
      expect(() => c.contract('00'), throwsArgumentError);
      expect(() => c.contract('$_dexCid&x=1'), throwsArgumentError);
      expect(http.calls, isEmpty);
    });

    test('asset(174) decodes the real answer', () async {
      http.handler = (_) async => _ok(_fixture('explorer_asset_174.json'));
      final a = await client().asset(174, nMaxOps: 5);
      expect(
        http.calls.single.toString(),
        'https://explorer.0xmx.net/api/asset?id=174&nMaxOps=5',
      );
      final history = ExplorerTable.parse(a['Asset history']);
      expect(history.rows.map((r) => r['Event']), ['Mint', 'Create']);
      expect(() => client().asset(-1), throwsArgumentError);
    });

    test('getJson refuses anything but a bare endpoint name', () {
      final c = client();
      expect(() => c.getJson('../status'), throwsArgumentError);
      expect(() => c.getJson('hdrs?x=1'), throwsArgumentError);
      expect(http.calls, isEmpty);
    });
  });

  test('endpointUri keeps base paths and drops trailing slashes', () {
    expect(
      BeamExplorerClient.endpointUri(
        'https://BeamSmart.net:8000/',
        'status',
      ).toString(),
      'https://beamsmart.net:8000/status',
    );
    expect(
      BeamExplorerClient.endpointUri('https://explorer.0xmx.net/api', 'hdrs', {
        'nMax': '50',
        'cols': 'HTk',
      }).toString(),
      'https://explorer.0xmx.net/api/hdrs?nMax=50&cols=HTk',
    );
  });
}
