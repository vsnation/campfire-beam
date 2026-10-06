/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the BEAM history says for each state, from fixture transactions
// mapped through the committed BeamTxMapper and read back by BeamTxView.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/amount/amount_formatter.dart';
import 'package:stackwallet/utilities/amount/amount_unit.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_text.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_view.dart';

import 'tx_ui_harness.dart';

BeamTxView _view(Map<String, Object?> json) => BeamTxView.of(mapped(json))!;

final _fmt = AmountFormatter(
  unit: AmountUnit.normal,
  locale: 'en_US',
  coin: kBeam,
  maxDecimals: 8,
);

void main() {
  test('every status reads in plain words, with the right title', () {
    const waitReceiver = "Waiting for the receiver's wallet to come online";
    final cases = <(Map<String, Object?>, String, String, BeamTxTone)>[
      (
        simpleTxJson(seed: 1, status: BeamTxStatus.pending),
        'Sending',
        waitReceiver,
        BeamTxTone.waiting,
      ),
      (
        simpleTxJson(seed: 2, status: BeamTxStatus.inProgress),
        'Sending',
        waitReceiver,
        BeamTxTone.waiting,
      ),
      (
        simpleTxJson(seed: 3, status: BeamTxStatus.inProgress, income: true),
        'Receiving',
        'Waiting for the sender to finish',
        BeamTxTone.waiting,
      ),
      (
        simpleTxJson(seed: 4, status: BeamTxStatus.registering),
        'Sending',
        'Sending to the network',
        BeamTxTone.waiting,
      ),
      (
        simpleTxJson(seed: 5, status: BeamTxStatus.confirming),
        'Sending',
        'Waiting for confirmation',
        BeamTxTone.waiting,
      ),
      (
        simpleTxJson(seed: 6, status: BeamTxStatus.completed),
        'Sent',
        'Sent',
        BeamTxTone.done,
      ),
      (
        simpleTxJson(seed: 7, status: BeamTxStatus.completed, income: true),
        'Received',
        'Received',
        BeamTxTone.done,
      ),
      (
        // The core's real text for an expired payment.
        simpleTxJson(
          seed: 8,
          status: BeamTxStatus.failed,
          failure: 'Transaction timed out',
        ),
        'Not sent',
        'Expired: the other wallet did not respond in time. '
            'Nothing was sent.',
        BeamTxTone.failed,
      ),
      (
        simpleTxJson(
          seed: 9,
          status: BeamTxStatus.failed,
          failure: 'Inputs missing',
        ),
        'Not sent',
        'Failed: the coins were already spent elsewhere. '
            'Nothing was sent.',
        BeamTxTone.failed,
      ),
      (
        // As recorded in the fixture.
        simpleTxJson(
          seed: 10,
          status: BeamTxStatus.failed,
          failure:
              'Failed to register transaction with the blockchain, '
              'see node logs for details',
        ),
        'Not sent',
        'Not accepted by the network. Nothing was sent.',
        BeamTxTone.failed,
      ),
      (
        simpleTxJson(seed: 11, status: BeamTxStatus.canceled),
        'Cancelled',
        'Cancelled. Nothing was sent.',
        BeamTxTone.neutral,
      ),
    ];
    for (final (json, title, status, tone) in cases) {
      final v = _view(json);
      final why = '${json['status_string']} ${json['failure_reason']}';
      expect(BeamTxText.title(v), title, reason: why);
      expect(BeamTxText.status(v), status, reason: why);
      expect(BeamTxText.tone(v), tone, reason: why);
    }
  });

  test('"Address is expired" is not read as a timeout', () {
    final v = _view(
      simpleTxJson(
        seed: 12,
        status: BeamTxStatus.failed,
        failure: 'Address is expired',
      ),
    );
    expect(BeamTxText.status(v), startsWith('Not sent: the receiving address'));
    expect(BeamTxText.status(v), contains('Ask for a new address'));
  });

  test('no core failure message reaches the screen verbatim', () {
    // BEAM_TX_FAILURE_REASON_MAP (wallet/core/common.h), swap-only ones
    // left out: a BEAM-only wallet never runs atomic swaps.
    const core = [
      'Unexpected reason, please send wallet logs to Beam support',
      'Receiver signature in not valid, please send wallet logs to Beam '
          'support',
      'Failed to register transaction with the blockchain, see node logs '
          'for details',
      'Transaction is not valid, please send wallet logs to Beam support',
      'Invalid kernel proof provided',
      'Failed to send Transaction parameters',
      'Not enough inputs to process the transaction',
      'Address is expired',
      'Failed to get transaction parameters',
      'Transaction timed out',
      'Payment not signed by the receiver, please send wallet logs to Beam '
          'support',
      'Kernel maximum height is too high',
      'Transaction has invalid state',
      'Fee is too small',
      'Fee is too large',
      "Kernel's min height is unacceptable",
      'No valid asset id/asset owner id',
      'Invalid asset id',
      'Some mandatory data for payment proof is missing',
      'Asset transactions are disabled in the receiver wallet',
      'Peer Identity required',
    ];
    for (final reason in core) {
      final v = _view(
        simpleTxJson(seed: 13, status: BeamTxStatus.failed, failure: reason),
      );
      final line = BeamTxText.status(v);
      expect(line, isNot(contains(reason)), reason: reason);
      expect(line.toLowerCase(), isNot(contains('logs')), reason: reason);
      expect(line.toLowerCase(), isNot(contains('kernel')), reason: reason);
      expect(line, contains('Nothing was sent'), reason: reason);
      // The core's text is still there for support, behind "Copy".
      expect(BeamTxText.technical(v), reason);
    }
  });

  test('a contract call is named, with its funds from the core', () {
    final json = contractTxJson(seed: 20);
    final v = _view(json);
    expect(v.isContract, isTrue);
    // Campfire's cache alone: the contract is known, the funds are not.
    expect(BeamTxText.title(v), 'DEX');
    final funds = BeamTxText.funds(
      v,
      contractAmounts: BeamTransaction.fromJson(json).invokeData.first.amounts,
    );
    expect(BeamTxText.title(v, funds: funds), 'DEX swap');
    expect(
      [
        for (final f in funds)
          BeamTxText.amount(f.delta, f.assetId, _fmt, sign: true),
      ],
      ['−0.06984329 BEAM', '+4,864.10722456 CHAD'],
    );
  });

  test(
    'an unknown contract is a "Contract call"; unverified assets show #id',
    () {
      final json = contractTxJson(seed: 21, dex: false, otherAsset: 4242);
      final v = _view(json);
      final funds = BeamTxText.funds(
        v,
        contractAmounts: BeamTransaction.fromJson(json)
            .invokeData
            .first
            .amounts,
      );
      expect(BeamTxText.title(v, funds: funds), 'Contract call');
      expect(
        BeamTxText.amount(
          funds.last.delta,
          funds.last.assetId,
          _fmt,
          sign: true,
        ),
        '+1.00000000 #4242',
      );
    },
  );

  test('a fee-only contract call moved nothing but its fee', () {
    final v = _view(contractTxJson(seed: 22, dex: false, feeOnly: true));
    expect(BeamTxText.funds(v, contractAmounts: const []), isEmpty);
    expect(v.paidFee, BigInt.from(13248300));
  });

  test('actions follow BeamTxActions exactly', () {
    final pending = _view(
      simpleTxJson(seed: 30, status: BeamTxStatus.inProgress),
    );
    expect(pending.canCancel, isTrue);
    expect(pending.canDelete, isFalse);
    final sent = _view(simpleTxJson(seed: 31, status: BeamTxStatus.completed));
    expect(sent.canCancel, isFalse);
    expect(sent.canDelete, isTrue);
    expect(sent.canExportProof, isTrue);
    expect(sent.canCheckProof, isFalse);
    final received = _view(
      simpleTxJson(seed: 32, status: BeamTxStatus.completed, income: true),
    );
    expect(received.canExportProof, isFalse);
    expect(received.canCheckProof, isTrue);
    final registering = _view(
      simpleTxJson(seed: 33, status: BeamTxStatus.registering),
    );
    expect(registering.canCancel, isFalse);
    expect(registering.canDelete, isFalse);
  });

  test('the counterparty is the other wallet, never this one', () {
    final out = _view(simpleTxJson(seed: 40, status: BeamTxStatus.completed));
    expect(out.counterparty, kPeerAddress);
    final inn = _view(
      simpleTxJson(seed: 41, status: BeamTxStatus.completed, income: true),
    );
    expect(inn.counterparty, kPeerAddress);
    expect(BeamTxText.short(kPeerAddress), hasLength(15));
  });
}
