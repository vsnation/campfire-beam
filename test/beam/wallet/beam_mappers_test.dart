/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pure mappings: wallet_status -> Balance (+ per-asset cache), tx_list ->
// TransactionV2 for every status and kind, and the send rules' plain
// messages.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/transaction.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/models/beam_wallet_status.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_send_rules.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_tx_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';

import '../core/fixtures.dart';
import 'beam_wallet_test_support.dart';

const _me =
    '1111111111111111111111111111111111111111111111111111111111111111aa';
const _peer =
    '2222222222222222222222222222222222222222222222222222222222222222bb';

BigInt _g(num beam) => BigInt.from((beam * 100000000).round());

TransactionV2 _map(Map<String, Object?> json) => BeamTxMapper.map(
  BeamTransaction.fromJson(json),
  walletId: 'w1',
  ownAddresses: {_me},
);

Map<String, Object?> _od(TransactionV2 t) =>
    (jsonDecode(t.otherData!) as Map).cast<String, Object?>();

String _label(TransactionV2 t) => t.statusLabel(
  currentChainHeight: 4100000,
  minConfirms: 1,
  minCoinbaseConfirms: 240,
);

Amount _sent(TransactionV2 t) =>
    t.getAmountSentFromThisWallet(fractionDigits: 8, subtractFee: true);
Amount _received(TransactionV2 t) =>
    t.getAmountReceivedInThisWallet(fractionDigits: 8);
Amount _fee(TransactionV2 t) => t.getFee(fractionDigits: 8);

