/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The relayer's gas price and fee as Campfire computes them, against the
// relayer's own rules (beam-bridge-ethrelay `mainnet`, utils/eth_gas.js and
// utils/eth_fee.js, read 2026-10-09) and the live numbers of research note
// 06 §D (2026-10-09 16:42 UTC).
//
// §D prints maxFeePerGas rounded to "1.8321 gwei"; its fee column was
// computed from the unrounded value, 1.83206425 gwei (base fee 0.7014 gwei,
// tip 0.42926425 gwei), which reproduces all five of its fees exactly.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_fees.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

String gwei(String g) {
  final parts = g.split('.');
  final frac = (parts.length > 1 ? parts[1] : '').padRight(9, '0');
  final wei =
      BigInt.parse(parts[0]) * BigInt.from(1000000000) + BigInt.parse(frac);
  return '0x${wei.toRadixString(16)}';
}

Map<String, dynamic> history(List<String> bases, List<String?> tips) => {
  'oldestBlock': '0x18f1a2d',
  'baseFeePerGas': [for (final b in bases) gwei(b)],
  'reward': [
    for (final t in tips)
      if (t == null) <String>[] else [gwei(t)],
  ],
};

BigInt g(String v) => BigInt.parse(gwei(v).substring(2), radix: 16);

final sectionD = BridgePrices(const {
  'ethereum': 2487.25,
  'beam': 0.00783632,
  'wrapped-bitcoin': 82567,
  'tether': 0.999262,
  'dai': 0.999917,
}, DateTime.utc(2026, 10, 9, 16, 42));

final sectionDGas = BridgeRelayerGas(
  baseFee: g('0.7014'),
  tip: g('0.42926425'),
  at: DateTime.utc(2026, 10, 9, 16, 42),
);

