/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// testBeamNodeConnection against local stand-ins on 127.0.0.1: a BEAM node
// (answers 42 6d 0a 04 20 00 00 00, as eu-nodes and us-nodes did on
// 2026-10-06), a web server, a silent server, a closed port, and a SOCKS5
// proxy that must receive the host NAME (Tor resolves it, not this
// device). No internet needed.

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/test_beam_node_connection.dart';

/// A loopback server that hands each connection's bytes to [onBytes].
class _Server {
  _Server._(this._socket);

  final ServerSocket _socket;
  final received = <int>[];
  final _clients = <Socket>[];

  int get port => _socket.port;

  static Future<_Server> start(
    void Function(_Server s, Socket client, List<int> all) onBytes,
  ) async {
    final s = _Server._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    s._socket.listen((client) {
      s._clients.add(client);
      final all = <int>[];
      client.listen(
        (data) {
          all.addAll(data);
          s.received.addAll(data);
          onBytes(s, client, all);
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
    });
    return s;
  }

  Future<void> close() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _socket.close();
  }
}

const _beamReply = [0x42, 0x6d, 0x0a, 0x04, 0x20, 0, 0, 0];

/// Answers like a BEAM node once the 40-byte opening has arrived.
void _beamNode(_Server s, Socket c, List<int> all) {
  if (all.length == 40) c.add([..._beamReply, ...List.filled(32, 7)]);
}

/// True when x is the x coordinate of a point on secp256k1.
bool _onCurve(BigInt x) {
  final p = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );
  final y2 = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
  return y2.modPow((p - BigInt.one) >> 1, p) == BigInt.one;
}

BigInt _x(List<int> opening) {
  var x = BigInt.zero;
  for (final b in opening.sublist(8, 40)) {
    x = (x << 8) | BigInt.from(b);
  }
  return x;
}

void main() {
  test('a BEAM node: found; it got the real opening (header + a point on '
      'the curve)', () async {
    final node = await _Server.start(_beamNode);
    addTearDown(node.close);
    final r = await testBeamNodeConnection(host: '127.0.0.1', port: node.port);
    expect(r, BeamNodeTestResult.beamNode);
    expect(node.received.sublist(0, 8), _beamReply);
    expect(node.received, hasLength(40));
    expect(_onCurve(_x(node.received)), isTrue);
  });

  test('every opening is a fresh valid point', () {
    final random = Random(42);
    final seen = <BigInt>{};
    for (var i = 0; i < 20; i++) {
      final o = beamNodeHandshakeOpening(random);
      expect(o.sublist(0, 8), _beamReply);
      final x = _x(o);
      expect(_onCurve(x), isTrue);
      expect(seen.add(x), isTrue);
    }
  });

  test('a web server: answers, but is not a BEAM node', () async {
    final web = await _Server.start((s, c, all) {
      c.add('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
    });
    addTearDown(web.close);
    expect(
      await testBeamNodeConnection(host: '127.0.0.1', port: web.port),
      BeamNodeTestResult.notBeamNode,
    );
  });

  test('silent, or hanging up: no reply', () async {
    final silent = await _Server.start((s, c, all) {});
    final hangUp = await _Server.start((s, c, all) => c.destroy());
    addTearDown(silent.close);
    addTearDown(hangUp.close);
    for (final s in [silent, hangUp]) {
      expect(
        await testBeamNodeConnection(
          host: '127.0.0.1',
          port: s.port,
          timeout: const Duration(milliseconds: 400),
        ),
        BeamNodeTestResult.noReply,
      );
    }
  });

  test('nothing listening: unreachable', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    expect(
      await testBeamNodeConnection(host: '127.0.0.1', port: port),
      BeamNodeTestResult.unreachable,
    );
  });

  test('not an address: refused before any connection', () async {
    for (final (host, port) in [
      ('https://eu-nodes.mainnet.beam.mw', 8100),
      ('eu nodes', 8100),
      ('', 8100),
      ('eu-nodes.mainnet.beam.mw', 0),
      ('eu-nodes.mainnet.beam.mw', 70000),
    ]) {
      expect(
        await testBeamNodeConnection(host: host, port: port),
        BeamNodeTestResult.invalidAddress,
        reason: '$host:$port',
      );
    }
  });

  group('through Tor (SOCKS5)', () {
    test('the host NAME goes to the proxy, which connects; the handshake '
        'runs through it', () async {
      String? domain;
      int? port;
      var stage = 0;
      final proxy = await _Server.start((s, c, all) {
        if (stage == 0 && all.length >= 3) {
          expect(all.sublist(0, 3), [5, 1, 0]);
          c.add([5, 0]);
          stage = 1;
        }
        if (stage == 1 && all.length > 8) {
          final req = all.sublist(3);
          final len = req[4];
          if (req.length >= 5 + len + 2) {
            expect(req.sublist(0, 4), [5, 1, 0, 3]);
            domain = String.fromCharCodes(req.sublist(5, 5 + len));
            port = (req[5 + len] << 8) | req[6 + len];
            c.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            stage = 2;
            all.removeRange(0, 3 + 5 + len + 2);
          }
        }
        if (stage == 2 && all.length == 40) {
          c.add(_beamReply);
          stage = 3;
        }
      });
      addTearDown(proxy.close);
      final r = await testBeamNodeConnection(
        host: 'eu-nodes.mainnet.beam.mw',
        port: 8100,
        proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
      );
      expect(r, BeamNodeTestResult.beamNode);
      expect(domain, 'eu-nodes.mainnet.beam.mw');
      expect(port, 8100);
    });

    test('a proxy that refuses the connection: unreachable', () async {
      final proxy = await _Server.start((s, c, all) {
        if (all.length == 3) c.add([5, 0]);
        if (all.length > 3) c.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
      });
      addTearDown(proxy.close);
      expect(
        await testBeamNodeConnection(
          host: 'eu-nodes.mainnet.beam.mw',
          port: 8100,
          proxyInfo: (host: InternetAddress.loopbackIPv4, port: proxy.port),
          timeout: const Duration(seconds: 2),
        ),
        BeamNodeTestResult.unreachable,
      );
    });
  });

  test('pasted addresses split into host and port; bad hosts are explained',
      () {
    expect(BeamNodeAddress.split('eu-nodes.mainnet.beam.mw:8100'), (
      host: 'eu-nodes.mainnet.beam.mw',
      port: 8100,
    ));
    expect(BeamNodeAddress.split(' tcp://1.2.3.4:8100/ '), (
      host: '1.2.3.4',
      port: 8100,
    ));
    expect(BeamNodeAddress.split('node.example'), (
      host: 'node.example',
      port: null,
    ));
    expect(BeamNodeAddress.hostProblem('eu-nodes.mainnet.beam.mw'), isNull);
    expect(BeamNodeAddress.hostProblem('10.0.0.5'), isNull);
    expect(
      BeamNodeAddress.hostProblem('node.example:81'),
      'Put the port number in the Port field',
    );
    expect(BeamNodeAddress.hostProblem('-x'), isNotNull);
    expect(BeamNodeAddress.hostProblem('a;b'), isNotNull);
    expect(BeamNodeAddress.hostProblem(''), 'Enter the node address');
    // Every result has a sentence that names the address and blames no one.
    for (final r in BeamNodeTestResult.values) {
      final m = beamNodeTestMessage(r, 'h:1');
      expect(m, isNotEmpty);
      expect(m.toLowerCase(), isNot(contains('you ')));
    }
  });
}
