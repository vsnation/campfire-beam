/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Restoring a BEAM wallet: naming it leads straight to the 12-word phrase
// (BEAM has no phrase length, passphrase or start date to choose, so
// Campfire's "Restore options" step is skipped; other coins keep it), and
// the dialog after the restore says why the balance reads 0 for a while and
// has one button labelled with where it goes. Dialog goldens are copied to
// docs/beam/screenshots/B-RESTORE/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/restore/beam_restore_flow_test.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/add_wallet_views/name_your_wallet_view/name_your_wallet_view.dart';
import 'package:stackwallet/pages/add_wallet_views/restore_wallet_view/restore_options_view/restore_options_view.dart';
import 'package:stackwallet/pages/add_wallet_views/restore_wallet_view/restore_wallet_view.dart';
import 'package:stackwallet/pages/add_wallet_views/restore_wallet_view/sub_widgets/restore_succeeded_dialog.dart';
import 'package:stackwallet/pages/wallet_view/wallet_view.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart'
    show DesktopMenuItemId;
import 'package:stackwallet/providers/desktop/current_desktop_menu_item.dart';
import 'package:stackwallet/providers/desktop/desktop_open_wallet_request.dart';
import 'package:stackwallet/utilities/enums/add_wallet_type_enum.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart'
    show kBeamRestoreScanningMessage;
import 'package:stackwallet/widgets/desktop/desktop_dialog_close_button.dart';
import 'package:tuple/tuple.dart';

import '../wiring_ui/wiring_harness.dart';

/// Shows [dialog] the way the restore does (Campfire's showDialog over the
/// screen behind it) once the first frame is up.
class _DialogHost extends StatefulWidget {
  const _DialogHost(this.dialog);

  final Widget dialog;

  @override
  State<_DialogHost> createState() => _DialogHostState();
}

class _DialogHostState extends State<_DialogHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showDialog<void>(
        context: context,
        useSafeArea: false,
        barrierDismissible: true,
        builder: (_) => widget.dialog,
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('My wallets')));
}

