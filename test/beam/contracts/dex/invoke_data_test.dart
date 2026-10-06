/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';

import 'dex_fixtures.dart';

void main() {
  const g = BigInt.from;

  group('decode (vectors serialized by BEAM yas)', () {
    test('a plain trade', () {
      final d = BeamInvokeData.decode(rawDataVector('trade_plain'));
      expect(d.entries, hasLength(1));
      final e = d.entries.single;
      expect(e.flags, 0);
      expect(e.method, 7);
      expect(e.contractId, dexCid);
      expect(e.args, hasLength(17));
      expect(e.args[0], 174);
      expect(e.comment, 'Amm trade');
      expect(e.charge, 0);
      expect(e.signatureCount, 0);
      expect(e.isDependent, isFalse);
      expect(d.pays, {0: g(10000000)});
      expect(d.receives, {174: g(80368764)});
      expect(d.fee, g(1100000));
      expect(d.appArgs, isNull);
    });

    test('a dependent call with stored app args', () {
      final d = BeamInvokeData.decode(rawDataVector('add_dependent'));
      final e = d.entries.single;
      expect(e.isDependent, isTrue);
      expect(e.parentHeight, g(4068104));
      expect(e.method, 5);
      expect(e.signatureCount, 1);
      expect(d.pays, {0: g(10000000), 174: g(81173706)});
      expect(d.receives, {175: g(33347624)});
      expect(d.appArgs, {
        'action': 'pool_add_liquidity',
        'cid': dexCid,
        'aid1': '0',
        'aid2': '174',
        'kind': '2',
        'val1': '10000000',
        'val2': '0',
        'bPredictOnly': '0',
      });
      // Three assets moving, BEAM among them: still the minimum.
      expect(d.fee, g(1100000));
    });

    test('integer edges, a deployment entry and a spend max', () {
      final d = BeamInvokeData.decode(rawDataVector('edges'));
      final e = d.entries.single;
      expect(e.method, 0);
      expect(e.contractId, isNull);
      expect(e.dataLength, 200);
      expect(e.args, hasLength(128));
      expect(e.charge, 137100);
      expect(e.parentHeight, g(127));
      expect(e.spend, {
        0: g(1000000000),
        127: g(63),
        128: g(-64),
        4294967295: -(BigInt.one << 62),
      });
      expect(d.spendMax, {0: g(1000000001)});
      expect(d.appArgs, isEmpty);
    });

    test('pool_create: the declared charge drives the fee', () {
      final d = BeamInvokeData.decode(rawDataVector('create_pool'));
      expect(d.entries.single.method, 3);
      expect(d.entries.single.charge, 137100);
      expect(d.pays, {0: g(1000000000)});
      expect(d.receives, isEmpty);
      expect(d.fee, g(1471000));
    });

    test('a withdraw', () {
      final d = BeamInvokeData.decode(rawDataVector('withdraw'));
      expect(d.entries.single.method, 6);
      expect(d.pays, {175: g(100000000)});
      expect(d.receives, {0: g(29987143), 174: g(243416758)});
    });
  });

  group('decode refuses what it cannot fully read', () {
    final trade = rawDataVector('trade_plain');

    test('truncated at every length', () {
      for (var n = 0; n < trade.length; n++) {
        expect(
          () => BeamInvokeData.decode(trade.sublist(0, n)),
          throwsFormatException,
          reason: 'length $n',
        );
      }
    });

    test('trailing bytes', () {
      expect(
        () => BeamInvokeData.decode([...trade, 0]),
        throwsFormatException,
      );
    });

    test('advanced, multisigned and unknown flags', () {
      // Replace the leading method byte (0x87) with a flagged header.
      List<int> withFlags(int flags) => [
        0x81,
        0x04,
        flags,
        0x00,
        0x00,
        0x80,
        0x87,
        ...trade.sublist(2),
      ];
      expect(
        BeamInvokeData.decode(withFlags(0x00)).entries.single.method,
        7,
        reason: 'a flagged header with no flags still decodes',
      );
      for (final f in [0x01, 0x08, 0x10, 0x04, 0x80]) {
        expect(
          () => BeamInvokeData.decode(withFlags(f)),
          throwsFormatException,
          reason: 'flags 0x${f.toRadixString(16)}',
        );
      }
    });

    test('a container longer than the data', () {
      expect(() => BeamInvokeData.decode([0x08, 0xff]), throwsFormatException);
      expect(
        () => BeamInvokeData.decode([0x88, 0x87]),
        throwsFormatException,
      );
    });

    test('an empty vector decodes to no entries', () {
      final d = BeamInvokeData.decode([0x80]);
      expect(d.entries, isEmpty);
      expect(d.fee, BigInt.zero);
    });
  });

  group('BeamContractFee', () {
    test('minimum is 0.011 BEAM', () {
      expect(BeamContractFee.minimum, g(1100000));
    });

    test('outputs are counted, plus one when BEAM does not move', () {
      // 5 outputs + 1 kernel = 100,000 exactly: still the minimum.
      expect(
        BeamContractFee.forEntry(
          argsBytes: 17,
          dataBytes: 0,
          spendAssets: const [0, 1, 2, 3, 4],
          charge: 0,
        ),
        g(1100000),
      );
      // 6 outputs: 18000*6 + 10000 = 118,000.
      expect(
        BeamContractFee.forEntry(
          argsBytes: 17,
          dataBytes: 0,
          spendAssets: const [1, 2, 3, 4, 5],
          charge: 0,
        ),
        g(118000 + 1000000),
      );
    });

    test('payload over 32 KB costs 50 groth per byte, before the floor', () {
      // 18000 + 10000 + 50 * 1000 = 78,000: still under the 100,000 floor.
      expect(
        BeamContractFee.forEntry(
          argsBytes: 32768,
          dataBytes: 1000,
          spendAssets: const [0],
          charge: 0,
        ),
        g(1100000),
      );
      // 28,000 + 50 * 2000 = 128,000.
      expect(
        BeamContractFee.forEntry(
          argsBytes: 32768,
          dataBytes: 2000,
          spendAssets: const [0],
          charge: 0,
        ),
        g(128000 + 1000000),
      );
    });

    test('charge above 100,000 units costs 10 groth per unit', () {
      expect(
        BeamContractFee.forEntry(
          argsBytes: 0,
          dataBytes: 0,
          spendAssets: const [0],
          charge: 100001,
        ),
        g(100000 + 1000010),
      );
    });
  });
}
