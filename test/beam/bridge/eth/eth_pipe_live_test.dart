/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// EthPipeService against Ethereum mainnet and CoinGecko, read-only and
// through Tor: the freeze checks of all five routes, the relayer's gas,
// the prices, the fees they give, the paid flags verified in research note
// 06, and a reference lock read back from its receipt. Nothing
// is signed or sent (the signer refuses).
//
//   BEAM_LIVE_BRIDGE_ETH=1 \
//   CFB_TOR_SOCKS=127.0.0.1:19050 \
//   CFB_ETH_LIVE_RPC=https://ethereum-rpc.publicnode.com \
//   scripts/beam/host_test.sh --no-analyze \
//     test/beam/bridge/eth/eth_pipe_live_test.dart
//
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_fees.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/ethereum/bridge/bridge_price_feed.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_service.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import 'lock_fixture.dart';

class _NoSigner implements UniSwapSigner {
  @override
  String get address => refOwner;

  @override
  Future<Uint8List> signDigest(Uint8List digest) =>
      throw StateError('read-only test');

  @override
  Future<String> send(UniTxRequest tx) => throw StateError('read-only test');
}

void main() {
  final env = Platform.environment;
  final enabled = env['BEAM_LIVE_BRIDGE_ETH'] == '1';
  final socks = (env['CFB_TOR_SOCKS'] ?? '127.0.0.1:19050').split(':');
  final tor = (host: InternetAddress(socks[0]), port: int.parse(socks[1]));
  final url = env['CFB_ETH_LIVE_RPC'] ?? 'https://ethereum-rpc.publicnode.com';

  // Every request through Tor; nothing falls back to a direct connection.
  EthRpcHttpClient viaTor() => EthRpcHttpClient(route: (_) => tor);

  late EthPipeService svc;
  setUpAll(() {
    svc = EthPipeService(
      rpc: EthRpc(
        url: url,
        clientFactory: viaTor,
        timeout: const Duration(seconds: 60),
      ),
      signer: _NoSigner(),
      priceFeed: BridgePriceFeed(
        clientFactory: viaTor,
        timeout: const Duration(seconds: 60),
      ),
    );
  });

  group(
    'live, read-only, through Tor',
    skip: enabled
        ? false
        : 'set '
              'BEAM_LIVE_BRIDGE_ETH=1 to run',
    () {
      test('freezes: all five routes clear', () async {
        for (final r in kBridgeRoutes) {
          final f = await svc.freezes(r);
          print('freezes ${r.id}: ${[for (final x in f) x.reason]}');
          expect(f, isEmpty, reason: r.id);
        }
      });

      test('relayer gas, prices, and the fees they give', () async {
        final gas = await svc.relayerGas();
        print(
          'relayerGas: baseFee ${gas.baseFee} wei, tip ${gas.tip} wei, '
          'maxFeePerGas ${gas.maxFeePerGas} wei',
        );
        expect(gas.maxFeePerGas > BigInt.zero, isTrue);
        final prices = await svc.prices(BridgePriceFeed.bridgeIds.toList());
        print('prices (USD): ${prices.usd}');
        for (final id in BridgePriceFeed.bridgeIds) {
          expect(prices.of(id), isNotNull, reason: id);
        }
        for (final r in kBridgeRoutes) {
          final exact = b2eRelayerFeeGroth(r, gas, prices, margin: 1.0);
          final quoted = b2eRelayerFeeGroth(r, gas, prices);
          final e2b = e2bRelayerFee(r, prices);
          print(
            'fees ${r.id}: b2e $exact groth (relayer minimum), $quoted '
            'quoted (×$kBridgeFeeMargin); e2b $e2b ${r.ethSymbol} units',
          );
          expect(quoted, isNotNull);
          expect(e2b, isNotNull);
        }
      });

      test('paid flags (research note 06, Summary 13)', () async {
        final known = {
          ('eth', 107): true,
          ('eth', 108): false,
          ('usdt', 108): true,
          ('usdt', 109): false,
          ('beam', 639): true,
          ('beam', 640): false,
        };
        for (final MapEntry(key: (id, msg), value: paid) in known.entries) {
          final got = await svc.isPaid(bridgeRouteById(id), msg);
          print('isPaid $id $msg: $got');
          expect(got, paid, reason: '$id $msg');
        }
      });

      test('the reference lock, read back from mainnet', () async {
        final lock = await svc.lockResult(
          bridgeRouteById('beam'),
          refHash,
          value: refValue,
          fee: refFee,
          receiverKey: refKey,
        );
        print(
          'lockResult $refHash: success ${lock!.success}, '
          'block ${lock.blockNumber}, msgId ${lock.msgId}',
        );
        expect(lock.msgId, 222);
      });
    },
  );
}
