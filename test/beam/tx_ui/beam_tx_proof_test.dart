/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Payment proofs from the details screen: export (copy the whole proof),
// a payment without one, and checking a pasted proof — valid, not valid,
// and text that is not a proof at all. The core is a FakeTransport.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_details.dart';

import 'tx_ui_harness.dart';

final _sentJson = simpleTxJson(seed: 71, status: BeamTxStatus.completed);
final _receivedJson = simpleTxJson(
  seed: 72,
  status: BeamTxStatus.completed,
  income: true,
);
final _proof = fakeHex(73, 640);

Future<void> _open(
  WidgetTester tester,
  Map<String, Object?> json,
  FakeTxBackend fake,
) async {
  setSurface(tester, desktop: false);
  await loadFonts(tester);
  await tester.pumpWidget(
    app(
      home: BeamTxDetails(
        transaction: mapped(json),
        walletId: kWalletId,
        coin: kBeam,
      ),
      fake: fake,
      desktop: false,
    ),
  );
  await settle(tester);
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Map<String, Object?> _proofInfo({required bool valid}) => {
  'is_valid': valid,
  'sender': valid ? kOwnAddress : '',
  'receiver': valid ? kPeerAddress : '',
  'amount': valid ? 10000000 : 0,
  'kernel': valid ? fakeHex(74, 64) : '',
  'asset_id': 0,
};

void main() {
  testWidgets('export: the proof is shown short and copied whole', (
    tester,
  ) async {
    final copied = captureClipboard(tester);
    final fake = FakeTxBackend({
      'export_payment_proof': {'payment_proof': _proof},
    });
    await _open(tester, _sentJson, fake);
    await _tapVisible(tester, find.text('Get payment proof'));
    expect(fake.transport.lastParams('export_payment_proof'), {
      'txId': _sentJson['txId'],
    });
    expect(find.text('Payment proof'), findsWidgets);
    expect(find.textContaining('nothing else'), findsOneWidget);
    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/proof_export_phone.png'),
    );
    await tester.tap(find.byKey(const Key('beamProofCopy')));
    await tester.pumpAndSettle();
    expect(copied.last, _proof);
  });

  testWidgets('export refused: said plainly, no error code', (tester) async {
    final fake = FakeTxBackend({
      'export_payment_proof': const BeamRpcException(
        -32602,
        'Some mandatory data for payment proof is missing',
      ),
    });
    await _open(tester, _sentJson, fake);
    await _tapVisible(tester, find.text('Get payment proof'));
    expect(find.text('No payment proof'), findsOneWidget);
    expect(
      find.textContaining("receiver's address does not support"),
      findsOneWidget,
    );
    expect(find.textContaining('-32602'), findsNothing);
  });

  Future<void> check(
    WidgetTester tester,
    FakeTxBackend fake,
    String pasted,
  ) async {
    await _open(tester, _receivedJson, fake);
    await _tapVisible(tester, find.byKey(const Key('beamTxCheckProof')));
    await tester.enterText(find.byKey(const Key('beamProofInput')), pasted);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('beamProofCheck')));
    await tester.pumpAndSettle();
  }

  testWidgets('check: a valid proof reads as one sentence', (tester) async {
    final fake = FakeTxBackend({
      'verify_payment_proof': _proofInfo(valid: true),
    });
    await check(tester, fake, _proof);
    expect(fake.transport.lastParams('verify_payment_proof'), {
      'payment_proof': _proof,
    });
    final verdict = tester.widget<Text>(
      find.byKey(const Key('beamProofVerdict')),
    );
    expect(verdict.data, startsWith('Valid: 0.10000000 BEAM was paid from '));
    expect(verdict.data, contains(kOwnAddress.substring(0, 8)));
    // "kernel" stays behind the info button.
    expect(verdict.data, contains('(transaction ID '));
    expect(verdict.data, isNot(contains('kernel')));
    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/proof_check_valid_phone.png'),
    );
  });

  testWidgets('check: a proof that does not hold', (tester) async {
    final fake = FakeTxBackend({
      'verify_payment_proof': _proofInfo(valid: false),
    });
    await check(tester, fake, _proof);
    expect(
      tester.widget<Text>(find.byKey(const Key('beamProofVerdict'))).data,
      'This proof is not valid. It does not show that the payment happened.',
    );
    await expectLater(
      find.byKey(kShot),
      matchesGoldenFile('goldens/proof_check_invalid_phone.png'),
    );
  });

  testWidgets('check: text that is not a proof is explained', (tester) async {
    final fake = FakeTxBackend({
      'verify_payment_proof': const BeamRpcException(-32602, 'Invalid proof'),
    });
    await check(tester, fake, 'hello');
    expect(
      tester.widget<Text>(find.byKey(const Key('beamProofProblem'))).data,
      'This text is not a payment proof. Ask the sender to send the whole '
      'proof again.',
    );
  });
}