void main() {
  group('balance mapping', () {
    test('recorded wallet_status: everything available', () {
      final s = BeamWalletStatus.fromJson(fixtureMap('wallet_status'));
      final b = BeamBalanceMapper.balance(s);
      expect(b.spendable.raw, BigInt.parse('66707641121'));
      expect(b.pendingSpendable.raw, BigInt.zero);
      expect(b.blockedTotal.raw, BigInt.zero);
      expect(b.total.raw, BigInt.parse('66707641121'));
      expect(b.total.fractionDigits, 8);

      final assets = BeamBalanceMapper.assetTotalsJson(s);
      expect(assets.keys, containsAll(['0', '6', '7']));
      expect(assets['6']!['available'], '6914515');
      final parsed = BeamBalanceMapper.parseAssetTotals(
        jsonDecode(jsonEncode(assets)),
      );
      expect(parsed[6]!.available, BigInt.from(6914515));
      expect(parsed[0]!.available, BigInt.parse('66707641121'));
    });

    test('change is inside receiving and locked is derived: no double '
        'count', () {
      // After sending 0.004 from 0.01: 0.005 change incoming, 0.001 fee.
      final s = BeamWalletStatus.fromJson(
        statusJson(
          height: 4100000,
          available: _g(0.002),
          receiving: _g(0.005),
          change: _g(0.005),
          sending: _g(0.01),
          maturing: _g(0.001),
        ),
      );
      final b = BeamBalanceMapper.balance(s);
      expect(b.spendable.raw, _g(0.002));
      // receiving (0.005, change included) + maturing (0.001)
      expect(b.pendingSpendable.raw, _g(0.006));
      expect(b.blockedTotal.raw, BigInt.zero);
      expect(b.total.raw, _g(0.008));
      // The core's own "locked" (= maturing + change) is not added anywhere.
      expect(s.totalsFor(0)!.locked, _g(0.006));
    });

    test('no totals (assets off): falls back to the top-level fields', () {
      final json = statusJson(height: 1, available: _g(1), receiving: _g(2))
        ..remove('totals');
      final b = BeamBalanceMapper.balance(BeamWalletStatus.fromJson(json));
      expect(b.spendable.raw, _g(1));
      expect(b.pendingSpendable.raw, _g(2));
    });

    test('unreadable cache entries are skipped', () {
      final parsed = BeamBalanceMapper.parseAssetTotals({
        '0': {'available': 'x'},
        'nope': <String, String>{},
        '7': BeamCachedAssetTotals(
          assetId: 7,
          available: BigInt.one,
          receiving: BigInt.zero,
          sending: BigInt.zero,
          maturing: BigInt.zero,
          change: BigInt.zero,
        ).toJson(),
      });
      expect(parsed.keys, [7]);
    });
  });

  group('transaction mapping', () {
    final statuses = {
      0: ('pending', 'Sending (pending)', 'Receiving (pending)'),
      1: (
        'inProgress',
        'Sending (waiting for receiver)',
        'Receiving (waiting for sender)',
      ),
      2: ('canceled', 'Cancelled', 'Cancelled'),
      3: ('completed', 'Sent', 'Received'),
      4: ('failed', 'Failed', 'Failed'),
      5: (
        'registering',
        'Sending (adding to a block)',
        'Receiving (adding to a block)',
      ),
      6: ('confirming', 'Sending (0/1)', 'Receiving (0/1)'),
    };

    for (final e in statuses.entries) {
      test('status ${e.key} (${e.value.$1}), both directions', () {
        final completed = e.key == 3;
        final out = _map(
          txJson(
            txId: 'aa' * 16,
            status: e.key,
            value: 500000,
            fee: 100000,
            sender: _me,
            receiver: _peer,
            height: completed ? 4099990 : null,
            kernel: 'cd' * 32,
            failureReason: e.key == 4 ? 'No peer response' : null,
          ),
        );
        expect(_od(out)[TxV2OdKeys.beamTxStatus], e.value.$1);
        expect(out.isBeamTransaction, isTrue);
        expect(out.beamTxStatus, e.value.$1);
        expect(out.type, TransactionType.outgoing);
        expect(out.height, completed ? 4099990 : null);
        expect(out.isCancelled, e.key == 2);
        expect(_label(out), e.value.$2);
        expect(_sent(out).raw, BigInt.from(500000));
        expect(_received(out).raw, BigInt.zero);
        expect(_fee(out).raw, BigInt.from(100000));
        if (e.key == 4) {
          expect(_od(out)[TxV2OdKeys.beamFailureReason], 'No peer response');
        }

        final inc = _map(
          txJson(
            txId: 'bb' * 16,
            status: e.key,
            income: true,
            value: 1000000,
            fee: 100000,
            sender: _peer,
            receiver: _me,
            height: completed ? 4099991 : null,
          ),
        );
        expect(inc.type, TransactionType.incoming);
        expect(_label(inc), e.value.$3);
        expect(_received(inc).raw, BigInt.from(1000000));
        expect(_sent(inc).raw, BigInt.zero);
        // The sender paid the fee; it is kept raw, but this wallet paid 0.
        expect(_fee(inc).raw, BigInt.zero);
        expect(_od(inc)[TxV2OdKeys.beamFee], '100000');
      });
    }

    test('ids, kernel, comment, confirmations and asset 0', () {
      final t = _map(
        txJson(
          txId: 'c23fc01d158ef164004439bd0040e265',
          status: 3,
          sender: _me,
          receiver: _peer,
          height: 3369249,
          confirmations: 12,
          kernel: '95dd27be38b22b5a' * 4,
          comment: 'Sample note',
          createTime: 1722558627,
        ),
      );
      expect(t.txid, 'c23fc01d158ef164004439bd0040e265');
      expect(t.hash, t.txid);
      expect(t.timestamp, 1722558627);
      expect(t.beamKernelId, startsWith('95dd27be'));
      expect(t.beamAssetId, 0);
      expect(t.contractAddress, isNull);
      expect(_od(t)[TxV2OdKeys.beamComment], 'Sample note');
      // Not stored: it changes with every block (see the test below).
      expect(_od(t).containsKey(TxV2OdKeys.beamConfirmations), isFalse);
      expect(t.height, 3369249);
    });

    test('sent to self', () {
      final t = _map(
        txJson(
          txId: 'dd' * 16,
          status: 3,
          value: 300000,
          sender: _me,
          receiver: _me,
          height: 10,
        ),
      );
      expect(t.type, TransactionType.sentToSelf);
      expect(_received(t).raw, BigInt.from(300000));
      expect(_fee(t).raw, BigInt.from(100000));
      expect(_label(t), 'Sent to self');
    });

    test('a split (tx_split: no address on either side) reads as a split, '
        'never as a payment', () {
      final json = txJson(
        txId: 'd5' * 16,
        status: 1,
        value: 4999998,
        fee: 100000,
        height: null,
      );
      expect(BeamTransaction.fromJson(json).isSplit, isTrue);
      final t = _map(json);
      expect(t.type, TransactionType.sentToSelf);
      expect(_od(t)[TxV2OdKeys.beamSplit], isTrue);
      expect(_received(t).raw, BigInt.from(4999998));
      expect(_fee(t).raw, BigInt.from(100000));
      expect(_label(t), 'Splitting coins (in progress)');

      final done = _map({...json, 'status': 3, 'height': 10});
      expect(_label(done), 'Split into coins');

      // A payment always names its receiver; one to yourself too.
      final paid = _map(txJson(txId: 'd6' * 16, status: 3, receiver: _peer));
      expect(_od(paid).containsKey(TxV2OdKeys.beamSplit), isFalse);
      expect(paid.type, TransactionType.outgoing);
      expect(
        BeamTransaction.fromJson(
          txJson(txId: 'd7' * 16, status: 3, income: true),
        ).isSplit,
        isFalse,
      );
    });

    test('a Confidential Asset transfer is tagged and kept out of the BEAM '
        'history', () {
      final t = _map(
        txJson(
          txId: 'ee' * 16,
          status: 3,
          assetId: 174,
          value: 700,
          sender: _me,
          receiver: _peer,
          height: 10,
        ),
      );
      expect(t.beamAssetId, 174);
      expect(t.contractAddress, beamAssetTag(174));
    });

    test('contract call: fee only, a payout, and BEAM locked into a '
        'contract', () {
      final feeOnly = _map(
        txJson(
          txId: 'f1' * 16,
          status: 3,
          txType: 12,
          fee: 1100000,
          height: 10,
          invokeData: [
            {'contract_id': '6b' * 32, 'amounts': <Object?>[]},
          ],
        ),
      );
      expect(feeOnly.type, TransactionType.outgoing);
      expect(_sent(feeOnly).raw, BigInt.zero);
      expect(_fee(feeOnly).raw, BigInt.from(1100000));
      expect(_od(feeOnly)[TxV2OdKeys.beamContractIds], ['6b' * 32]);
      expect(feeOnly.contractAddress, isNull);

      final payout = _map(
        txJson(
          txId: 'f2' * 16,
          status: 3,
          txType: 12,
          fee: 12100000,
          height: 10,
          invokeData: [
            {
              'contract_id': '87' * 32,
              'amounts': [
                {'asset_id': 0, 'amount_str': '-50000000'},
                {'asset_id': 174, 'amount_str': '-9'},
              ],
            },
          ],
        ),
      );
      expect(payout.type, TransactionType.incoming);
      expect(_received(payout).raw, BigInt.from(50000000));
      expect(_fee(payout).raw, BigInt.from(12100000));

      final locked = _map(
        txJson(
          txId: 'f3' * 16,
          status: 3,
          txType: 12,
          fee: 1100000,
          height: 10,
          invokeData: [
            {
              'contract_id': '72' * 32,
              'amounts': [
                {'asset_id': 0, 'amount_str': '100000000'},
              ],
            },
          ],
        ),
      );
      expect(locked.type, TransactionType.outgoing);
      expect(_sent(locked).raw, BigInt.from(100000000));
      expect(_fee(locked).raw, BigInt.from(1100000));
    });

    test('every recorded transaction maps (25 real shapes)', () {
      for (final json in fixtureList('tx_list')) {
        final t = _map(json);
        expect(t.isBeamTransaction, isTrue);
        expect(_label(t), isNotEmpty);
        expect(_fee(t).raw >= BigInt.zero, isTrue);
      }
    });

    test('an unchanged transaction is recognised as the same', () {
      final json = txJson(txId: 'a1' * 16, status: 1, sender: _me);
      expect(BeamTxMapper.same(_map(json), _map(json)), isTrue);
      final later = Map.of(json)
        ..['status'] = 3
        ..['height'] = 5;
      expect(BeamTxMapper.same(_map(json), _map(later)), isFalse);
    });

    test('a new block does not make a completed transaction differ', () {
      final json = txJson(
        txId: 'a2' * 16,
        status: 3,
        sender: _me,
        height: 3369249,
        confirmations: 12,
      );
      final nextBlock = Map.of(json)..['confirmations'] = 13;
      expect(BeamTxMapper.same(_map(json), _map(nextBlock)), isTrue);
    });
  });

  group('send rules', () {
    TypeMatcher<BeamWalletException> problem(
      BeamWalletProblem p, [
      Pattern? text,
    ]) => isA<BeamWalletException>()
        .having((e) => e.problem, 'problem', p)
        .having((e) => e.toString(), 'message', contains(text ?? ''));

    final vectors =
        (jsonDecode(
              File('test/beam/fixtures/beam_core_address_vectors.json')
                  .readAsStringSync(),
            ) as Map)['valid']
            as List;
    String vector(String type) =>
        (vectors.firstWhere((v) => (v as Map)['type'] == type)
                as Map)['address']
            as String;

    test('regular and regular_new addresses are accepted', () {
      expect(
        BeamSendRules.checkAddress(vector('regular')),
        BeamAddressType.regular,
      );
      expect(
        BeamSendRules.checkAddress(' ${vector('regular_new')}\n'),
        BeamAddressType.regularNew,
      );
    });

    test('every BEAM address type can be paid, each in its own way', () {
      expect(
        BeamSendRules.checkAddress(vector('offline')),
        BeamAddressType.offline,
      );
      final regular = BeamSendMode.forType(BeamAddressType.regular);
      expect(regular.minimumFee, BigInt.from(100000));
      expect(regular.offlineFlag, isFalse);
      expect(regular.receiverMustBeOnline, isTrue);

      final offline = BeamSendMode.forType(BeamAddressType.offline);
      expect(offline.minimumFee, BigInt.from(1100000));
      expect(offline.offlineFlag, isTrue);
      expect(offline.receiverMustBeOnline, isFalse);

      for (final t in [
        BeamAddressType.maxPrivacy,
        BeamAddressType.publicOffline,
      ]) {
        final mode = BeamSendMode.forType(t);
        expect(mode.minimumFee, BigInt.from(1100000), reason: t.name);
        expect(mode.offlineFlag, isFalse, reason: t.name);
        expect(mode.explanation, contains('0.011 BEAM'), reason: t.name);
      }
    });

    test('not an address: empty, garbage, other coins', () {
      expect(
        () => BeamSendRules.checkAddress('  '),
        throwsA(problem(BeamWalletProblem.invalidAddress, 'Enter the')),
      );
      for (final bad in [
        'hello',
        '0x52908400098527886E0F7030069857D2E4169EE7',
        'bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq',
      ]) {
        expect(
          () => BeamSendRules.checkAddress(bad),
          throwsA(problem(BeamWalletProblem.invalidAddress, "isn't a BEAM")),
        );
      }
    });

    test('amounts: zero, too much, send-all takes the fee out', () {
      expect(
        () => BeamSendRules.checkAmount(
          amount: BigInt.zero,
          fee: kBeamDefaultFee,
          available: _g(1),
        ),
        throwsA(problem(BeamWalletProblem.invalidAmount, 'above zero')),
      );
      expect(
        () => BeamSendRules.checkAmount(
          amount: _g(0.0095),
          fee: kBeamDefaultFee,
          available: _g(0.01),
        ),
        throwsA(
          problem(
            BeamWalletProblem.insufficientFunds,
            'Not enough BEAM. Sending 0.0095 BEAM plus the 0.001 BEAM fee '
            'needs 0.0105 BEAM, and 0.01 BEAM is available.',
          ),
        ),
      );
      expect(
        BeamSendRules.checkAmount(
          amount: _g(0.01),
          fee: kBeamDefaultFee,
          available: _g(0.01),
        ),
        _g(0.009),
      );
      expect(
        BeamSendRules.checkAmount(
          amount: _g(0.005),
          fee: kBeamDefaultFee,
          available: _g(0.01),
        ),
        _g(0.005),
      );
    });

    test('not synced: says why and that sending is paused', () {
      const behind = BeamSyncCatchingUp(
        node: BeamNodeKind.publicNode,
        explorerCheck: BeamExplorerCheck.aheadOfWallet,
        blockInterval: Duration(minutes: 1),
        walletHeight: 100,
        networkHeight: 142,
        blocksBehind: 42,
      );
      expect(
        () => BeamSendRules.checkSynced(behind),
        throwsA(
          problem(
            BeamWalletProblem.notSynced,
            'Behind by 42 blocks',
          ).having((e) => '$e', 'paused', contains('Sending is paused')),
        ),
      );
      BeamSendRules.checkSynced(
        const BeamSynced(
          node: BeamNodeKind.publicNode,
          explorerCheck: BeamExplorerCheck.agrees,
        ),
      );
    });

    test('formatting', () {
      expect(BeamSendRules.formatBeam(BigInt.from(100000)), '0.001 BEAM');
      expect(BeamSendRules.formatBeam(_g(12)), '12.0 BEAM');
      expect(BeamSendRules.formatBeam(BigInt.one), '0.00000001 BEAM');
    });
  });
}
