/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM transaction details: what each state shows (goldens at 375 px and
// desktop), copy and explorer, cancel allowed / refused by the core, and
// delete with its confirmation. The core is a FakeTransport.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/pages/wallet_view/transaction_views/tx_v2/transaction_v2_details_view.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_details.dart';
import 'package:stackwallet/widgets/desktop/desktop_dialog.dart';

import 'tx_ui_harness.dart';

Widget _phone(TransactionV2 tx) =>
    BeamTxDetails(transaction: tx, walletId: kWalletId, coin: kBeam);

Widget _desktop(TransactionV2 tx) => Scaffold(
  backgroundColor: kColors.background.withValues(alpha: 0.6),
  body: Center(
    child: DesktopDialog(
      maxWidth: 640,
      maxHeight: 780,
      child: BeamTxDetails(transaction: tx, walletId: kWalletId, coin: kBeam),
    ),
  ),
);

/// A home screen that opens the details, so a pop can be seen.
Widget _opener(TransactionV2 tx) => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => _phone(tx))),
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> _show(
  WidgetTester tester,
  Widget home,
  FakeTxBackend fake, {
  bool desktop = false,
  double? h,
}) async {
  setSurface(tester, desktop: desktop, h: h);
  await loadFonts(tester);
  await tester.pumpWidget(app(home: home, fake: fake, desktop: desktop));
  await settle(tester);
}

Future<void> _golden(String name) =>
    expectLater(find.byKey(kShot), matchesGoldenFile('goldens/$name.png'));

final _pendingJson = simpleTxJson(
  seed: 51,
  status: BeamTxStatus.inProgress,
  comment: 'Rent for October',
);
final _sentJson = simpleTxJson(
  seed: 52,
  status: BeamTxStatus.completed,
  comment: 'Lunch',
);
final _receivedJson = simpleTxJson(
  seed: 53,
  status: BeamTxStatus.completed,
  income: true,
  value: 250000000,
);
final _expiredJson = simpleTxJson(
  seed: 54,
  status: BeamTxStatus.failed,
  failure: 'Transaction timed out',
);
final _swapJson = contractTxJson(seed: 55);

