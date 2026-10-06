/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

/// A stand-in for wallet-api in TCP line mode: accepts one connection, hands
/// every request line to the test, and lets the test write raw bytes back.
class FakeCore {
  FakeCore._(this._server) {
    _server.listen((s) {
      client = s;
      const LineSplitter()
          .bind(utf8.decoder.bind(s))
          .listen(
            (line) => requests.add(
              (jsonDecode(line) as Map).cast<String, Object?>(),
            ),
            onError: (Object _) {},
          );
      _connected.complete();
    });
  }

  static Future<FakeCore> start() async =>
      FakeCore._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final _connected = Completer<void>();
  final requests = StreamQueue();
  Socket? client;

  int get port => _server.port;
  Future<void> get connected => _connected.future;

  void sendRaw(List<int> bytes) => client!.add(bytes);
  void sendLine(Object json) => sendRaw(utf8.encode('${jsonEncode(json)}\n'));
  void reply(Object? id, Object? result) =>
      sendLine({'jsonrpc': '2.0', 'id': id, 'result': result});

  Future<void> close() async {
    client?.destroy();
    await _server.close();
  }
}

/// Collects request maps in arrival order and lets a test await the next.
class StreamQueue {
  final _items = <Map<String, Object?>>[];
  final _waiters = <Completer<Map<String, Object?>>>[];

  void add(Map<String, Object?> m) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(m);
    } else {
      _items.add(m);
    }
  }

  Future<Map<String, Object?>> next() {
    if (_items.isNotEmpty) return Future.value(_items.removeAt(0));
    final c = Completer<Map<String, Object?>>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 10));
  }
}

