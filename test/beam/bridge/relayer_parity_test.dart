/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's bridge fee against the relayer's own code.
//
// fixtures/relayer_fee_vectors.json was written by running BeamMW's
// beam-bridge-ethrelay `utils/eth_gas.js` and `utils/eth_fee.js`, unmodified,
// on 401 fee histories and price sets (the first is the live one of
// 2026-10-09): scripts/beam/bridge/relayer_fee/make_vectors.sh. For every one
// Campfire must compute the same gas price and the same minimum fee, to the
// unit, for all five routes; and the fee it locks must be the least the
// relayer accepts (with no margin) or more (with the margin).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_fees.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

void main() {
  final file = File('test/beam/bridge/fixtures/relayer_fee_vectors.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final vectors = (data['vectors'] as List).cast<Map<String, dynamic>>();

  BridgePrices pricesOf(Map<String, dynamic> v) => BridgePrices({
    for (final e in (v['prices'] as Map<String, dynamic>).entries)
      e.key: (e.value as num).toDouble(),
  }, DateTime.utc(2026, 10, 9));

  test('the vectors come from the relayer itself', () {
    expect(data['source'], contains('beam-bridge-ethrelay'));
    expect(vectors.length, greaterThan(400));
  });

  test('the same gas price as the relayer (eth_gas.js)', () {
    for (final v in vectors) {
      final gas = BridgeRelayerGas.fromFeeHistory(
        (v['history'] as Map).cast<String, dynamic>(),
      );
      expect(gas.maxFeePerGas, BigInt.parse(v['maxFeePerGas'] as String));
      expect(gas.tip, BigInt.parse(v['maxPriorityFeePerGas'] as String));
    }
  });

  test('the same minimum fee as the relayer, every route (eth_fee.js)', () {
    var checked = 0;
    for (final v in vectors) {
      final gas = BridgeRelayerGas.fromFeeHistory(
        (v['history'] as Map).cast<String, dynamic>(),
      );
      final prices = pricesOf(v);
      final minimum = (v['minimum'] as Map).cast<String, String>();
      for (final route in kBridgeRoutes) {
        expect(
          b2eRelayerMinimum(route, gas, prices),
          BigInt.parse(minimum[route.id]!),
          reason: '${route.id}, ${v['maxFeePerGas']} wei, ${v['prices']}',
        );
        checked++;
      }
    }
    expect(checked, vectors.length * 5);
  });

  test('with no margin the fee is the least the relayer accepts', () {
    for (final v in vectors) {
      final gas = BridgeRelayerGas.fromFeeHistory(
        (v['history'] as Map).cast<String, dynamic>(),
      );
      final prices = pricesOf(v);
      for (final route in kBridgeRoutes) {
        final minimum = BigInt.parse((v['minimum'] as Map)[route.id] as String);
        final fee = b2eRelayerFeeGroth(route, gas, prices, margin: 1.0)!;
        expect(fee % route.beamGrid, BigInt.zero);
        expect(relayerReads(route, fee) >= minimum, isTrue);
        if (fee > route.beamGrid) {
          expect(
            relayerReads(route, fee - route.beamGrid) < minimum,
            isTrue,
            reason: '${route.id}: $fee groth is more than needed',
          );
        }
      }
    }
  });

  test('the quoted fee covers the margin on top of the minimum', () {
    for (final v in vectors) {
      final gas = BridgeRelayerGas.fromFeeHistory(
        (v['history'] as Map).cast<String, dynamic>(),
      );
      final prices = pricesOf(v);
      for (final route in kBridgeRoutes) {
        final minimum = BigInt.parse((v['minimum'] as Map)[route.id] as String);
        final fee = b2eRelayerFeeGroth(route, gas, prices)!;
        final withMargin =
            minimum *
            BigInt.from((kBridgeFeeMargin * 1000).round()) ~/
            BigInt.from(1000);
        expect(relayerReads(route, fee) >= withMargin, isTrue);
      }
    }
  });

  test('the live case of 2026-10-09, in plain numbers', () {
    final v = vectors.first;
    final gas = BridgeRelayerGas.fromFeeHistory(
      (v['history'] as Map).cast<String, dynamic>(),
    );
    final prices = pricesOf(v);
    final beam = bridgeRouteById('beam');
    final usdt = bridgeRouteById('usdt');
    // 96 000 gas at 1.043282187 gwei, ETH $2,485.63, BEAM $0.00795925.
    expect(b2eRelayerMinimum(beam, gas, prices), BigInt.from(3127788375));
    expect(
      b2eRelayerFeeGroth(beam, gas, prices, margin: 1.0),
      BigInt.from(3127788375),
    );
    // USDT has 6 decimals: the relayer cuts the last two digits of groth.
    expect(b2eRelayerMinimum(usdt, gas, prices), BigInt.from(311435));
    expect(
      b2eRelayerFeeGroth(usdt, gas, prices, margin: 1.0),
      BigInt.from(31143500),
    );
  });
}
