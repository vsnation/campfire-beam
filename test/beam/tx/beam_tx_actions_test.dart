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
import 'package:stackwallet/wallets/beam/models/beam_call_results.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/tx/beam_tx_actions.dart';

BeamTransaction _tx(
  BeamTxStatus status, {
  bool income = false,
  BeamTxType type = BeamTxType.simple,
  BeamAddressType? addressType = BeamAddressType.regular,
  String? failure,
}) => BeamTransaction(
  txId: 'aa',
  statusCode: status.code,
  statusString: status.name,
  txTypeCode: type.code,
  txTypeString: type.name,
  sender: 's',
  receiver: 'r',
  comment: '',
  createTime: 0,
  income: income,
  addressType: addressType,
  failureReason: failure,
);

void main() {
  test('cancel only while pending or in progress, as the core allows', () {
    for (final s in BeamTxStatus.values) {
      expect(
        BeamTxActions.canCancel(_tx(s)),
        s == BeamTxStatus.pending || s == BeamTxStatus.inProgress,
        reason: s.name,
      );
    }
  });

  test('delete only once finished', () {
    for (final s in BeamTxStatus.values) {
      expect(
        BeamTxActions.canDelete(_tx(s)),
        const {
          BeamTxStatus.completed,
          BeamTxStatus.failed,
          BeamTxStatus.canceled,
        }.contains(s),
        reason: s.name,
      );
    }
  });

  test('a proof is offered for completed payments this wallet sent', () {
    expect(BeamTxActions.canExportProof(_tx(BeamTxStatus.completed)), isTrue);
    expect(
      BeamTxActions.canExportProof(_tx(BeamTxStatus.completed, income: true)),
      isFalse,
    );
    expect(
      BeamTxActions.canExportProof(
        _tx(BeamTxStatus.completed, type: BeamTxType.contract),
      ),
      isFalse,
    );
    expect(BeamTxActions.canExportProof(_tx(BeamTxStatus.inProgress)), isFalse);
  });

  test('a stuck regular payment explains that both wallets must be online',
      () {
    expect(
      BeamTxActions.statusLine(_tx(BeamTxStatus.inProgress)),
      contains('come online'),
    );
    expect(
      BeamTxActions.statusLine(
        _tx(
          BeamTxStatus.inProgress,
          addressType: BeamAddressType.maxPrivacy,
        ),
      ),
      'In progress',
    );
  });

  test('failures are explained without blaming the user', () {
    expect(
      BeamTxActions.statusLine(
        _tx(BeamTxStatus.failed, failure: 'Transaction expired'),
      ),
      startsWith('Expired'),
    );
    expect(
      BeamTxActions.statusLine(
        _tx(BeamTxStatus.failed, failure: 'Inputs missing'),
      ),
      contains('already spent'),
    );
    expect(BeamTxActions.statusLine(_tx(BeamTxStatus.completed)), 'Sent');
    expect(
      BeamTxActions.statusLine(_tx(BeamTxStatus.completed, income: true)),
      'Received',
    );
  });

  test('a proof verdict is a sentence', () {
    String fmt(BigInt a, int aid) => '${a ~/ BigInt.from(100000000)} BEAM';
    final ok = BeamProofVerdict.of(
      BeamPaymentProofInfo(
        isValid: true,
        sender: 'a' * 64,
        receiver: 'b' * 64,
        amount: BigInt.from(200000000),
        kernel: 'c' * 64,
        assetId: 0,
      ),
      describeAmount: fmt,
    );
    expect(ok.valid, isTrue);
    expect(ok.sentence, startsWith('Valid: 2 BEAM was paid from aaaaaaaa…'));
    final bad = BeamProofVerdict.of(
      BeamPaymentProofInfo(
        isValid: false,
        sender: '',
        receiver: '',
        amount: BigInt.zero,
        kernel: '',
        assetId: 0,
      ),
      describeAmount: fmt,
    );
    expect(bad.valid, isFalse);
    expect(bad.sentence, contains('not valid'));
  });
}
