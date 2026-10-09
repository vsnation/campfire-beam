/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// No IP address of the user may be exposed: with Tor on, every request
// goes through Tor. These tests run Ethereum's
// JSON-RPC client (the one every web3dart call and "Test connection" use)
// against a local SOCKS5 proxy standing in for Tor and a local RPC:
// * Tor on: the request goes through the proxy, and the proxy gets the
//   host NAME (it resolves it; this device's DNS never sees it);
// * Tor on but not connected: it throws, and nothing reaches the proxy or
//   the RPC;
// * Tor off: it goes straight to the RPC, and the proxy sees nothing.
// Campfire's HTTP class (Ethereum index, prices, icons) uses the same
// tunnel; its test is at the end.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stackwallet/networking/http.dart';
import 'package:stackwallet/networking/socks5_tunnel.dart';
import 'package:stackwallet/services/event_bus/events/global/tor_connection_status_changed_event.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';

import 'fake_socks.dart';

void main() {
  late FakeEthRpc rpc;
  late FakeSocksProxy tor;

  setUp(() async {
    rpc = await FakeEthRpc.start(chainId: 1, blockNumber: 21000000);
    tor = await FakeSocksProxy.start(target: rpc.address);
  });
  tearDown(() async {
    await tor.close();
    await rpc.close();
  });

  group('the rule (ethRouteFor)', () {
    final rpcUrl = Uri.parse('https://eth.drpc.org');
    SocksProxy proxy() => (host: InternetAddress.loopbackIPv4, port: 9050);

    test('Tor off: direct', () {
      expect(
        ethRouteFor(
          rpcUrl,
          torOn: false,
          torStatus: () => TorConnectionStatus.disconnected,
          proxy: () => fail('the proxy is not asked for'),
        ),
        isNull,
      );
    });

    test('Tor on and connected: the proxy', () {
      expect(
        ethRouteFor(
          rpcUrl,
          torOn: true,
          torStatus: () => TorConnectionStatus.connected,
          proxy: proxy,
        ),
        proxy(),
      );
    });

    test('Tor on, connecting or off: throws, never direct', () {
      for (final status in [
        TorConnectionStatus.connecting,
        TorConnectionStatus.disconnected,
      ]) {
        expect(
          () => ethRouteFor(
            rpcUrl,
            torOn: true,
            torStatus: () => status,
            proxy: proxy,
          ),
          throwsA(isA<EthTorNotConnectedException>()),
          reason: '$status',
        );
      }
      // Connected, but the service cannot give its port.
      expect(
        () => ethRouteFor(
          rpcUrl,
          torOn: true,
          torStatus: () => TorConnectionStatus.connected,
          proxy: () => throw Exception('no port'),
        ),
        throwsA(isA<EthTorNotConnectedException>()),
      );
    });

    test('this device: direct, Tor or not (Tor refuses loopback)', () {
      for (final host in ['127.0.0.1', 'localhost', '[::1]', '127.8.9.10']) {
        expect(
          ethRouteFor(
            Uri.parse('http://$host:8545'),
            torOn: true,
            torStatus: () => TorConnectionStatus.disconnected,
            proxy: proxy,
          ),
          isNull,
          reason: host,
        );
      }
      // A LAN address is not this device: through Tor like any other.
      expect(
        () => ethRouteFor(
          Uri.parse('http://192.168.1.20:8545'),
          torOn: true,
          torStatus: () => TorConnectionStatus.disconnected,
          proxy: proxy,
        ),
        throwsA(isA<EthTorNotConnectedException>()),
      );
    });

    test('a .onion address with Tor off is not sent (no DNS lookup)', () {
      expect(
        () => ethRouteFor(
          Uri.parse('http://abcdefghijklmnop.onion'),
          torOn: false,
          torStatus: () => TorConnectionStatus.disconnected,
          proxy: proxy,
        ),
        throwsA(isA<EthOnionNeedsTorException>()),
      );
    });
  });

  group('web3dart over EthRpcHttpClient', () {
    test('Tor on: through the proxy, which gets the host name', () async {
      final client = ethWeb3Client(
        'http://rpc.example:8545/v1/key',
        route: (_) => tor.info,
      );
      expect(await client.getChainId(), BigInt.one);
      expect(await client.getBlockNumber(), 21000000);
      expect(tor.connects, isNotEmpty);
      for (final c in tor.connects) {
        expect(c.addressType, 0x03, reason: 'a name, not an address');
        expect(c.host, 'rpc.example');
        expect(c.port, 8545);
      }
      expect(rpc.methods, ['eth_chainId', 'eth_blockNumber']);
      expect(rpc.requests.map((r) => r.path).toSet(), {'/v1/key'});
    });

    test(
      'Tor on but not connected: throws; nothing is sent anywhere',
      () async {
        final client = ethWeb3Client(
          'http://127.0.0.2:${rpc.port}',
          route: (_) => throw const EthTorNotConnectedException(),
        );
        await expectLater(
          client.getChainId(),
          throwsA(isA<EthTorNotConnectedException>()),
        );
        expect(tor.connections, 0);
        expect(rpc.requests, isEmpty);
      },
    );

    test('Tor off: straight to the RPC; the proxy sees nothing', () async {
      final client = ethWeb3Client(
        'http://127.0.0.1:${rpc.port}',
        route: (_) => null,
      );
      expect(await client.getChainId(), BigInt.one);
      expect(tor.connections, 0);
      expect(rpc.methods, ['eth_chainId']);
    });

    test('Tor turned on between two calls: the second goes through Tor, '
        'not over the open direct connection', () async {
      SocksProxy? route;
      final http.Client httpClient = EthRpcHttpClient(route: (_) => route);
      final client = ethWeb3Client(
        'http://127.0.0.1:${rpc.port}',
        httpClient: httpClient as EthRpcHttpClient,
      );
      expect(await client.getChainId(), BigInt.one);
      expect(tor.connections, 0);
      route = tor.info;
      expect(await client.getBlockNumber(), 21000000);
      expect(tor.connects.single.host, '127.0.0.1');
      httpClient.close();
    });

    test('createEthHttpClient is this client', () {
      final c = createEthHttpClient();
      expect(c, isA<EthRpcHttpClient>());
      c.close();
    });
  });

  group('the tunnel itself', () {
    test('https: TLS starts inside the tunnel, for the name asked', () async {
      final blackHole = await FakeSocksProxy.start(keepFirstBytes: true);
      addTearDown(blackHole.close);
      await expectLater(
        connectThroughSocks5(
          proxy: blackHole.info,
          host: 'ethereum-rpc.publicnode.com',
          port: 443,
          secure: true,
          timeout: const Duration(seconds: 5),
        ),
        throwsA(anything), // the fake proxy hangs up after the hello
      );
      expect(blackHole.connects.single, (
        addressType: 0x03,
        host: 'ethereum-rpc.publicnode.com',
        port: 443,
      ));
      expect(blackHole.firstBytes.single, [0x16], reason: 'a TLS handshake');
    });

    test(
      'the proxy refusing the host fails the request (no fallback)',
      () async {
        final refusing = await FakeSocksProxy.start();
        addTearDown(refusing.close);
        final client = ethWeb3Client(
          'http://127.0.0.1:${rpc.port}',
          route: (_) => refusing.info,
        );
        await expectLater(client.getChainId(), throwsA(anything));
        expect(refusing.connects, hasLength(1));
        expect(rpc.requests, isEmpty);
      },
    );

    test(
      "Campfire's HTTP class goes through the same tunnel, by name",
      () async {
        final response = await const HTTP().post(
          url: Uri.parse('http://index.example:8080/rpc'),
          headers: {'Content-Type': 'application/json'},
          body: '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}',
          proxyInfo: tor.info,
        );
        expect(response.code, 200);
        expect(response.body, contains('"result":"0x1"'));
        expect(tor.connects.single, (
          addressType: 0x03,
          host: 'index.example',
          port: 8080,
        ));
      },
    );
  });
}
