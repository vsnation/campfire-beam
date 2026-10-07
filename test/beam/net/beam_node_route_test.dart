/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// With Tor on, every BEAM connection goes through Tor or is not made (owner,
// 2026-10-07): node names are resolved inside Tor (SOCKS5 RESOLVE), wallet-api
// gets ip:port plus the proxy, and every failure stops instead of falling
// back to a direct connection.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';

Matcher hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

/// A SOCKS5 server that answers one RESOLVE per connection with [reply]
/// and records what it received.
class _FakeSocks {
  _FakeSocks._(this._server, this.reply);

  static Future<_FakeSocks> start(
    List<int> Function(List<int> request) reply,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeSocks._(server, reply);
    server.listen(fake._serve);
    return fake;
  }

  final ServerSocket _server;
  final List<int> Function(List<int> request) reply;
  final List<List<int>> received = [];
  int connections = 0;

  int get port => _server.port;

  void _serve(Socket s) {
    connections++;
    final buf = <int>[];
    var greeted = false;
    s.listen((data) {
      buf.addAll(data);
      if (!greeted && buf.length >= 3) {
        received.add(buf.sublist(0, 3));
        buf.removeRange(0, 3);
        greeted = true;
        s.add(const [5, 0]);
      }
      if (greeted && buf.length >= 5 && buf.length >= 5 + buf[4] + 2) {
        final req = buf.sublist(0, 5 + buf[4] + 2);
        received.add(req);
        buf.clear();
        final out = reply(req);
        if (out.isEmpty) {
          s.destroy();
        } else {
          s.add(out);
        }
      }
    });
  }

  Future<void> close() => _server.close();
}

class _ViaTorRouter implements BeamNodeRouter {
  @override
  bool get torOn => true;

  @override
  Future<BeamNodeRoute> route(BeamNodeEndpoint node) async => BeamNodeRoute(
    address: BeamNodeEndpoint('192.0.2.7', node.port),
    socksProxy: '127.0.0.1:9150',
  );
}

void main() {
  group('resolveThroughTor', () {
    test('sends the Tor RESOLVE request and returns the IPv4 address',
        () async {
      final socks = await _FakeSocks.start(
        (_) => const [5, 0, 0, 1, 198, 51, 100, 23, 0, 0],
      );
      addTearDown(socks.close);
      final ip = await resolveThroughTor(
        'eu-node01.mainnet.beam.mw',
        proxyHost: InternetAddress.loopbackIPv4,
        proxyPort: socks.port,
      );
      expect(ip, '198.51.100.23');
      expect(socks.received.first, [5, 1, 0], reason: 'no authentication');
      final name = 'eu-node01.mainnet.beam.mw'.codeUnits;
      expect(socks.received[1], [5, 0xF0, 0, 3, name.length, ...name, 0, 0]);
    });

    test('a name Tor cannot resolve is a bad node, not a direct lookup',
        () async {
      final socks = await _FakeSocks.start(
        (_) => const [5, 4, 0, 1, 0, 0, 0, 0, 0, 0],
      );
      addTearDown(socks.close);
      await expectLater(
        resolveThroughTor(
          'nowhere.invalid',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: socks.port,
        ),
        throwsA(hostError(BeamHostError.badNode)),
      );
    });

    test('Tor closing the connection, or not listening, is "Tor not ready"',
        () async {
      final socks = await _FakeSocks.start((_) => const []);
      final port = socks.port;
      await expectLater(
        resolveThroughTor(
          'eu-nodes.mainnet.beam.mw',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: port,
        ),
        throwsA(hostError(BeamHostError.torNotReady)),
      );
      await socks.close();
      await expectLater(
        resolveThroughTor(
          'eu-nodes.mainnet.beam.mw',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: port,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(hostError(BeamHostError.torNotReady)),
      );
    });

    test('an IPv6 answer cannot be used through BEAM\'s SOCKS client',
        () async {
      final socks = await _FakeSocks.start(
        (_) => [5, 0, 0, 4, ...List.filled(16, 1), 0, 0],
      );
      addTearDown(socks.close);
      await expectLater(
        resolveThroughTor(
          'v6only.example',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: socks.port,
        ),
        throwsA(hostError(BeamHostError.badNode)),
      );
    });

    test('IPv4 literals need no lookup; IPv6 literals are refused', () async {
      expect(
        await resolveThroughTor(
          '203.0.113.9',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: 1,
        ),
        '203.0.113.9',
      );
      await expectLater(
        resolveThroughTor(
          '2001:db8::1',
          proxyHost: InternetAddress.loopbackIPv4,
          proxyPort: 1,
        ),
        throwsA(hostError(BeamHostError.badNode)),
      );
    });
  });

  group('routes', () {
    test('the private node on this machine is never proxied', () {
      expect(isLoopbackHost('127.0.0.1'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('::1'), isTrue);
      expect(isLoopbackHost('eu-nodes.mainnet.beam.mw'), isFalse);
      expect(isLoopbackHost('10.0.0.5'), isFalse);
    });

    test('wallet-api gets --proxy only for a route through Tor', () {
      const direct = BeamNodeRoute(
        address: BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100),
      );
      expect(ProcessHost.proxyArgs(direct), isEmpty);
      const viaTor = BeamNodeRoute(
        address: BeamNodeEndpoint('192.0.2.7', 8100),
        socksProxy: '127.0.0.1:9150',
      );
      expect(ProcessHost.proxyArgs(viaTor), [
        '--proxy=1',
        '--proxy_addr=127.0.0.1:9150',
      ]);
      expect('$viaTor', '192.0.2.7:8100 via Tor');
    });

    test('with Tor on, a core that cannot use a proxy is never started',
        () async {
      final tmp = await Directory.systemTemp.createTemp('beam_route_');
      addTearDown(() => tmp.delete(recursive: true));
      final host = ProcessHost(
        rootDir: tmp.path,
        router: _ViaTorRouter(),
        coreSupportsSocks: false,
      );
      await expectLater(
        host.routeFor(const BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100)),
        throwsA(hostError(BeamHostError.torUnsupported)),
      );
      final able = ProcessHost(
        rootDir: tmp.path,
        router: _ViaTorRouter(),
        coreSupportsSocks: true,
      );
      final route = await able.routeFor(
        const BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100),
      );
      expect(route.address.host, '192.0.2.7');
      expect(route.socksProxy, '127.0.0.1:9150');
    });

    test('the direct router changes nothing', () async {
      const node = BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100);
      final r = await const BeamNodeRouter.direct().route(node);
      expect(r.address, node);
      expect(r.viaTor, isFalse);
    });
  });
}
