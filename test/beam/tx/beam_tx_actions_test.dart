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

  test('a stuck regular payment explains that both wallets must be online', () {
    expect(
      BeamTxActions.statusLine(_tx(BeamTxStatus.inProgress)),
      contains('come online'),
    );
    expect(
      BeamTxActions.statusLine(
        _tx(BeamTxStatus.inProgress, addressType: BeamAddressType.maxPrivacy),
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

  group('failure messages the core really sends', () {
    // BEAM_TX_FAILURE_REASON_MAP, wallet/core/common.h, beam-7.5.14493.
    const users = {
      'Transaction timed out': 'Expired: the other wallet',
      'Address is expired': 'receiving address has expired',
      'Failed to register transaction with the blockchain, see node logs '
              'for details':
          'Not accepted by the network',
      'Not enough inputs to process the transaction': 'not enough coins',
      'Fee is too small': 'network fee was too low',
      'Fee is too large': 'too large',
      'Cannot extract shielded coin, fee is too big.': 'too large',
      'Payment not signed by the receiver, please send wallet logs to Beam '
              'support':
          'did not sign',
      'Failed to send Transaction parameters': 'could not be reached',
      'Failed to get transaction parameters': 'could not be reached',
      'No voucher, no address to receive it': 'one-time keys',
      'The sender cannot get vouchers for offline transaction': 'one-time keys',
      'Asset transactions are disabled in the receiver wallet':
          'does not accept tokens',
      'Transaction cancelled': 'Cancelled by the other side',
      'Aborted by the user': 'Cancelled',
      'Transaction is not valid, please send wallet logs to Beam support':
          'could not complete it',
      'Invalid kernel proof provided': 'could not complete it',
      'Key keeper malfunctioned': 'could not complete it',
      'Transaction has invalid state': 'could not complete it',
    };

    test('each one reads as plain words and says nothing was sent', () {
      users.forEach((core, expected) {
        final s = BeamTxActions.failureSentence(core, interactive: true);
        expect(s, contains(expected), reason: core);
        if (expected != 'Cancelled') {
          expect(s, contains('Nothing was sent.'), reason: core);
        }
      });
    });

    test('a timeout on a non-interactive payment blames no wallet', () {
      expect(
        BeamTxActions.failureSentence(
          'Transaction timed out',
          interactive: false,
        ),
        startsWith('Expired: it was not added to a block'),
      );
    });

    test('an unknown message never shows the core text as status', () {
      final line = BeamTxActions.statusLine(
        _tx(
          BeamTxStatus.failed,
          failure: 'Side chain bridge has network error',
        ),
      );
      expect(line, BeamTxActions.notCompleted);
    });
  });
}
