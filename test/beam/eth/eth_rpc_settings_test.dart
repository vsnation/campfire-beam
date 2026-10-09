/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Ethereum RPC settings: the URL rules of the node form, "Test connection"
// (chain id 1 or a plain refusal, at most 20 s, through Tor when it is on)
// against local servers, and the built-in RPC list in Settings › Nodes.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/models/node_model.dart';
import 'package:stackwallet/services/node_service.dart';
import 'package:stackwallet/utilities/eth_rpc_url.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/utilities/test_eth_node_connection.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';

import '../../hive/hive_ce_test_utils.dart';
import 'fake_socks.dart';

void main() {
  group('RPC URL rules', () {
    test('https URLs, any path or port, are fine', () {
      for (final url in [
        'https://eth2.stackwallet.com',
        'https://ethereum-rpc.publicnode.com',
        'https://eth-mainnet.g.alchemy.com/v2/abc123',
        'https://rpc.example:8443/path?key=1',
        '  https://eth.drpc.org  ',
      ]) {
        expect(EthRpcUrl.problem(url), isNull, reason: url);
      }
    });

    test('http only for this device, the local network and .onion', () {
      for (final url in [
        'http://localhost:8545',
        'http://127.0.0.1:8545',
        'http://[::1]:8545',
        'http://192.168.1.20:8545',
        'http://10.0.0.5:8545',
        'http://172.20.1.1:8545',
        'http://[fd00::5]:8545',
        'http://abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion',
      ]) {
        expect(EthRpcUrl.problem(url), isNull, reason: url);
      }
      for (final url in [
        'http://eth.drpc.org',
        'http://8.8.8.8:8545',
        'http://172.32.0.1:8545',
      ]) {
        expect(EthRpcUrl.problem(url), contains('https://'), reason: url);
      }
    });

    test('not a URL: says what to type', () {
      expect(EthRpcUrl.problem(''), 'Enter the RPC URL');
      for (final bad in ['eth.drpc.org', 'ws://eth.drpc.org', 'https://']) {
        expect(
          EthRpcUrl.problem(bad),
          'Use a URL like https://ethereum-rpc.publicnode.com',
          reason: bad,
        );
      }
    });

    test('the port a node record keeps follows the URL', () {
      expect(EthRpcUrl.portOf('https://eth.drpc.org'), 443);
      expect(EthRpcUrl.portOf('http://127.0.0.1'), 80);
      expect(EthRpcUrl.portOf('http://127.0.0.1:8545/x'), 8545);
      expect(EthRpcUrl.usesTls('https://eth.drpc.org'), isTrue);
      expect(EthRpcUrl.usesTls('http://127.0.0.1:8545'), isFalse);
    });
  });

  group('Test connection', () {
    test('Ethereum mainnet: chain id 1, then the block number', () async {
      final rpc = await FakeEthRpc.start(chainId: 1, blockNumber: 21234567);
      addTearDown(rpc.close);
      final r = await testEthNodeConnection(
        'http://127.0.0.1:${rpc.port}',
        route: (_) => null,
      );
      expect(r.status, EthNodeTestStatus.mainnet);
      expect(r.blockNumber, 21234567);
      expect(rpc.methods, ['eth_chainId', 'eth_blockNumber']);
      expect(
        ethNodeTestMessage(r, ''),
        'Connected to Ethereum mainnet (block 21,234,567).',
      );
    });

    test('another chain: refused in plain words', () async {
      final rpc = await FakeEthRpc.start(chainId: 56);
      addTearDown(rpc.close);
      final r = await testEthNodeConnection(
        'http://127.0.0.1:${rpc.port}',
        route: (_) => null,
      );
      expect(r.status, EthNodeTestStatus.wrongChain);
      expect(r.chainId, BigInt.from(56));
      expect(rpc.methods, ['eth_chainId'], reason: 'stops at the chain id');
      expect(
        ethNodeTestMessage(r, ''),
        'This RPC is not Ethereum mainnet (chain id 56). Pick another.',
      );
    });

    test('through Tor when Tor is on', () async {
      final rpc = await FakeEthRpc.start();
      final tor = await FakeSocksProxy.start(target: rpc.address);
      addTearDown(rpc.close);
      addTearDown(tor.close);
      // A LAN address (http:// is allowed there), reached through Tor.
      final r = await testEthNodeConnection(
        'http://192.168.1.20:8545',
        route: (_) => tor.info,
      );
      expect(r.ok, isTrue);
      expect(tor.connects.first.host, '192.168.1.20');
      expect(rpc.methods, ['eth_chainId', 'eth_blockNumber']);
    });

    test('Tor on but not connected: nothing sent, and it says so', () async {
      final rpc = await FakeEthRpc.start();
      addTearDown(rpc.close);
      final r = await testEthNodeConnection(
        'https://eth.drpc.org',
        route: (_) => throw const EthTorNotConnectedException(),
      );
      expect(r.status, EthNodeTestStatus.torNotConnected);
      expect(rpc.requests, isEmpty);
      expect(ethNodeTestMessage(r, ''), contains("Tor isn't connected yet"));
    });

    test('no answer: gives up at the time limit', () async {
      final rpc = await FakeEthRpc.start(silent: true);
      addTearDown(rpc.close);
      final watch = Stopwatch()..start();
      final r = await testEthNodeConnection(
        'http://127.0.0.1:${rpc.port}',
        route: (_) => null,
        timeout: const Duration(seconds: 1),
      );
      expect(r.status, EthNodeTestStatus.noAnswer);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ethNodeTestMessage(r, ''), startsWith('No answer from this RPC'));
    });

    test('an unusable URL is not tried', () async {
      final r = await testEthNodeConnection(
        'http://eth.drpc.org',
        route: (_) => fail('nothing is sent'),
      );
      expect(r.status, EthNodeTestStatus.invalidUrl);
      expect(ethNodeTestMessage(r, 'http://eth.drpc.org'), contains('https'));
    });
  });

  group('built-in RPCs', () {
    final eth = Ethereum(CryptoCurrencyNetwork.main);
    var registered = false;

    setUp(() async {
      await setUpHiveCeTest();
      if (!registered) {
        registered = true;
        DB.instance.hive.registerAdapter(NodeModelAdapter());
      }
      await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
    });
    tearDown(tearDownHiveCeTest);

    test('Stack Wallet first (the default), then the public RPCs; all '
        'built in, all through Tor when it is on', () async {
      final service = NodeService(secureStorageInterface: FakeSecureStorage());
      await service.updateDefaults();
      final nodes = service.getNodesFor(eth);
      expect(
        [for (final n in nodes) (n.name, n.host)],
        [
          ('Stack Wallet', 'https://eth2.stackwallet.com'),
          ('PublicNode', 'https://ethereum-rpc.publicnode.com'),
          ('dRPC', 'https://eth.drpc.org'),
          ('MEV Blocker', 'https://rpc.mevblocker.io'),
          ('Blast', 'https://eth-mainnet.public.blastapi.io'),
        ],
      );
      for (final n in nodes) {
        expect(n.isDefault, isTrue, reason: '${n.name} cannot be deleted');
        expect(n.torEnabled && n.clearnetEnabled, isTrue, reason: n.name);
        expect(EthRpcUrl.problem(n.host), isNull, reason: n.name);
      }
      expect(service.getPrimaryNodeFor(currency: eth)?.name, 'Stack Wallet');

      // A second start adds nothing twice and keeps the user's own RPC last.
      await service.save(
        NodeModel(
          host: 'https://my-rpc.example/v1',
          port: 443,
          name: 'Mine',
          id: 'mine',
          useSSL: true,
          enabled: true,
          coinName: eth.identifier,
          isFailover: true,
          isDown: false,
          torEnabled: true,
          clearnetEnabled: true,
          isPrimary: false,
        ),
        null,
        false,
      );
      await service.updateDefaults();
      expect(service.getNodesFor(eth).map((n) => n.name), [
        'Stack Wallet',
        'PublicNode',
        'dRPC',
        'MEV Blocker',
        'Blast',
        'Mine',
      ]);
    });

    test('Ethereum no longer warns that Tor is unsupported', () {
      expect(eth.torSupport, isTrue);
    });
  });
}
