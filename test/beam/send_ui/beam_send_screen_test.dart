/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM Send screen and Campfire's confirmation for it, phone (375 x
// 667) and desktop, with goldens. Name lookups and name payments run the
// real BeamBansService over recorded wallet-api answers (FakeTransport);
// see send_ui_support.dart.
//
//   flutter test --update-goldens test/beam/send_ui   (write the goldens)
//   flutter test test/beam/send_ui                    (compare)

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/pages/send_view/confirm_transaction_view.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/widgets/beam/send/beam_confirm_content.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_result.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_format.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';

import '../contracts/bans/bans_fixtures.dart';
import 'send_ui_support.dart';

const _send = Key('beamSendReviewButton');
const _to = Key('beamSendRecipientField');
const _amount = Key('beamSendAmountField');

Widget _page(
  ScriptedBackend b, {
  Duration nameDebounce = const Duration(milliseconds: 400),
  String? Function(int assetId, BigInt amount)? assetWorth,
}) => BeamSendPage(
  backend: b,
  coin: Beam(CryptoCurrencyNetwork.main),
  walletId: 'beam-test-wallet',
  walletName: 'My BEAM',
  locale: 'en_US',
  clipboard: FakeClipboard(),
  minimumBuildTime: Duration.zero,
  routeOnSuccessName: '/',
  nameDebounce: nameDebounce,
  assetWorth: assetWorth,
);

Future<ScriptedBackend> _open(
  WidgetTester tester, {
  required bool desktop,
  ScriptedBackend? backend,
  Duration nameDebounce = const Duration(milliseconds: 400),
  String? Function(int assetId, BigInt amount)? assetWorth,
}) async {
  await setScreen(tester, desktop: desktop);
  final b = backend ?? ScriptedBackend();
  await pumpCampfire(
    tester,
    home: _page(b, nameDebounce: nameDebounce, assetWorth: assetWorth),
    desktop: desktop,
  );
  await tester.pump(const Duration(milliseconds: 50));
  return b;
}

bool _sendEnabled(WidgetTester tester) {
  final w = tester.widget(find.byKey(_send));
  if (w is TextButton) return w.onPressed != null;
  return (w as dynamic).enabled as bool;
}

Future<void> _type(WidgetTester tester, Key field, String text) async {
  await tester.enterText(find.byKey(field), text);
  await tester.pump();
}

Future<void> _pickAsset(WidgetTester tester, int id) async {
  final selector = find.byKey(const Key('beamSendAssetSelector'));
  await tester.ensureVisible(selector);
  await tester.pump();
  await tester.tap(selector);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.tap(find.byKey(Key('beamAssetChoice_$id')));
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _golden(WidgetTester tester, String name) async {
  // Let the fields' floating labels finish moving.
  await tester.pump(const Duration(milliseconds: 800));
  await settleAssets(tester);
  await expectLater(
    find.byKey(goldenKey),
    matchesGoldenFile('goldens/$name.png'),
  );
}

/// Taps Send on the form and waits for Campfire's confirmation.
Future<void> _toConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(_send));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

final _regular = vectorAddress('regular');