void main() {
  group('relayer gas from eth_feeHistory', () {
    test('base fee is the last entry (the block being built)', () {
      final gas = BridgeRelayerGas.fromFeeHistory(
        history(['0.75', '0.78', '0.7014'], ['0.4', '0.5']),
      );
      expect(gas.baseFee, g('0.7014'));
    });

    test('the tip is the upper middle of an even count, as the relayer '
        'picks it (sorted[floor(n / 2)])', () {
      final gas = BridgeRelayerGas.fromFeeHistory(
        history(['1'], ['0.4', '0.1', '0.3', '0.2']),
      );
      // Sorted 0.1 0.2 0.3 0.4: index 2. An average (0.25) would quote
      // below the relayer's minimum.
      expect(gas.tip, g('0.3'));
      expect(gas.maxFeePerGas, g('2.3'));
    });

    test('odd count: the middle one; empty rows are skipped', () {
      final gas = BridgeRelayerGas.fromFeeHistory(
        history(['1'], ['0.5', null, '0.1', '0.9', null]),
      );
      expect(gas.tip, g('0.5'));
    });

    test('the tip is clamped to 0.01–3 gwei, and no tips means 0.01', () {
      expect(
        BridgeRelayerGas.fromFeeHistory(
          history(['1'], ['0.001', '0.002', '0.003']),
        ).tip,
        kBridgeMinTip,
      );
      expect(
        BridgeRelayerGas.fromFeeHistory(history(['1'], ['5', '7', '9'])).tip,
        kBridgeMaxTip,
      );
      expect(
        BridgeRelayerGas.fromFeeHistory(history(['1'], [])).tip,
        kBridgeMinTip,
      );
      expect(
        BridgeRelayerGas.fromFeeHistory({
          'baseFeePerGas': ['0x1'],
        }).tip,
        kBridgeMinTip,
      );
    });

    test('"0x" reads as zero; no base fee is refused', () {
      final gas = BridgeRelayerGas.fromFeeHistory({
        'baseFeePerGas': ['0x'],
        'reward': [
          ['0x'],
        ],
      });
      expect(gas.baseFee, BigInt.zero);
      expect(gas.tip, kBridgeMinTip);
      expect(
        () => BridgeRelayerGas.fromFeeHistory({'baseFeePerGas': <String>[]}),
        throwsFormatException,
      );
    });

    test('a real answer (eth_feeHistory 0xa, latest, [50])', () {
      // ethereum-rpc.publicnode.com through Tor, 2026-10-09, blocks from
      // 0x18f1dd5 (26 156 501); blob fields left out.
      final gas = BridgeRelayerGas.fromFeeHistory({
        'oldestBlock': '0x18f1dd5',
        'baseFeePerGas': [
          '0xd296a7d', '0xce68b9b', '0xd540d04', '0xc0f5918', '0xd1cf3ec',
          '0xd0e69ff', '0xeb01e7d', '0x1085fd37', '0x122be423',
          '0x1416d60d', '0x153f25be', //
        ],
        'gasUsedRatio': [0.42, 0.63, 0.12, 0.85, 0.48, 1, 1, 0.9, 0.92, 0.73],
        'reward': [
          ['0x8f0d180'], ['0x36d3d15'], ['0x3f0d30b'], ['0x5f5e100'],
          ['0x52e77ff'], ['0x7ce2981'], ['0x8f0d180'], ['0x5f5e100'],
          ['0xbebc200'], ['0x5dc1f7f'], //
        ],
      });
      // The same rule in Python over the same answer: base 356 459 966,
      // tip 100 000 000, maxFee 812 919 932 wei.
      expect(gas.baseFee, BigInt.from(356459966));
      expect(gas.tip, BigInt.from(100000000));
      expect(gas.maxFeePerGas, BigInt.from(812919932));
    });
  });

  group('b2e relayer fee, research §D, margin 1.0', () {
    test('maxFeePerGas is 1.83206425 gwei', () {
      expect(sectionDGas.maxFeePerGas, BigInt.from(1832064250));
    });

    final expected = {
      'beam': BigInt.from(5582377613), // 55.82377613 BEAM, 96 000 gas
      'eth': BigInt.from(21985),
      'wbtc': BigInt.from(663),
      'usdt': BigInt.from(54722100), // on USDT's 100-groth grid
      'dai': BigInt.from(54686161),
    };
    for (final MapEntry(key: id, value: groth) in expected.entries) {
      test(id, () {
        final fee = b2eRelayerFeeGroth(
          bridgeRouteById(id),
          sectionDGas,
          sectionD,
          margin: 1.0,
        );
        expect(fee, groth);
        expect(fee! % bridgeRouteById(id).beamGrid, BigInt.zero);
      });
    }

    test('BEAM with the spec\'s 120 000 gas would be 25 % more', () {
      // The WBEAM relayer charges 96 000 (research Summary 8).
      expect(bridgeRouteById('beam').relayGas, 96000);
      final fee = b2eRelayerFeeGroth(
        bridgeRouteById('beam'),
        sectionDGas,
        sectionD,
        margin: 1.0,
      )!;
      expect(fee * BigInt.from(120000) ~/ BigInt.from(96000) > fee, isTrue);
    });

    test('the default margin pays more, never less', () {
      for (final r in kBridgeRoutes) {
        final exact = b2eRelayerFeeGroth(
          r,
          sectionDGas,
          sectionD,
          margin: 1.0,
        )!;
        final quoted = b2eRelayerFeeGroth(r, sectionDGas, sectionD)!;
        expect(quoted >= exact, isTrue, reason: r.id);
      }
    });

    test('no price, no fee', () {
      final noEth = BridgePrices(const {'beam': 0.0078}, DateTime(2026));
      expect(
        b2eRelayerFeeGroth(bridgeRouteById('beam'), sectionDGas, noEth),
        isNull,
      );
      final zero = BridgePrices(const {
        'ethereum': 2487.25,
        'beam': 0,
      }, DateTime(2026));
      expect(
        b2eRelayerFeeGroth(bridgeRouteById('beam'), sectionDGas, zero),
        isNull,
      );
    });
  });

  group('e2b relayer fee (0.02 BEAM worth), research §D', () {
    final expected = {
      'beam': BigInt.from(2000000),
      'eth': BigInt.from(70000000000), // 7 groth's worth of wei
      'wbtc': BigInt.one,
      'usdt': BigInt.from(157),
      'dai': BigInt.parse('156740000000000'),
    };
    for (final MapEntry(key: id, value: units) in expected.entries) {
      test(id, () {
        final fee = e2bRelayerFee(bridgeRouteById(id), sectionD);
        expect(fee, units);
        expect(fee! % bridgeRouteById(id).ethGrid, BigInt.zero);
      });
    }
  });
}
