/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/models/beam_call_results.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/models/beam_utxo.dart';
import 'package:stackwallet/wallets/beam/models/beam_version.dart';
import 'package:stackwallet/wallets/beam/models/beam_wallet_status.dart';

import 'fixtures.dart';

final _maxSafeJsonInt = BigInt.parse('9007199254740991');
final _hex = RegExp(r'^[0-9a-f]+$');

void main() {
  group('BeamWalletStatus', () {
    final json = fixtureMap('wallet_status');
    final s = BeamWalletStatus.fromJson(json);

    test('parses the system state', () {
      expect(s.currentHeight, json['current_height']);
      expect(s.currentStateHash, hasLength(64));
      expect(s.isInSync, isA<bool>());
      expect(s.currentStateTime.isUtc, isTrue);
      expect(
        s.currentStateTime.millisecondsSinceEpoch,
        (json['current_state_timestamp']! as int) * 1000,
      );
    });

    test('every total comes from its lossless _str field', () {
      final raw = [for (final t in json['totals']! as List) t as Map];
      expect(s.totals, hasLength(raw.length));
      for (var i = 0; i < raw.length; i++) {
        final t = s.totals[i];
        expect(t.assetId, raw[i]['asset_id']);
        expect(t.available, BigInt.parse(raw[i]['available_str'] as String));
        expect(t.receiving, BigInt.parse(raw[i]['receiving_str'] as String));
        expect(t.locked, BigInt.parse(raw[i]['locked_str'] as String));
        expect(t.change, BigInt.parse(raw[i]['change_str'] as String));
      }
    });

    test('regular + shielded add up; BEAM totals match the top level', () {
      for (final t in s.totals) {
        expect(t.available, t.availableRegular + t.availableMp);
        expect(t.receiving, t.receivingRegular + t.receivingMp);
        expect(t.sending, t.sendingRegular + t.sendingMp);
        expect(t.maturing, t.maturingRegular + t.maturingMp);
      }
      expect(s.totalsFor(0)!.available, s.available);
      expect(s.totalsFor(123456), isNull);
    });

    test('amounts beyond 2^53 and 2^64 stay exact', () {
      const huge = '123456789012345678901234567';
      final st = BeamWalletStatus.fromJson({
        'current_height': 1,
        'current_state_hash': 'aa',
        'current_state_timestamp': 1,
        'prev_state_hash': 'bb',
        'is_in_sync': false,
        'totals': [
          {
            'asset_id': 186,
            // No plain number: wallet-api omits it above 2^53-1.
            'available_str': huge,
            'available_regular_str': huge,
            'available_mp_str': '0',
            // A rounded plain number next to a _str: the _str wins.
            'receiving': 9007199254740992,
            'receiving_str': '9007199254740993',
            for (final k in [
              'receiving_regular',
              'receiving_mp',
              'sending',
              'sending_regular',
              'sending_mp',
              'maturing',
              'maturing_regular',
              'maturing_mp',
              'change',
              'locked',
            ])
              '${k}_str': '0',
          },
        ],
      });
      final t = st.totals.single;
      expect(t.available, BigInt.parse(huge));
      expect(t.available > _maxSafeJsonInt, isTrue);
      expect(t.receiving.toString(), '9007199254740993');
      // App-scoped status has no balances: null, not zero.
      expect(st.available, isNull);
    });

    test('a missing _str in totals is a format error, not a zero', () {
      expect(
        () => BeamAssetTotals.fromJson(const {'asset_id': 0}),
        throwsFormatException,
      );
    });
  });

  group('BeamTransaction', () {
    final raw = fixtureList('tx_list');
    final txs = raw.map(BeamTransaction.fromJson).toList();

    test('every fixture tx parses with a known status and type', () {
      expect(txs, hasLength(raw.length));
      for (final tx in txs) {
        expect(tx.txId, matches(_hex));
        expect(tx.txId, hasLength(32));
        expect(tx.status, isNot(BeamTxStatus.unknown));
        expect(tx.txType, isNot(BeamTxType.unknown));
        expect(tx.createdAt.isUtc, isTrue);
      }
      final statuses = txs.map((t) => t.status).toSet();
      final types = txs.map((t) => t.txType).toSet();
      final rawStatuses = raw.map((t) => t['status']).toSet();
      final rawTypes = raw.map((t) => t['tx_type']).toSet();
      expect(statuses.map((s) => s.code).toSet(), rawStatuses);
      expect(types.map((t) => t.code).toSet(), rawTypes);
      expect(
        statuses,
        containsAll([BeamTxStatus.completed, BeamTxStatus.failed]),
      );
      expect(types, containsAll([BeamTxType.simple, BeamTxType.contract]));
    });

    test('contract txs carry invoke data, not asset/value', () {
      final contracts = txs.where((t) => t.isContract).toList();
      expect(contracts, isNotEmpty);
      for (final tx in contracts) {
        expect(tx.assetId, isNull);
        expect(tx.value, isNull);
        expect(tx.fee, isNotNull);
        expect(tx.feeOnly, isNotNull);
        expect(tx.invokeData, isNotEmpty);
        for (final inv in tx.invokeData) {
          expect(inv.contractId, matches(_hex));
          expect(inv.contractId, hasLength(64));
        }
        final amounts = [
          for (final inv in tx.invokeData) ...inv.amounts.map((a) => a.amount),
        ];
        expect(tx.feeOnly, amounts.isEmpty);
        // The core: income unless something left the wallet.
        if (amounts.isNotEmpty) {
          expect(tx.income, amounts.every((a) => a <= BigInt.zero));
        }
      }
      expect(
        contracts.expand((t) => t.invokeData).expand((i) => i.amounts).any(
          (a) => a.amount.isNegative,
        ),
        isTrue,
      );
    });

    test('simple txs carry asset, value, peers', () {
      final simple = txs.where((t) => t.txType == BeamTxType.simple).toList();
      expect(simple, isNotEmpty);
      for (final tx in simple) {
        expect(tx.assetId, isNotNull);
        expect(tx.value! > BigInt.zero, isTrue);
        expect(tx.sender, isNotEmpty);
        expect(tx.receiver, isNotEmpty);
        expect(tx.income, isNotNull);
      }
    });

    test('failed txs have a reason and no kernel; completed have a kernel', () {
      for (final tx in txs) {
        if (tx.status == BeamTxStatus.failed) {
          expect(tx.failureReason, isNotNull);
          expect(tx.kernel, isNull);
        }
        if (tx.status == BeamTxStatus.completed) {
          expect(tx.kernel, hasLength(64));
          expect(tx.height, isNotNull);
          expect(tx.confirmations, greaterThanOrEqualTo(0));
        }
      }
    });

    test('status and type codes map like wallet/core/common.h', () {
      expect(
        [for (var c = 0; c <= 6; c++) BeamTxStatus.fromCode(c)],
        [
          BeamTxStatus.pending,
          BeamTxStatus.inProgress,
          BeamTxStatus.canceled,
          BeamTxStatus.completed,
          BeamTxStatus.failed,
          BeamTxStatus.registering,
          BeamTxStatus.confirming,
        ],
      );
      expect(BeamTxStatus.fromCode(99), BeamTxStatus.unknown);
      expect(BeamTxStatus.fromCode(-1), BeamTxStatus.unknown);
      expect(BeamTxType.fromCode(7), BeamTxType.pushTransaction);
      expect(BeamTxType.fromCode(12), BeamTxType.contract);
      expect(BeamTxType.fromCode(14), BeamTxType.instantSbbsMessage);
      expect(BeamTxType.fromCode(15), BeamTxType.unknown);
    });

    test('push tx address type and a uint64 value without _str', () {
      final tx = BeamTransaction.fromJson({
        'txId': 'ab' * 16,
        'status': 1,
        'status_string': 'in progress',
        'tx_type': 7,
        'tx_type_string': 'lelantus mw push',
        'sender': '',
        'receiver': '',
        'comment': '',
        'create_time': 1,
        'address_type': 'max_privacy',
        'asset_id': 0,
        'value': 9007199254740993,
        'fee': 1100000,
        'income': false,
      });
      expect(tx.addressType, BeamAddressType.maxPrivacy);
      expect(tx.value.toString(), '9007199254740993');
      expect(tx.status, BeamTxStatus.inProgress);
    });
  });

  group('BeamAddress', () {
    final raw = fixtureList('addr_list');
    final addrs = raw.map(BeamAddress.fromJson).toList();

    test('all five address types parse; none is unknown', () {
      expect(addrs, hasLength(raw.length));
      expect(
        addrs.map((a) => a.type).toSet(),
        {
          BeamAddressType.regular,
          BeamAddressType.regularNew,
          BeamAddressType.offline,
          BeamAddressType.maxPrivacy,
          BeamAddressType.publicOffline,
        },
      );
    });

    test('fields match the fixture', () {
      for (var i = 0; i < raw.length; i++) {
        final a = addrs[i];
        expect(a.address, raw[i]['address']);
        expect(a.own, raw[i]['own']);
        expect(a.expired, raw[i]['expired']);
        expect(a.walletId, matches(_hex));
        expect(a.identity, matches(_hex));
        expect(a.ownId, BigInt.parse(raw[i]['own_id_str']! as String));
        expect(a.expiresAt == null, a.duration == 0);
        if (a.type == BeamAddressType.regular) {
          expect(a.address, matches(_hex));
        } else {
          expect(a.address, matches(RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$')));
        }
      }
      expect(addrs.any((a) => !a.expired), isTrue);
    });

    test('validate_address result', () {
      final v = BeamAddressValidation.fromJson(fixtureMap('validate_address'));
      expect(v.isValid, isTrue);
      expect(v.isMine, isFalse);
      expect(v.type, BeamAddressType.regular);
      expect(v.payments, isNull);
    });

    test('wire names round-trip', () {
      for (final t in BeamAddressType.values) {
        expect(BeamAddressType.fromWire(t.wireName), t);
      }
      expect(BeamAddressType.fromWire('swap'), BeamAddressType.unknown);
    });
  });

  group('BeamAssetInfo', () {
    final raw = fixtureMap('assets_list')['assets']! as List;
    final assets = [
      for (final a in raw) BeamAssetInfo.fromJson((a as Map).cast()),
    ];

    test('emission is exact, including where the plain number is absent', () {
      var bigOnes = 0;
      for (var i = 0; i < raw.length; i++) {
        final r = raw[i] as Map;
        expect(assets[i].emission, BigInt.parse(r['emission_str'] as String));
        if (!r.containsKey('emission')) {
          bigOnes++;
          expect(assets[i].emission > _maxSafeJsonInt, isTrue);
        }
      }
      expect(bigOnes, greaterThan(0));
    });

    test('our metadata parser agrees with the core for every asset', () {
      var compared = 0;
      for (var i = 0; i < raw.length; i++) {
        final pairs = (raw[i] as Map)['metadata_pairs'];
        if (pairs == null) continue;
        expect(
          assets[i].metadata.values,
          (pairs as Map).cast<String, String>(),
          reason: 'asset ${assets[i].assetId}',
        );
        compared++;
      }
      expect(compared, raw.length);
    });

    test('decimals come only from NTH_RATIO powers of ten', () {
      int? d(String? ratio) => BeamAssetMetadata.parse(
        'STD:SCH_VER=1;N=T;SN=T;UN=T;NTHUN=t'
        '${ratio == null ? '' : ';NTH_RATIO=$ratio'}',
      ).decimals;
      expect(d('100000000'), 8);
      expect(d('1'), 0);
      expect(d('10'), 1);
      expect(d('1000000000000'), 12);
      expect(d('21000000'), isNull);
      expect(d('0'), isNull);
      expect(d('abc'), isNull);
      expect(d(null), isNull);
      expect(BeamAssetInfo.decimalsFor(0, null), 8);
      expect(BeamAssetInfo.decimalsFor(7, null), isNull);

      final ratios = {
        for (final a in assets) a.metadata.values['NTH_RATIO']: a.decimals,
      };
      expect(ratios['100000000'], 8);
      expect(ratios[null], isNull);
      expect(ratios['21000000'], isNull);
    });

    test('get_asset_info 174 (FOMO)', () {
      final a = BeamAssetInfo.fromJson(fixtureMap('get_asset_info_174'));
      expect(a.assetId, 174);
      expect(a.metadata.isStdPrefixed, isTrue);
      expect(a.metadata.name, 'FOMO');
      expect(a.metadata.unitName, 'FOMO');
      expect(a.metadata.schemaVersion, 1);
      expect(a.decimals, 8);
      expect(a.metadata.siteUrl, startsWith('https://'));
      expect(a.coreSaysStd, isTrue);
      expect(a.isOwned, isFalse);
      expect(a.ownerId, hasLength(64));
    });

    test('non-STD metadata has no fields; values may contain =', () {
      final plain = BeamAssetMetadata.parse('just a label');
      expect(plain.isStdPrefixed, isFalse);
      expect(plain.values, isEmpty);
      expect(plain.decimals, isNull);
      final url = BeamAssetMetadata.parse(
        'STD:N=X;OPT_SITE_URL=https://a/?q=1',
      );
      expect(url.siteUrl, 'https://a/?q=1');
    });
  });

  group('BeamUtxo', () {
    final raw = fixtureList('get_utxo');
    final coins = raw.map(BeamUtxo.fromJson).toList();

    test('status comes from status_string', () {
      for (var i = 0; i < raw.length; i++) {
        expect(coins[i].status.wireName, raw[i]['status_string']);
        expect(coins[i].amount, BigInt.from(raw[i]['amount']! as int));
        expect(coins[i].createTxId, hasLength(32));
        expect(coins[i].spentTxId, isNull);
        expect(coins[i].isShielded, isFalse);
      }
      expect(
        coins.map((c) => c.status).toSet(),
        containsAll([BeamUtxoStatus.available, BeamUtxoStatus.spent]),
      );
    });

    test('MaxHeight maturity reads as unknown', () {
      final c = BeamUtxo.fromJson(const {
        'id': 12,
        'asset_id': 0,
        'amount': 5,
        'type': 'shld',
        'maturity': 18446744073709551615.0,
        'createTxId': '',
        'spentTxId': '',
        'status': 1,
        'status_string': 'incoming',
      });
      expect(c.maturity, isNull);
      expect(c.id, '12');
      expect(c.isShielded, isTrue);
      expect(c.status, BeamUtxoStatus.incoming);
    });
  });

  test('BeamVersion', () {
    final v = BeamVersion.fromJson(fixtureMap('get_version'));
    expect(v.apiVersion, '7.4');
    expect(v.apiVersionMajor, 7);
    expect(v.apiVersionMinor, 4);
    expect(v.isMainnet, isTrue);
    expect(v.beamVersionRevision, isA<int>());
  });

  test('BeamCalcChange', () {
    final c = BeamCalcChange.fromJson(fixtureMap('calc_change'));
    expect(c.explicitFee, BigInt.from(100000));
    expect(c.change, c.assetChange);
  });

  test('BeamInvokeResult and BeamPaymentProofInfo', () {
    final r = BeamInvokeResult.fromJson(const {
      'output': '{"res":[]}',
      'raw_data': [1, 2, 255],
    });
    expect(r.rawData, [1, 2, 255]);
    expect(r.txId, isNull);
    expect(
      () => BeamInvokeResult.fromJson(const {
        'raw_data': [256],
      }),
      throwsFormatException,
    );
    final p = BeamPaymentProofInfo.fromJson(const {
      'is_valid': true,
      'sender': 's',
      'receiver': 'r',
      'amount': 100000000,
      'kernel': 'k',
      'asset_id': 174,
    });
    expect(p.amount, BigInt.from(100000000));
    expect(p.assetId, 174);
  });

  test('wrong shapes are FormatExceptions naming the field', () {
    expect(
      () => BeamVersion.fromJson(const {'api_version': 7}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('api_version'),
        ),
      ),
    );
  });
}