void main() {
  group('goldens', () {
    testWidgets('phone: payment in progress, Cancel above the fold', (
      tester,
    ) async {
      await _show(tester, _phone(mapped(_pendingJson)), FakeTxBackend());
      expect(
        find.text("Waiting for the receiver's wallet to come online"),
        findsOneWidget,
      );
      final cancel = tester.getRect(find.byKey(const Key('beamTxCancel')));
      expect(cancel.bottom, lessThanOrEqualTo(812));
      expect(find.text('Remove record'), findsNothing);
      await _golden('details_in_progress_phone');
    });

    testWidgets('phone: sent payment (whole page)', (tester) async {
      await _show(tester, _phone(mapped(_sentJson)), FakeTxBackend(), h: 1450);
      expect(find.byKey(const Key('beamTxCancel')), findsNothing);
      expect(find.text('Get payment proof'), findsOneWidget);
      expect(find.text('Remove record'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      await _golden('details_sent_phone');
    });

    testWidgets('phone: received payment (whole page)', (tester) async {
      await _show(
        tester,
        _phone(mapped(_receivedJson)),
        FakeTxBackend(),
        h: 1300,
      );
      expect(find.text('Paid by the sender'), findsOneWidget);
      expect(
        find.text('Check a payment proof', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Get payment proof'), findsNothing);
      expect(find.byType(Image), findsOneWidget); // the small sticker
      await _golden('details_received_phone');
    });

    testWidgets('phone: expired payment', (tester) async {
      await _show(
        tester,
        _phone(mapped(_expiredJson)),
        FakeTxBackend(),
        h: 1100,
      );
      expect(
        find.text(
          'Expired: the other wallet did not respond in time. '
          'Nothing was sent.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Copy technical details', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('None: it never reached the network'), findsOneWidget);
      // A payment that never went through paid no fee.
      expect(find.text('None: nothing was sent'), findsOneWidget);
      expect(find.text('−0.10000000 BEAM'), findsNothing);
      expect(find.text('0.10000000 BEAM'), findsOneWidget);
      await _golden('details_expired_phone');
    });

    testWidgets('phone: DEX swap with both sides', (tester) async {
      final fake = FakeTxBackend()..serveTxStatus([_swapJson]);
      await _show(tester, _phone(mapped(_swapJson)), fake, h: 1100);
      expect(find.text('DEX swap'), findsOneWidget);
      expect(find.text('+4,864.10722456 CHAD'), findsOneWidget);
      expect(find.text('−0.06984329 BEAM'), findsOneWidget);
      expect(find.text('BEAM DEX'), findsOneWidget);
      await _golden('details_swap_phone');
    });

    testWidgets('desktop: sent payment', (tester) async {
      await _show(
        tester,
        _desktop(mapped(_sentJson)),
        FakeTxBackend(),
        desktop: true,
      );
      expect(find.text('−0.10000000 BEAM'), findsOneWidget);
      await _golden('details_sent_desktop');
    });

    testWidgets('desktop: payment in progress', (tester) async {
      await _show(
        tester,
        _desktop(mapped(_pendingJson)),
        FakeTxBackend(),
        desktop: true,
      );
      expect(find.byKey(const Key('beamTxCancel')), findsOneWidget);
      await _golden('details_in_progress_desktop');
    });
  });

  testWidgets("Campfire's details view hands BEAM to the BEAM details", (
    tester,
  ) async {
    final tx = mapped(_sentJson);
    await _show(
      tester,
      TransactionV2DetailsView(
        transaction: tx,
        walletId: kWalletId,
        coin: kBeam,
      ),
      FakeTxBackend(),
    );
    expect(find.byType(BeamTxDetails), findsOneWidget);
  });

  testWidgets('copy the address and the transaction ID', (tester) async {
    final copied = captureClipboard(tester);
    await _show(tester, _phone(mapped(_sentJson)), FakeTxBackend());
    // The address is shortened on screen; the copy is the full address.
    expect(find.text(kPeerAddress), findsNothing);
    await tester.tap(find.text('Copy').first);
    await tester.pumpAndSettle();
    expect(copied.last, kPeerAddress);
    final kernel = _sentJson['kernel']! as String;
    final copyKernel = find.text('Copy').at(1);
    await tester.ensureVisible(copyKernel);
    await tester.pumpAndSettle();
    await tester.tap(copyKernel);
    await tester.pumpAndSettle();
    expect(copied.last, kernel);
    expect(find.text(kernel), findsOneWidget);
  });

  testWidgets('the explorer opens by kernel id, after the privacy warning', (
    tester,
  ) async {
    final fake = FakeTxBackend();
    await _show(tester, _phone(mapped(_sentJson)), fake);
    final link = find.byKey(const Key('beamTxExplorer'));
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('Attention'), findsOneWidget);
    expect(find.textContaining('may log your IP address'), findsOneWidget);
    await tester.tap(find.byKey(const Key('beamTxConfirmYes')));
    await tester.pumpAndSettle();
    expect(fake.opened, [
      Uri.parse(
        'https://explorer.beam.mw/block?kernel_id=${_sentJson['kernel']}',
      ),
    ]);
  });

  testWidgets('the info button explains the word "kernel"', (tester) async {
    await _show(tester, _phone(mapped(_sentJson)), FakeTxBackend());
    final info = find.byKey(const Key('beamTxKernelInfo'));
    await tester.ensureVisible(info);
    await tester.pumpAndSettle();
    await tester.tap(info);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('BEAM calls this the kernel ID'),
      findsOneWidget,
    );
  });

  group('cancel', () {
    testWidgets('allowed: confirm, cancel, refresh, then the record turns '
        'Cancelled', (tester) async {
      final fake = FakeTxBackend({'tx_cancel': true});
      await _show(tester, _phone(mapped(_pendingJson)), fake);
      await tester.tap(find.byKey(const Key('beamTxCancel')));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this payment?'), findsOneWidget);
      expect(find.text('Nothing has been sent yet.'), findsOneWidget);
      await _golden('cancel_confirm_phone');

      await tester.tap(find.byKey(const Key('beamTxConfirmYes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Payment cancelled. Nothing was sent.'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(fake.transport.lastParams('tx_cancel'), {
        'txId': _pendingJson['txId'],
      });
      expect(fake.refreshes, 1);

      // The wallet's refresh stores the new status; the screen follows.
      fake.update(
        mapped({
          ..._pendingJson,
          'status': BeamTxStatus.canceled.code,
          'status_string': 'cancelled',
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('beamTxStatus')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('beamTxStatus'))).data,
        'Cancelled. Nothing was sent.',
      );
      expect(find.byKey(const Key('beamTxCancel')), findsNothing);
      expect(find.text('Remove record'), findsOneWidget);
    });

    testWidgets('refused by the core: "Too late to cancel"', (tester) async {
      final fake = FakeTxBackend({
        'tx_cancel': const BeamRpcException(-32001, 'Invalid tx status'),
      });
      await _show(tester, _phone(mapped(_pendingJson)), fake);
      await tester.tap(find.byKey(const Key('beamTxCancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('beamTxConfirmYes')));
      await tester.pumpAndSettle();
      expect(
        find.text('Too late to cancel: it is already being added to a block'),
        findsOneWidget,
      );
      expect(find.textContaining('-32001'), findsNothing);
      await _golden('cancel_refused_phone');
      expect(fake.refreshes, 1);
    });

    testWidgets('"Keep waiting" changes nothing', (tester) async {
      final fake = FakeTxBackend({'tx_cancel': true});
      await _show(tester, _phone(mapped(_pendingJson)), fake);
      await tester.tap(find.byKey(const Key('beamTxCancel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('beamTxConfirmKeep')));
      await tester.pumpAndSettle();
      expect(fake.transport.callsTo('tx_cancel'), isEmpty);
      expect(fake.refreshes, 0);
    });

    testWidgets('not offered once the core would refuse it', (tester) async {
      for (final status in [
        BeamTxStatus.registering,
        BeamTxStatus.confirming,
        BeamTxStatus.completed,
        BeamTxStatus.failed,
        BeamTxStatus.canceled,
      ]) {
        // A fresh tree per state, as opening another entry would give.
        await tester.pumpWidget(const SizedBox());
        await _show(
          tester,
          _phone(mapped(simpleTxJson(seed: 60, status: status))),
          FakeTxBackend(),
        );
        expect(
          find.byKey(const Key('beamTxCancel')),
          findsNothing,
          reason: status.name,
        );
        final removable = {
          BeamTxStatus.completed,
          BeamTxStatus.failed,
          BeamTxStatus.canceled,
        }.contains(status);
        expect(
          find.byKey(const Key('beamTxDelete')),
          removable ? findsOneWidget : findsNothing,
          reason: status.name,
        );
      }
    });
  });

  group('delete', () {
    testWidgets('confirm, delete, forget the record, refresh, close', (
      tester,
    ) async {
      final fake = FakeTxBackend({'tx_delete': true});
      final tx = mapped(_sentJson);
      await _show(tester, _opener(tx), fake);
      await tester.tap(find.text('open'));
      await settle(tester);
      final remove = find.byKey(const Key('beamTxDelete'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(find.text('Remove this record from your wallet?'), findsOneWidget);
      expect(find.text('Nothing changes on the blockchain.'), findsOneWidget);
      await _golden('delete_confirm_phone');

      await tester.tap(find.byKey(const Key('beamTxConfirmYes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Record removed from this wallet'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(fake.transport.lastParams('tx_delete'), {'txId': tx.txid});
      expect(fake.forgotten, [tx.txid]);
      expect(fake.refreshes, 1);
      expect(find.byType(BeamTxDetails), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('"Keep it" changes nothing', (tester) async {
      final fake = FakeTxBackend({'tx_delete': true});
      await _show(tester, _phone(mapped(_sentJson)), fake);
      final remove = find.byKey(const Key('beamTxDelete'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('beamTxConfirmKeep')));
      await tester.pumpAndSettle();
      expect(fake.transport.callsTo('tx_delete'), isEmpty);
      expect(fake.forgotten, isEmpty);
    });

    testWidgets('a core refusal is explained, the record is kept', (
      tester,
    ) async {
      final fake = FakeTxBackend({
        'tx_delete': const BeamRpcException(-32001, 'Invalid tx status'),
      });
      await _show(tester, _phone(mapped(_sentJson)), fake);
      final remove = find.byKey(const Key('beamTxDelete'));
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('beamTxConfirmYes')));
      await tester.pumpAndSettle();
      expect(find.textContaining('cannot be removed'), findsOneWidget);
      expect(fake.forgotten, isEmpty);
    });
  });
}