void main() {
  final beam = Beam(CryptoCurrencyNetwork.main);

  group('after naming the wallet', () {
    test('BEAM goes straight to the 12-word phrase', () {
      final (route, args) = RestoreOptionsView.nextStepFor('My BEAM', beam);
      expect(RestoreOptionsView.skipsOptionsFor(beam), isTrue);
      expect(route, RestoreWalletView.routeName);
      // Exactly what route_generator accepts for that page, and what the
      // options page itself would have passed for BEAM.
      expect(args, isA<Tuple5<String, CryptoCurrency, int, int, String>>());
      final t = args as Tuple5<String, CryptoCurrency, int, int, String>;
      expect(t.item1, 'My BEAM');
      expect(t.item2, beam);
      expect(t.item3, 12);
      expect(t.item4, 0);
      expect(t.item5, '');
    });

    test('other coins keep Campfire\'s restore options', () {
      for (final coin in [
        Bitcoin(CryptoCurrencyNetwork.main),
        Firo(CryptoCurrencyNetwork.main),
        Monero(CryptoCurrencyNetwork.main),
      ]) {
        final (route, args) = RestoreOptionsView.nextStepFor('Mine', coin);
        expect(RestoreOptionsView.skipsOptionsFor(coin), isFalse);
        expect(route, RestoreOptionsView.routeName, reason: coin.prettyName);
        expect(args, isA<Tuple2<String, CryptoCurrency>>());
        expect((args as Tuple2<String, CryptoCurrency>).item2, coin);
      }
    });
  });

  test('desktop: "Open my wallet" selects My Campfire and asks the desktop '
      'home to open that wallet', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(currentDesktopMenuItemProvider.state).state =
        DesktopMenuItemId.settings;
    container.read(prevDesktopMenuItemProvider.state).state =
        DesktopMenuItemId.settings;
    RestoreWalletView.openOnDesktop(container, 'restored-id');
    expect(
      container.read(currentDesktopMenuItemProvider),
      DesktopMenuItemId.myStack,
    );
    expect(
      container.read(prevDesktopMenuItemProvider),
      DesktopMenuItemId.myStack,
    );
    expect(container.read(desktopOpenWalletRequestProvider), 'restored-id');
  });

  group('screens', () {
    final db = WiringDb();
    setUpAll(db.open);
    tearDownAll(db.close);

    testWidgets('name → Next → the phrase, with no "Restore options" page', (
      tester,
    ) async {
      await pumpWiring(
        tester,
        NameYourWalletView(addWalletType: AddWalletType.Restore, coin: beam),
        desktop: true,
        frame: false,
      );
      await tester.enterText(find.byType(TextField).first, 'My BEAM');
      await tester.pump();
      await tester.tap(find.text('Next'));
      await settle(tester, rounds: 2);

      expect(find.byType(RestoreOptionsView), findsNothing);
      expect(find.text('Choose recovery phrase length'), findsNothing);
      final page = tester.widget<RestoreWalletView>(
        find.byType(RestoreWalletView),
      );
      expect(page.walletName, 'My BEAM');
      expect(page.coin, beam);
      expect(page.seedWordsLength, 12);
      expect(page.restoreBlockHeight, 0);
      expect(page.mnemonicPassphrase, '');
      expect(find.text('Enter your 12-word recovery phrase.'), findsOneWidget);
      await finish(tester);
    });

    for (final desktop in [false, true]) {
      final name = desktop ? 'desktop' : 'phone';
      const label = kBeamRestoredOpenWallet;
      testWidgets('$name: "Wallet restored" says why it reads 0, and "$label" '
          'goes there', (tester) async {
        var actions = 0;
        await pumpWiring(
          tester,
          _DialogHost(
            BeamRestoreSucceededDialog(
              isDesktop: desktop,
              actionLabel: label,
              onAction: () => actions++,
            ),
          ),
          desktop: desktop,
          frame: false,
        );
        await settle(tester, rounds: 2);

        expect(find.text('Wallet restored'), findsOneWidget);
        expect(find.text(kBeamRestoreScanningMessage), findsOneWidget);
        // One button, labelled with its outcome, on screen without
        // scrolling (a 375 × 667 phone or the 1280 × 800 window).
        final button = find.byKey(const Key('beamRestoredAction'));
        expect(button, findsOneWidget);
        expect(
          find.descendant(of: button, matching: find.text(label)),
          findsOneWidget,
        );
        expect(find.text('OK'), findsNothing);
        expect(find.text('Ok'), findsNothing);
        final r = tester.getRect(button);
        final screen = desktop ? desktopWindow : phone;
        expect(r.bottom, lessThanOrEqualTo(screen.height));
        expect(r.right, lessThanOrEqualTo(screen.width));
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/restore_succeeded_$name.png'),
        );

        await tester.tap(button);
        await settle(tester, rounds: 2);
        expect(actions, 1);
        expect(find.byType(BeamRestoreSucceededDialog), findsNothing);
        expect(find.text('My wallets'), findsOneWidget);
        await finish(tester);
      });
    }

    testWidgets('phone: "Open my wallet" loads the wallet and opens its home', (
      tester,
    ) async {
      final wallet = await openBeamWallet(tester, db, name: 'Restored');
      late NavigatorState nav;
      await pumpWiring(
        tester,
        Builder(
          builder: (context) {
            nav = Navigator.of(context);
            return const Scaffold(body: Center(child: Text('My wallets')));
          },
        ),
        desktop: false,
      );
      unawaited(RestoreWalletView.openRestoredWallet(nav, wallet));
      // Loading the wallet is real I/O behind Campfire's loading overlay.
      for (
        var i = 0;
        i < 10 && find.byType(WalletView).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await settle(tester, rounds: 2);
      final view = tester.widget<WalletView>(find.byType(WalletView));
      expect(view.walletId, wallet.walletId);
      // The loading overlay is gone; the wallet's own home is on top.
      expect(find.text('Opening Restored'), findsNothing);
      await finish(tester);
    });

    testWidgets('desktop: closing the dialog does nothing else', (
      tester,
    ) async {
      var actions = 0;
      await pumpWiring(
        tester,
        _DialogHost(
          BeamRestoreSucceededDialog(
            isDesktop: true,
            actionLabel: kBeamRestoredOpenWallet,
            onAction: () => actions++,
          ),
        ),
        desktop: true,
        frame: false,
      );
      await settle(tester, rounds: 2);
      await tester.tap(
        find.descendant(
          of: find.byType(DesktopDialogCloseButton),
          matching: find.byType(MaterialButton),
        ),
      );
      await settle(tester, rounds: 2);
      expect(find.byType(BeamRestoreSucceededDialog), findsNothing);
      expect(actions, 0);
      await finish(tester);
    });
  });
}