void main() {
  late FakeCore core;
  late TcpLineTransport t;
  Object? dropError = 'not called';
  var dropCount = 0;

  setUp(() async {
    core = await FakeCore.start();
    dropError = 'not called';
    dropCount = 0;
    t = TcpLineTransport(
      port: core.port,
      aclKey: 'acl-test-key',
      defaultTimeout: const Duration(seconds: 5),
      onDisconnected: (e) {
        dropError = e;
        dropCount++;
      },
      log: (_) {},
    );
    await t.connect();
    await core.connected;
  });

  tearDown(() async {
    await t.close();
    await core.close();
  });

  test('a request is one JSON line: jsonrpc, int id, params, key', () async {
    final f = t.call('wallet_status', {'nz_totals': true});
    final req = await core.requests.next();
    expect(req['jsonrpc'], '2.0');
    expect(req['id'], isA<int>());
    expect(req['method'], 'wallet_status');
    expect(req['params'], {'nz_totals': true});
    expect(req['key'], 'acl-test-key');
    core.reply(req['id'], {'ok': 1});
    expect(await f, {'ok': 1});
  });

  test('ids are unique and responses are matched by id, not order', () async {
    final a = t.call('a');
    final b = t.call('b');
    final c = t.call('c');
    final ra = await core.requests.next();
    final rb = await core.requests.next();
    final rc = await core.requests.next();
    expect({ra['id'], rb['id'], rc['id']}.length, 3);
    // Answer in reverse order, two of them in one TCP write.
    core.sendRaw(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': rc['id'], 'result': 'C'})}\n'
        '${jsonEncode({'jsonrpc': '2.0', 'id': rb['id'], 'result': 'B'})}\n',
      ),
    );
    core.reply(ra['id'], 'A');
    expect(await Future.wait([a, b, c]), ['A', 'B', 'C']);
  });

  test('a response split mid UTF-8 char over many writes', () async {
    final f = t.call('tx_status');
    final req = await core.requests.next();
    final line = utf8.encode(
      '${jsonEncode({
        'jsonrpc': '2.0',
        'id': req['id'],
        'result': {'comment': 'Grüße — ✓ 🚀'},
      })}\n',
    );
    for (var i = 0; i < line.length; i++) {
      core.sendRaw([line[i]]);
      if (i % 7 == 0) await Future<void>.delayed(Duration.zero);
    }
    expect(await f, {'comment': 'Grüße — ✓ 🚀'});
  });

  test('events interleaved with responses go to the events stream', () async {
    final events = <BeamEvent>[];
    final sub = t.events.listen(events.add);
    final f = t.call('ev_subunsub', {'ev_system_state': true});
    final req = await core.requests.next();
    core.sendLine({
      'jsonrpc': '2.0',
      'id': 'ev_sync_progress',
      'result': {'sync_requests_done': 1, 'sync_requests_total': 4},
    });
    core.reply(req['id'], true);
    core.sendLine({
      'jsonrpc': '2.0',
      'id': 'ev_system_state',
      'result': {'current_height': 42, 'is_in_sync': true},
    });
    expect(await f, true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events.map((e) => e.name), ['ev_sync_progress', 'ev_system_state']);
    expect(events[1].data['current_height'], 42);
    await sub.cancel();
  });

  test('an error object becomes BeamRpcException with code and data', () async {
    final f = t.call('tx_send', {'value': 1});
    final req = await core.requests.next();
    core.sendLine({
      'jsonrpc': '2.0',
      'id': req['id'],
      'error': {
        'code': -32602,
        'message': 'The minimum fee is 100000 GROTH',
        'data': {'hint': 1},
      },
    });
    await expectLater(
      f,
      throwsA(
        isA<BeamRpcException>()
            .having((e) => e.code, 'code', -32602)
            .having((e) => e.message, 'message', contains('minimum fee'))
            .having((e) => e.data, 'data', {'hint': 1}),
      ),
    );
  });

  test('timeout; the late answer is ignored; the next call works', () async {
    final slow = t.call('assets_list', const {}, const Duration(
      milliseconds: 100,
    ));
    final req = await core.requests.next();
    await expectLater(slow, throwsA(isA<TimeoutException>()));
    core.reply(req['id'], 'too late');

    final next = t.call('get_version');
    final req2 = await core.requests.next();
    core.reply(req2['id'], 'v');
    expect(await next, 'v');
    expect(t.isConnected, isTrue);
  });

  test('a malformed UTF-8 byte does not drop the connection', () async {
    final f = t.call('tx_list');
    final req = await core.requests.next();
    core.sendRaw([
      ...utf8.encode('{"jsonrpc":"2.0","id":${req['id']},"result":"a'),
      0xFF,
      ...utf8.encode('b"}\n'),
    ]);
    expect(await f, 'a\uFFFDb');
    expect(t.isConnected, isTrue);
    expect(dropCount, 0);
  });

  test('a line that is not JSON is skipped and the link stays up', () async {
    final f = t.call('wallet_status');
    final req = await core.requests.next();
    core.sendRaw(utf8.encode('POST /api/wallet HTTP/1.1\n[1,2]\n\n'));
    core.reply(req['id'], 'still fine');
    expect(await f, 'still fine');
  });

  test('a dropped connection fails every pending call, once', () async {
    final a = t.call('a');
    final b = t.call('b');
    await core.requests.next();
    await core.requests.next();
    final failA = expectLater(a, throwsA(isA<BeamConnectionException>()));
    final failB = expectLater(b, throwsA(isA<BeamConnectionException>()));
    core.client!.destroy();
    await failA;
    await failB;
    expect(t.isConnected, isFalse);
    expect(dropCount, 1);
    expect(dropError, isNull);
    await expectLater(t.call('c'), throwsA(isA<BeamConnectionException>()));
  });

  test('close() fails pending calls, ends events, no drop callback', () async {
    final done = Completer<void>();
    t.events.listen(null, onDone: done.complete);
    final a = t.call('a');
    await core.requests.next();
    final failA = expectLater(a, throwsA(isA<BeamConnectionException>()));
    await t.close();
    await failA;
    await done.future.timeout(const Duration(seconds: 2));
    expect(dropCount, 0);
    await expectLater(t.connect(), throwsA(isA<BeamConnectionException>()));
  });

  test('connect to a port nobody listens on is a typed error', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    final lone = TcpLineTransport(port: port, log: (_) {});
    await expectLater(lone.connect(), throwsA(isA<BeamConnectionException>()));
    expect(lone.isConnected, isFalse);
    await lone.close();
  });

  test('2 MB request and 2 MB response lines pass intact', () async {
    final shader = List<int>.generate(2 * 1024 * 1024 ~/ 4, (i) => i % 256);
    final f = t.call('invoke_contract', {'contract': shader});
    final req = await core.requests.next();
    final params = (req['params']! as Map).cast<String, Object?>();
    expect((params['contract']! as List).length, shader.length);
    expect((params['contract']! as List).last, shader.last);

    final big = 'x' * (2 * 1024 * 1024);
    core.reply(req['id'], {'output': big});
    final r = (await f)! as Map;
    expect((r['output']! as String).length, big.length);
  });

  test('a 16 MB response line is not capped', () async {
    final f = t.call('invoke_contract', const {}, const Duration(seconds: 30));
    final req = await core.requests.next();
    final big = List<int>.filled(16 * 1024 * 1024 ~/ 4, 255);
    final sw = Stopwatch()..start();
    core.reply(req['id'], {'raw_data': big});
    final r = (await f)! as Map;
    expect((r['raw_data']! as List).length, big.length);
    // ignore: avoid_print
    print('16 MB line round trip: ${sw.elapsedMilliseconds} ms');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('concurrent calls of mixed sizes never interleave', () async {
    final futures = <Future<Object?>>[];
    for (var i = 0; i < 60; i++) {
      futures.add(t.call('m$i', {'pad': 'p' * (i.isEven ? 200000 : 3)}));
    }
    final seen = <String>{};
    for (var i = 0; i < 60; i++) {
      final req = await core.requests.next();
      seen.add(req['method']! as String);
      core.reply(req['id'], req['method']);
    }
    expect(seen.length, 60);
    final results = await Future.wait(futures);
    expect(results, [for (var i = 0; i < 60; i++) 'm$i']);
  });

  test('params that cannot be JSON are rejected before sending', () async {
    await expectLater(
      t.call('tx_send', {'value': BigInt.one}),
      throwsA(isA<ArgumentError>()),
    );
  });
}