void main() {
  group('phone, 375 x 667', () {
    testWidgets('empty form: Send is on screen without scrolling, and off', (
      tester,
    ) async {
      await _open(tester, desktop: false);
      final cta = tester.getRect(find.byKey(_send));
      expect(cta.top, greaterThan(0));
      expect(cta.bottom, lessThanOrEqualTo(667));
      expect(find.text('Send'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
      expect(find.text('Enter BEAM address or name'), findsOneWidget);
      await _golden(tester, 'phone_01_empty');
    });

    testWidgets('an address: its type in plain words, fee 0.001 BEAM, Send '
        'on; nothing prepared yet', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.5');
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.textContaining("receiver's wallet must be online"),
        findsOneWidget,
      );
      expect(find.text('0.001 BEAM'), findsOneWidget);
      expect(_sendEnabled(tester), isTrue);
      final cta = tester.getRect(find.byKey(_send));
      expect(cta.bottom, lessThanOrEqualTo(667));
      expect(b.log, isEmpty);
      await _golden(tester, 'phone_02_address');
    });

    testWidgets('address confirm: amount, asset, fee, destination, total — '
        'prepared, not sent', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.5');
      await _toConfirm(tester);
      expect(find.text('Confirm transaction'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmAmount')))
            .data,
        '0.5 BEAM',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmFee')))
            .data,
        '0.001 BEAM',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmTotal')))
            .data,
        '0.501 BEAM',
      );
      expect(find.text('Send 0.5 BEAM'), findsOneWidget);
      expect(b.log, ['prepareSend'], reason: 'prepareSend only, no send');
      await _golden(tester, 'phone_03_address_confirm');
    });

    testWidgets('two activations of Send in one frame build one payment, '
        'with no "Nothing was sent" for the second (L-1)', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.5');
      // Two activations before any frame is drawn (a repeated Enter key, a
      // double tap faster than the building dialog's barrier appears).
      final send = tester.widget<TextButton>(find.byKey(_send)).onPressed!;
      send();
      send();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Confirm transaction'), findsOneWidget);
      expect(find.text('Nothing was sent'), findsNothing);
      expect(b.log, ['prepareSend']);
    });

    testWidgets('a name: skeleton while looking it up, then the owner card', (
      tester,
    ) async {
      // A slow lookup, so the skeleton can be photographed.
      final b = await _open(
        tester,
        desktop: false,
        nameDebounce: const Duration(seconds: 3),
      );
      await _type(tester, _to, '@Beam');
      expect(find.text('Looking up beam.beam…'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
      await _golden(tester, 'phone_04_name_resolving');
      expect(find.text('Looking up beam.beam…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await settleLookup(tester);
      expect(find.text('beam.beam'), findsOneWidget);
      expect(find.text('Registered name'), findsOneWidget);
      expect(
        find.textContaining(
          'Owner key ${BansKey.fingerprint(beamOwnerKey)} · active until',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'the amount is visible on the blockchain, the '
          'recipient is not',
        ),
        findsOneWidget,
      );
      expect(b.core.actions, ['view_name']);
      await _type(tester, _amount, '0.00012345');
      expect(_sendEnabled(tester), isTrue);
      expect(find.text('At least 0.011 BEAM'), findsOneWidget);
      await _golden(tester, 'phone_05_name_payable');
    });

    testWidgets('a name on hold is payable, with a warning', (tester) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, 'onhold.beam');
      await settleLookup(tester);
      expect(find.text('This name has lapsed'), findsOneWidget);
      expect(
        find.textContaining('Payments still reach its owner'),
        findsOneWidget,
      );
      await _golden(tester, 'phone_06_name_on_hold');
    });

    testWidgets('nobody owns the name: no Send, and what to do', (
      tester,
    ) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, 'nobody');
      await _type(tester, _amount, '1');
      await settleLookup(tester);
      expect(find.text('No one owns nobody.beam'), findsOneWidget);
      expect(
        find.textContaining('Check the spelling, or ask for their address'),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isFalse);
      await _golden(tester, 'phone_07_name_not_registered');
    });

    testWidgets('a name past its hold is refused as expired', (tester) async {
      final b = ScriptedBackend();
      b.core.names['gone'] = viewNameOutput(
        beamOwnerKey,
        kTip - kBansHoldBlocks - 10,
      );
      await _open(tester, desktop: false, backend: b);
      await _type(tester, _to, 'gone');
      await settleLookup(tester);
      expect(find.text('gone.beam has expired'), findsOneWidget);
      expect(find.textContaining('payments to it are refused'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
    });

    testWidgets('a failed lookup says so and "Try again" looks again', (
      tester,
    ) async {
      final b = ScriptedBackend();
      b.core.names['flaky'] = const BeamRpcException(-32603, 'node busy');
      await _open(tester, desktop: false, backend: b);
      await _type(tester, _to, 'flaky');
      await settleLookup(tester);
      expect(find.text("Couldn't check flaky.beam"), findsOneWidget);
      expect(find.text('Try again', findRichText: true), findsOneWidget);
      await _golden(tester, 'phone_08_name_failed');
      b.core.names['flaky'] = 'view_name_beam';
      await tester.tap(find.text('Try again', findRichText: true));
      await settleLookup(tester);
      expect(find.text('Registered name'), findsOneWidget);
    });

    testWidgets('name payment confirm: amount and fee come from the decoded '
        'transaction; nothing broadcast', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _type(tester, _amount, '0.00012345');
      await _toConfirm(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('beamConfirmRecipient'))).data,
        'beam.beam',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmOwner')))
            .data,
        'Owner key ${BansKey.fingerprint(beamOwnerKey)}',
      );
      // pay_beam: 12345 groth to `beam`, kernel fee 1,100,000 groth.
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmAmount')))
            .data,
        '0.00012345 BEAM',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmFee')))
            .data,
        '0.011 BEAM',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmTotal')))
            .data,
        '0.01112345 BEAM',
      );
      expect(find.text('Send to beam.beam'), findsOneWidget);
      // Resolved for the card, then preparePay: params, resolve, build,
      // resolve again. Nothing signed or sent.
      expect(b.core.actions, [
        'view_name',
        'view_params',
        'view_name',
        'pay',
        'view_name',
      ]);
      expect(b.core.broadcasts, 0);
      expect(b.log, ['hold', 'preparePay']);
      await _golden(tester, 'phone_09_name_confirm');
    });

    testWidgets('after Send on a phone: the sent sheet (Beam girl, tx id, '
        '"View in history") and the not-sure sheet', (tester) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _type(tester, _amount, '0.00012345');
      await _toConfirm(tester);
      final review = tester
          .widget<ConfirmTransactionView>(find.byType(ConfirmTransactionView))
          .beamReview!;
      final ctx = tester.element(find.byType(BeamConfirmContent));
      unawaited(
        showBeamSendSuccess(
          ctx,
          review: review,
          txId: 'ee' * 16,
          desktop: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Payment sent'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('beamSendSuccessSummary')))
            .data,
        '0.00012345 BEAM to beam.beam.',
      );
      expect(find.text('View in history'), findsOneWidget);
      await _golden(tester, 'phone_12_name_sent');
      await tester.tap(find.byKey(const Key('beamSendSuccessDone')));
      await tester.pump(const Duration(milliseconds: 400));

      unawaited(
        showBeamSendFailure(
          ctx,
          error: const BeamWalletException(
            BeamWalletProblem.sendOutcomeUnknown,
            "The connection dropped while sending, so it's not certain "
            'whether the payment went out. Check your transaction history '
            'before sending again.',
          ),
          outcomeUnknown: true,
          desktop: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Check your history before sending again'),
        findsOneWidget,
      );
      expect(find.text('Check my history'), findsOneWidget);
      await _golden(tester, 'phone_13_not_sure');
    });

    testWidgets('not synced: the banner says why and Send is off', (
      tester,
    ) async {
      final b = await _open(
        tester,
        desktop: false,
        backend: ScriptedBackend(sync: catchingUp),
      );
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.5');
      expect(find.text('Catching up with the network'), findsOneWidget);
      expect(find.textContaining('Behind by 42 blocks'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
      await _golden(tester, 'phone_10_not_synced');
      b.setSync(synced);
      await tester.pump();
      await tester.pump();
      expect(find.text('Catching up with the network'), findsNothing);
      expect(_sendEnabled(tester), isTrue);
    });

    testWidgets('a token to a name needs the fee in BEAM', (tester) async {
      await _open(
        tester,
        desktop: false,
        backend: ScriptedBackend(balances: {0: g(0.005), 174: g(10)}),
      );
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _pickAsset(tester, 174);
      await _type(tester, _amount, '5');
      expect(
        find.textContaining(
          'The network fee (at least 0.011 BEAM) is paid in BEAM, and this '
          'wallet has 0.005 BEAM. Add BEAM to send FOMO.',
        ),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isFalse);
      await _golden(tester, 'phone_11_token_needs_beam_fee');
    });

    testWidgets('an unverified asset that copies FOMO: the generic icon, '
        'its #id and a warning', (tester) async {
      final b = ScriptedBackend(balances: {0: g(1), 321: g(50)});
      b.metadata[321] = 'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO;NTHUN=GROTH';
      await _open(tester, desktop: false, backend: b);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _pickAsset(tester, 321);
      await _type(tester, _amount, '5');
      expect(find.text('Not verified · #321'), findsOneWidget);
      expect(
        find.textContaining('Not the verified FOMO (#174)'),
        findsOneWidget,
      );
      expect(find.text('FOMO #321'), findsWidgets);
      expect(_sendEnabled(tester), isTrue);
      await _golden(tester, 'phone_14_unverified_asset');
    });

    testWidgets('a token to an address is refused in plain words', (
      tester,
    ) async {
      await _open(
        tester,
        desktop: false,
        backend: ScriptedBackend(balances: {0: g(1), 174: g(10)}),
      );
      await _type(tester, _to, _regular);
      await _pickAsset(tester, 174);
      await _type(tester, _amount, '5');
      expect(
        find.text(
          'FOMO can be sent to a name for now, not to an address. Choose '
          'BEAM to pay this address.',
        ),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isFalse);
    });

    testWidgets('Send all to an address: the whole balance, the fee comes '
        'out of it', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, _regular);
      await tester.tap(find.byKey(const Key('beamSendAllButton')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(_amount));
      expect(field.controller!.text, '2');
      expect(
        find.text('The network fee comes out of this amount.'),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isTrue);
      await _toConfirm(tester);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmAmount')))
            .data,
        '1.999 BEAM',
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmTotal')))
            .data,
        '2 BEAM',
      );
      expect(b.log, ['prepareSend']);
    });

    testWidgets('Send all to a name keeps the minimum fee back', (
      tester,
    ) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await tester.tap(find.byKey(const Key('beamSendAllButton')));
      await tester.pump();
      final field = tester.widget<TextField>(find.byKey(_amount));
      expect(field.controller!.text, '1.989');
      expect(_sendEnabled(tester), isTrue);
    });

    testWidgets('too little BEAM for amount plus fee: says how much is '
        'needed', (tester) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '1.9995');
      expect(
        find.text(
          'Not enough BEAM. Sending 1.9995 BEAM plus the 0.001 BEAM network '
          'fee needs 2.0005 BEAM, and 2 BEAM is available.',
        ),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isFalse);
      await _type(tester, _amount, '0');
      expect(find.text('Enter an amount above zero.'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
    });

    testWidgets('an offline address: what it means, and the 0.011 BEAM '
        'push fee the core asks for', (tester) async {
      final b = await _open(tester, desktop: false);
      await _type(tester, _to, vectorAddress('offline'));
      await _type(tester, _amount, '0.1');
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Offline address'), findsOneWidget);
      expect(
        find.textContaining(
          "Arrives even while the receiver's wallet is "
          'closed',
        ),
        findsOneWidget,
      );
      expect(find.text('0.011 BEAM'), findsOneWidget);
      expect(_sendEnabled(tester), isTrue);
      await _toConfirm(tester);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('beamConfirmFee')))
            .data,
        '0.011 BEAM',
      );
      expect(b.log, ['prepareSend']);
    });

    testWidgets('text that is neither an address nor a name says why', (
      tester,
    ) async {
      await _open(tester, desktop: false);
      await _type(tester, _to, 'ab!cd');
      expect(
        find.text('Use only lowercase letters, numbers, - _ and ~.'),
        findsOneWidget,
      );
      expect(_sendEnabled(tester), isFalse);
      await _type(tester, _to, 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh!');
      expect(
        find.text(
          "That isn't a BEAM address or a name. Copy it again from "
          "the person you're paying.",
        ),
        findsOneWidget,
      );
    });
  });

  // Seen in the DMG test: the asset picker listed amounts only, while the
  // wallet home shows what each is worth.
  group('asset picker values', () {
    final one = BigInt.from(100000000);

    test('BEAM in fiat; an asset in BEAM and fiat; nothing without a price', () {
      String? fiat(BigInt groth) => groth * BigInt.from(100) ~/ one < BigInt.one
          ? 'under 0.01 USD'
          : '≈ ${(groth * BigInt.from(100) ~/ one) ~/ BigInt.from(100)}.'
                '${((groth * BigInt.from(100) ~/ one) % BigInt.from(100)).toString().padLeft(2, '0')} USD';
      BigInt? inBeam(int id, BigInt amount) =>
          id == 174 ? amount * BigInt.from(1232) ~/ BigInt.from(10000) : null;

      expect(
        BeamSendFormat.assetWorth(
          0,
          one * BigInt.from(5) ~/ BigInt.two,
          fiat: fiat,
        ),
        '≈ 2.50 USD',
      );
      expect(
        BeamSendFormat.assetWorth(
          174,
          one * BigInt.from(200),
          inBeam: inBeam,
          fiat: fiat,
        ),
        '≈ 24.64 BEAM · 24.64 USD',
      );
      expect(
        BeamSendFormat.assetWorth(174, one, inBeam: inBeam),
        '≈ 0.1232 BEAM',
      );
      expect(BeamSendFormat.assetWorth(321, one, inBeam: inBeam), isNull);
      expect(BeamSendFormat.assetWorth(0, one), isNull);
      expect(BeamSendFormat.assetWorth(0, BigInt.zero, fiat: fiat), isNull);
    });

    testWidgets('the picker shows the worth beside each amount', (
      tester,
    ) async {
      await _open(
        tester,
        desktop: true,
        backend: ScriptedBackend(balances: {0: g(2.5), 174: g(10)}),
        assetWorth: (id, _) => id == 0 ? '≈ 0.02 USD' : null,
      );
      final selector = find.byKey(const Key('beamSendAssetSelector'));
      await tester.ensureVisible(selector);
      await tester.pump();
      await tester.tap(selector);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester
            .widget<Text>(find.byKey(const Key('beamAssetChoiceWorth_0')))
            .data,
        '≈ 0.02 USD',
      );
      expect(find.byKey(const Key('beamAssetChoiceWorth_174')), findsNothing);
    });
  });

  group('desktop', () {
    Future<void> enterPassword(WidgetTester tester, String password) async {
      await tester.enterText(
        find.byKey(const Key('desktopLoginPasswordFieldKey')),
        password,
      );
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    Future<void> waitForSend(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('the form, an address filled in', (tester) async {
      await _open(tester, desktop: true);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.25');
      await tester.enterText(
        find.byKey(const Key('beamSendCommentField')),
        'rent',
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(_sendEnabled(tester), isTrue);
      await _golden(tester, 'desktop_01_form');
    });

    testWidgets('the gate: a wrong password sends nothing; the right one '
        'sends once, then shows the transaction id', (tester) async {
      final b = await _open(tester, desktop: true);
      await _type(tester, _to, _regular);
      await _type(tester, _amount, '0.25');
      await tester.enterText(
        find.byKey(const Key('beamSendCommentField')),
        'rent',
      );
      await tester.pump();
      await _toConfirm(tester);
      expect(find.text('Confirm BEAM transaction'), findsOneWidget);
      await _golden(tester, 'desktop_02_address_confirm');
      expect(b.log, ['prepareSend']);

      await tester.tap(find.byKey(const Key('beamConfirmSendButton')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Enter your wallet password to send BEAM'),
        findsOneWidget,
      );
      await enterPassword(tester, 'wrong');
      await tester.pump(const Duration(seconds: 2));
      expect(b.log, ['prepareSend'], reason: 'nothing sent without the gate');

      await tester.tap(find.byKey(const Key('beamConfirmSendButton')));
      await tester.pump(const Duration(milliseconds: 400));
      await enterPassword(tester, 'correct horse');
      await waitForSend(tester);
      expect(b.log.where((e) => e == 'confirmSend'), hasLength(1));
      expect(b.confirmed.single.noteOnChain, 'rent');
      expect(b.log, contains('note:${'ab' * 16}'));
      expect(find.text('Payment sent'), findsOneWidget);
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('beamSendSuccessTxId')),
            )
            .data,
        'ababab…ababab',
      );
      await _golden(tester, 'desktop_03_sent');
      await tester.tap(find.byKey(const Key('beamSendSuccessDone')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Payment sent'), findsNothing);
      expect(find.text('Confirm BEAM transaction'), findsNothing);
    });

    testWidgets('a name payment is executed only after the gate', (
      tester,
    ) async {
      final b = await _open(tester, desktop: true);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _type(tester, _amount, '0.00012345');
      await _toConfirm(tester);
      expect(find.text('Send to beam.beam'), findsOneWidget);
      expect(b.core.broadcasts, 0);
      await tester.tap(find.byKey(const Key('beamConfirmSendButton')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(b.core.broadcasts, 0, reason: 'the gate is up, nothing sent');
      await enterPassword(tester, 'correct horse');
      await waitForSend(tester);
      expect(b.core.broadcasts, 1);
      expect(
        b.core.transport.lastParams('process_invoke_data')['data'],
        bansRaw('pay_beam'),
      );
      expect(find.text('Payment sent'), findsOneWidget);
      expect(
        find.textContaining('The owner of beam.beam can claim it'),
        findsOneWidget,
      );
      expect(b.log, containsAllInOrder(['preparePay', 'executePay']));
      expect(b.log, contains('release'));
    });

    testWidgets('the owner changes between the card and signing: refused, '
        'nothing sent, and the card shows the new owner', (tester) async {
      final b = await _open(tester, desktop: true);
      await _type(tester, _to, 'beam');
      await settleLookup(tester);
      await _type(tester, _amount, '0.00012345');
      await _toConfirm(tester);
      // Someone else owns `beam` now.
      b.core.override = (name) => name == 'beam' ? 'view_name_listed' : null;
      await tester.tap(find.byKey(const Key('beamConfirmSendButton')));
      await tester.pump(const Duration(milliseconds: 400));
      await enterPassword(tester, 'correct horse');
      await waitForSend(tester);
      expect(b.core.broadcasts, 0);
      expect(find.text('Nothing was sent'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('beamSendFailureMessage')))
            .data,
        'beam.beam changed owner just now, so nothing was sent. Check the '
        "name with the person you're paying, then try again.",
      );
      await _golden(tester, 'desktop_04_owner_changed');
      await tester.tap(find.byKey(const Key('beamSendFailureDone')));
      await tester.pump(const Duration(milliseconds: 500));
      await settleLookup(tester);
      expect(find.text('Confirm BEAM transaction'), findsNothing);
      expect(
        find.textContaining('Owner key 18b1…0962'),
        findsOneWidget,
        reason: 'the form looked the name up again',
      );
    });
  });
}
