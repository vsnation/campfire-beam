/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM Receive in Campfire's own screens (ReceiveView on phones,
// DesktopReceive on desktop, WalletAddressesView for the list), over a real
// BeamWallet whose core is a FakeTransport answering from the sanitized
// addr_list fixture.
//
// Goldens (macOS host only; fonts rasterise differently elsewhere):
//   scripts/beam/host_test.sh --no-analyze --copy-goldens --update-goldens \
//     test/beam/receive_ui

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/pages/receive_view/addresses/wallet_addresses_view.dart';
import 'package:stackwallet/pages/receive_view/receive_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_receive.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/clipboard_interface.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/widgets/beam/receive/beam_address_list.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_text.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_widgets.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

import '../wallet/beam_wallet_test_support.dart' show waitFor;
import 'receive_ui_harness.dart';

const _desktopWindow = Size(500, 1080);

/// Campfire's desktop Send/Receive column (MyWallet): 460 wide, a white
/// card with 20 px padding, in a scrolling list, on the app's Material
/// page.
Widget _desktopColumn(String walletId, ClipboardInterface clipboard) =>
    Builder(
      builder: (context) => Material(
        color: Theme.of(context).extension<StackColors>()!.background,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 460,
            child: ListView(
              primary: false,
              padding: const EdgeInsets.all(20),
              children: [
                RoundedWhiteContainer(
                  padding: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: DesktopReceive(
                      walletId: walletId,
                      clipboard: clipboard,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

/// Campfire's "Wallet addresses" page body. On this (desktop) host the
/// page leaves its phone app bar out, so only the list is shown.
Widget _addresses(String walletId) => Builder(
  builder: (context) => Material(
    color: Theme.of(context).extension<StackColors>()!.background,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: WalletAddressesView(walletId: walletId),
    ),
  ),
);

String _shownAddress(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byKey(BeamReceiveKeys.address)).data!;

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await ReceiveDb.open();
  });

  Future<ReceiveWorld> world(
    WidgetTester tester, {
    ReceiveCore? core,
    bool device = true,
    bool nodeOn = false,
    bool open = true,
    bool ownNode = false,
  }) async {
    late ReceiveWorld w;
    await tester.runAsync(() async {
      w = await ReceiveWorld.create(
        tmp,
        core: core,
        privateNodeDevice: device,
        privateNodeOn: nodeOn,
      );
      if (open) await w.openWallet();
      if (ownNode) await w.confirmOwnNode();
    });
    return w;
  }

  Future<void> finish(WidgetTester tester, ReceiveWorld w) async {
    await drainToasts(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(w.close);
  }

  group('Receive (phone, 375 px)', () {
    testWidgets('shows the wallet\'s regular address at once, QR and copy '
        'above the fold, and makes no new address on open', (tester) async {
      final w = await world(tester, core: ReceiveCore()..names = ['alice']);
      final clipboard = FakeClipboard();
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId, clipboard: clipboard),
        backend: w.backend(),
      );
      await settle(tester);

      expect(_shownAddress(tester), fixtureCurrent());
      expect(w.core.created, isEmpty, reason: 'an address existed');
      expectOnScreen(tester, find.byKey(BeamReceiveKeys.qr), phone);
      expectOnScreen(tester, find.byKey(BeamReceiveKeys.copy), phone);
      expect(find.text(BeamReceiveText.regularExplainer), findsOneWidget);
      // The name chip: the BANS name this wallet owns.
      expect(find.byKey(BeamReceiveKeys.nameCard), findsOneWidget);
      expect(find.text('alice.beam'), findsOneWidget);
      expect(find.text(BeamReceiveText.nameExplainer), findsOneWidget);
      expect(w.core.bansActions, ['my_key', 'view_domain']);

      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_phone.png'),
        );
      }

      await tester.tap(find.byKey(BeamReceiveKeys.copy));
      await tester.pump();
      expect((await clipboard.getData('text/plain'))!.text, fixtureCurrent());
      await tester.tap(find.byKey(BeamReceiveKeys.share));
      await tester.pump();
      expect(w.shared, [fixtureCurrent()]);
      await drainToasts(tester);
      await tester.tap(find.byKey(BeamReceiveKeys.nameCopy('alice.beam')));
      await tester.pump();
      expect((await clipboard.getData('text/plain'))!.text, 'alice.beam');

      // Open Receive again: still the same address, still nothing made.
      await drainToasts(tester);
      await tester.pumpWidget(const SizedBox());
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId, clipboard: clipboard),
        backend: w.backend(),
      );
      await settle(tester);
      expect(_shownAddress(tester), fixtureCurrent());
      expect(w.core.created, isEmpty);
      await finish(tester, w);
    });

    testWidgets('makes one regular, never-expiring address when the wallet '
        'has none, and not another on the next open', (tester) async {
      final w = await world(tester);
      // The wallet's only usable address went away (deleted elsewhere).
      w.core.addrs = w.core.addrs.where((a) => a['expired'] == true).toList();

      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);

      expect(w.core.created, hasLength(1));
      expect(w.core.created.single['type'], 'regular');
      expect(w.core.created.single['expiration'], 'never');
      expect(_shownAddress(tester), syntheticRegular(1));

      await tester.pumpWidget(const SizedBox());
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      expect(_shownAddress(tester), syntheticRegular(1));
      expect(w.core.created, hasLength(1), reason: 'reused on the next open');
      await finish(tester, w);
    });

    testWidgets('a new address on request; the old one keeps working', (
      tester,
    ) async {
      final w = await world(tester);
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      await tester.tap(find.byKey(BeamReceiveKeys.newAddress));
      await settle(tester);
      expect(w.core.created.single['type'], 'regular');
      expect(_shownAddress(tester), syntheticRegular(1));
      expect(find.text(BeamReceiveText.newAddressReady), findsOneWidget);
      expect(
        w.core.addrs.where((a) => a['address'] == fixtureCurrent()),
        hasLength(1),
        reason: 'the old address is not deleted',
      );
      await finish(tester, w);
    });

    testWidgets('on a public node the private types are shown disabled, '
        'with the reason and the way to turn the private node on', (
      tester,
    ) async {
      final w = await world(tester);
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      expect(find.byKey(BeamReceiveKeys.nameCard), findsNothing);

      await tester.ensureVisible(find.byKey(BeamReceiveKeys.moreWays));
      await tester.tap(find.byKey(BeamReceiveKeys.moreWays));
      await settle(tester);
      expect(
        find.text(
          'Turn on your private node in Node settings — it takes about 2 '
          'hours the first time.',
        ),
        findsOneWidget,
      );
      for (final t in ['offline', 'max_privacy', 'public_offline']) {
        expect(find.byKey(ValueKey('beamReceive.type.$t')), findsOneWidget);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('beamReceive.type.max_privacy')),
      );
      await tester.tap(
        find.byKey(const ValueKey('beamReceive.type.max_privacy')),
      );
      await settle(tester);
      expect(w.core.created, isEmpty, reason: 'disabled: nothing is made');
      expect(find.text('Max privacy address'), findsOneWidget);

      await tester.ensureVisible(find.byKey(BeamReceiveKeys.privateReason));
      await settle(tester, rounds: 1);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_phone_private_off.png'),
        );
      }
      await tester.ensureVisible(find.byKey(BeamReceiveKeys.openNodeSettings));
      await tester.tap(find.byKey(BeamReceiveKeys.openNodeSettings));
      await tester.pump();
      expect(w.nodeSettingsOpened, [false]);
      await finish(tester, w);
    });

    testWidgets('while the core connects: what is happening, then why it '
        'takes a moment', (tester) async {
      // A wallet whose core has not connected yet, with nothing cached.
      final w = await world(tester, open: false);
      await tester.runAsync(() => w.openWallet(open: false));
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await tester.pump();
      expect(find.text(BeamReceiveText.gettingAddress), findsOneWidget);
      expect(find.text(BeamReceiveText.gettingAddressSlow), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester, rounds: 2);
      expect(find.text(BeamReceiveText.gettingAddressSlow), findsOneWidget);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_phone_loading.png'),
        );
      }
      await finish(tester, w);
    });

    testWidgets('when the core cannot start: says why, never blames the '
        'user, offers Try again', (tester) async {
      final w = await world(tester, open: false);
      await tester.runAsync(() async {
        w.host.openError = const BeamHostException(
          BeamHostError.binaryMissing,
          'wallet-api not found',
        );
        await w.openWallet(waitLive: false);
        await waitFor(() => w.wallet.coreProblem != null, what: 'problem');
      });
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      expect(find.text(BeamReceiveText.cantGetAddress), findsOneWidget);
      expect(find.text(w.wallet.coreProblem!.message), findsOneWidget);
      expect(find.byKey(BeamReceiveKeys.tryAgain), findsOneWidget);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_phone_problem.png'),
        );
      }
      await finish(tester, w);
    });

    testWidgets('no name when the core cannot read BANS names', (
      tester,
    ) async {
      final w = await world(tester, core: ReceiveCore()..names = null);
      await pumpScreen(
        tester,
        ReceiveView(walletId: w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      expect(w.core.bansActions, contains('my_key'), reason: 'it was asked');
      expect(find.byKey(BeamReceiveKeys.nameCard), findsNothing);
      expect(_shownAddress(tester), fixtureCurrent());
      await finish(tester, w);
    });
  });

  group('Receive (desktop)', () {
    testWidgets('once the private node is confirmed, each private type '
        'makes the right address, shown with its QR', (tester) async {
      final w = await world(
        tester,
        core: ReceiveCore()..names = ['alice'],
        nodeOn: true,
        ownNode: true,
      );
      expect(w.wallet.privateNodeStatus!.privateReceiveAvailable, isTrue);
      final clipboard = FakeClipboard();
      await pumpScreen(
        tester,
        _desktopColumn(w.wallet.walletId, clipboard),
        backend: w.backend(),
        size: _desktopWindow,
      );
      await settle(tester);
      expect(_shownAddress(tester), fixtureCurrent());
      await tester.tap(find.byKey(BeamReceiveKeys.moreWays));
      await settle(tester);
      expect(find.byKey(BeamReceiveKeys.privateReason), findsNothing);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_desktop_private_on.png'),
        );
      }

      Future<void> make(String wire) async {
        final tile = find.byKey(ValueKey('beamReceive.type.$wire'));
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await settle(tester);
      }

      await make('max_privacy');
      expect(w.core.created.last['type'], 'max_privacy');
      expect(w.core.created.last['expiration'], 'auto');
      expect(w.core.created.last.containsKey('offline_payments'), isFalse);
      expect(find.text('Max privacy address'), findsWidgets);
      expect(
        find.text(BeamReceiveText.typeExplainer(BeamAddressType.maxPrivacy)),
        findsWidgets,
      );
      if (isMacHost) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/receive_desktop_max_privacy_dialog.png'),
        );
      }
      await tester.tap(find.byKey(BeamReceiveKeys.dialogCopy));
      await tester.pump();
      expect(
        (await clipboard.getData('text/plain'))!.text,
        fixtureToken('max_privacy'),
      );
      await drainToasts(tester);
      await tester.tap(find.byKey(BeamReceiveKeys.dialogDone));
      await settle(tester);

      await make('offline');
      expect(w.core.created.last['type'], 'offline');
      expect(w.core.created.last['offline_payments'], 1);
      expect(w.core.created.last['expiration'], 'auto');
      await tester.tap(find.byKey(BeamReceiveKeys.dialogDone));
      await settle(tester);

      await make('public_offline');
      expect(w.core.created.last['type'], 'public_offline');
      expect(w.core.created.last['expiration'], 'never');
      await tester.tap(find.byKey(BeamReceiveKeys.dialogDone));
      await settle(tester);

      // A public address is meant to be posted: it is reused, not remade.
      await make('public_offline');
      expect(w.core.created, hasLength(3));
      await tester.tap(find.byKey(BeamReceiveKeys.dialogDone));
      await settle(tester);
      await finish(tester, w);
    });

    testWidgets('on a public node: disabled with the reason, opens the '
        'desktop node settings', (tester) async {
      final w = await world(tester, core: ReceiveCore()..names = ['alice']);
      await pumpScreen(
        tester,
        _desktopColumn(w.wallet.walletId, FakeClipboard()),
        backend: w.backend(),
        size: _desktopWindow,
      );
      await settle(tester);
      await tester.tap(find.byKey(BeamReceiveKeys.moreWays));
      await settle(tester);
      expect(find.byKey(BeamReceiveKeys.privateReason), findsOneWidget);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/receive_desktop_private_off.png'),
        );
      }
      await tester.tap(find.byKey(BeamReceiveKeys.openNodeSettings));
      await tester.pump();
      expect(w.nodeSettingsOpened, [true]);
      await finish(tester, w);
    });
  });

  group('Wallet addresses', () {
    testWidgets('active first with the one Receive shows; expired folded '
        'behind a count', (tester) async {
      final w = await world(tester);
      await pumpScreen(
        tester,
        _addresses(w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      final current = fixtureCurrent();
      expect(find.byKey(BeamAddressListKeys.tile(current)), findsOneWidget);
      expect(find.text(BeamReceiveText.onReceive), findsOneWidget);
      expect(find.text('Sample note 6'), findsOneWidget);
      expect(find.text(BeamReceiveText.expiredCount(19)), findsOneWidget);
      final firstExpired = fixtureAddrs().first['address']! as String;
      expect(find.byKey(BeamAddressListKeys.tile(firstExpired)), findsNothing);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/addresses_phone.png'),
        );
      }
      await tester.tap(find.byKey(BeamAddressListKeys.expiredHeader));
      await settle(tester);
      expect(
        find.byKey(BeamAddressListKeys.tile(firstExpired)),
        findsOneWidget,
      );
      expect(find.text('Sample note 1'), findsOneWidget);
      expect(w.core.created, isEmpty, reason: 'the list never makes one');
      await finish(tester, w);
    });

    testWidgets('edit a label', (tester) async {
      final w = await world(tester);
      await pumpScreen(
        tester,
        _addresses(w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      final current = fixtureCurrent();
      await tester.tap(find.byKey(BeamAddressListKeys.edit(current)));
      await settle(tester);
      expect(find.byKey(BeamAddressListKeys.labelField), findsOneWidget);
      await tester.enterText(
        find.byKey(BeamAddressListKeys.labelField),
        'From Alex',
      );
      await tester.pump();
      if (isMacHost) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/addresses_edit_label.png'),
        );
      }
      await tester.tap(find.byKey(BeamAddressListKeys.saveLabel));
      await settle(tester);
      expect(w.core.edited.single, {
        'address': current,
        'comment': 'From Alex',
      });
      expect(find.text('From Alex'), findsOneWidget);
      expect(find.text(BeamReceiveText.labelSaved), findsOneWidget);
      await finish(tester, w);
    });

    testWidgets('delete asks first and says what deleting means; Campfire '
        'stops showing the deleted address', (tester) async {
      final w = await world(tester);
      await pumpScreen(
        tester,
        _addresses(w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      final current = fixtureCurrent();

      await tester.tap(find.byKey(BeamAddressListKeys.delete(current)));
      await settle(tester);
      expect(find.text(BeamReceiveText.deleteMessage), findsOneWidget);
      if (isMacHost) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/addresses_delete_confirm.png'),
        );
      }
      await tester.tap(find.text(BeamReceiveText.cancel));
      await settle(tester);
      expect(w.core.deleted, isEmpty);

      await tester.tap(find.byKey(BeamAddressListKeys.delete(current)));
      await settle(tester);
      await tester.tap(find.byKey(BeamAddressListKeys.confirmDelete));
      await settle(tester, rounds: 6);
      expect(w.core.deleted.single['address'], current);
      expect(find.byKey(BeamAddressListKeys.tile(current)), findsNothing);
      expect(find.text(BeamReceiveText.deleted), findsOneWidget);
      // Campfire's cache no longer offers the deleted address.
      final isar = MainDB.instance.isar;
      String cachedReceiving() => isar.walletInfo
          .where()
          .walletIdEqualTo(w.wallet.walletId)
          .findFirstSync()!
          .cachedReceivingAddress;
      await tester.runAsync(
        () => waitFor(
          () =>
              isar.addresses
                      .where()
                      .valueWalletIdEqualTo(current, w.wallet.walletId)
                      .findFirstSync()
                      ?.subType ==
                  AddressSubType.unknown &&
              cachedReceiving() != current,
          what: 'deleted address dropped from the cache',
        ),
      );
      expect(cachedReceiving(), isNot(current));
      await finish(tester, w);
    });

    testWidgets('empty: one tap makes the first address', (tester) async {
      final w = await world(tester);
      w.core.addrs = [];
      await pumpScreen(
        tester,
        _addresses(w.wallet.walletId),
        backend: w.backend(),
      );
      await settle(tester);
      expect(find.byKey(BeamAddressListKeys.empty), findsOneWidget);
      expect(find.text(BeamReceiveText.noAddresses), findsOneWidget);
      if (isMacHost) {
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/addresses_phone_empty.png'),
        );
      }
      await tester.tap(find.text(BeamReceiveText.getMyAddress));
      await settle(tester);
      expect(w.core.created.single['type'], 'regular');
      expect(
        find.byKey(BeamAddressListKeys.tile(syntheticRegular(1))),
        findsOneWidget,
      );
      await finish(tester, w);
    });
  });
}
