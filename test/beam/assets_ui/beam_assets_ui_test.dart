/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The asset screens (Campfire's token list, token page and token send for
// BEAM Confidential Assets) over a real BeamWallet whose core is a
// FakeTransport answering from the sanitized fixtures plus two made-up
// assets: an unverified "Pepe Coin" and a copycat "FOMO". Prices and LP
// tokens come from the recorded mainnet DEX pools.
//
// Goldens (phone 375×667 at 2×, desktop 1280×800):
//   flutter test --update-goldens test/beam/assets_ui
// The phone goldens use the asset screens' phone layout; Campfire's shared
// buttons inside follow the real platform (a dart:io check), so on a
// desktop test host they keep their desktop size.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/pages/bridge/bridge_wiring.dart';
import 'package:stackwallet/pages/token_view/beam_asset_confirm_view.dart';
import 'package:stackwallet/pages/token_view/beam_asset_receive_view.dart';
import 'package:stackwallet/pages/token_view/beam_asset_send_view.dart';
import 'package:stackwallet/pages/token_view/beam_asset_view.dart';
import 'package:stackwallet/pages/token_view/beam_assets_view.dart';
import 'package:stackwallet/pages/token_view/my_tokens_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/beam_desktop_asset_view.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_text.dart';
import 'package:stackwallet/wallets/beam/assets/beam_hidden_assets.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/models/tx_data.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/widgets/beam/assets/beam_asset_logo.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';

import '../asset_wallet/asset_test_support.dart';
import 'assets_ui_harness.dart';

TxData _pay(String address, BigInt amount) => TxData(
  recipients: [
    TxRecipient(
      address: address,
      amount: Amount(rawValue: amount, fractionDigits: 8),
      isChange: false,
      addressType: AddressType.mimbleWimble,
    ),
  ],
);

Future<void> _golden(String name) =>
    expectLater(find.byKey(goldenKey), matchesGoldenFile('goldens/$name.png'));

BeamSticker _emptySticker(WidgetTester tester) => tester
    .widget<BeamStickerImage>(find.byKey(const Key('beamAssetsEmptySticker')))
    .sticker;

String? textOf(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  return w is Text ? (w.data ?? w.textSpan?.toPlainText()) : null;
}

/// An asset wallet whose core took the payment and then could not be
/// asked about it: every confirm ends with "outcome unknown".
class _UnsureAssetWallet extends BeamAssetWallet {
  _UnsureAssetWallet(super.parent, super.asset);

  int confirmCalls = 0;

  @override
  Future<TxData> confirmSend({required TxData txData}) async {
    confirmCalls++;
    throw const BeamWalletException(
      BeamWalletProblem.sendOutcomeUnknown,
      'The connection dropped while sending.',
    );
  }
}

void main() {
  late Directory tmp;
  late Isar isar;
  late AssetHarness h;
  late BeamWallet wallet;
  late Map<int, BeamAssetContract> contracts;
  late BeamAssetMarket market;
  late TxData fomoTx;
  late TxData copycatTx;

  BeamAssetWallet assetWallet(int id) =>
      BeamAssetWallet.load(parent: wallet, asset: contracts[id]!);

  setUpAll(() async {
    tmp = await tempRoot('beam_assets_ui_test_');
    installCampfireTheme(Directory('${tmp.path}/themes'));
    isar = await openAssetTestDb(Directory('${tmp.path}/isar'));
    h = AssetHarness((await Directory('${tmp.path}/root').create()).path);
    wallet = await h.openWallet(name: 'Campfire BEAM');
    market = BeamAssetMarket(recordedPools());
    contracts = await BeamAssetRegistry.sync(
      isar: isar,
      heldIds: wallet.info.beamAssetTotals.keys,
      api: wallet.coreApi,
      pools: market.pools,
    );
    final payee = vectorAddress('regular');
    final fomo = assetWallet(174);
    fomoTx = await fomo.prepareSend(txData: _pay(payee, g(12.5)));
    await fomo.exit();
    final copycat = assetWallet(fakeFomoId);
    copycatTx = await copycat.prepareSend(txData: _pay(payee, g(250)));
    await copycat.exit();
    // Everything below renders from Campfire's cache, as at unlock.
    await wallet.exit();
    Wallets.sharedInstance.addWallet(wallet);
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  group('asset list', () {
    testWidgets('phone: verified, unverified, copycat, pool shares and '
        'unpriced assets, with the estimated total', (tester) async {
      await pumpAssets(
        tester,
        MyTokensView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
      );
      expect(find.text('My assets'), findsOneWidget);
      expect(find.byType(BeamAssetsView), findsOneWidget);
      // Rounded in the list; every digit on the asset page.
      expect(find.text('568.1297 FOMO'), findsOneWidget);
      expect(
        find.textContaining('2 assets have no price and are not counted'),
        findsOneWidget,
      );
      final holdings = BeamAssetHoldings.build(
        totals: wallet.info.beamAssetTotals,
        contracts: contracts,
        hidden: const {},
        market: market,
      );
      final total = BeamAssetHoldings.portfolio(holdings, marketKnown: true);
      expect(
        find.text(
          BeamAssetText.beamEstimate(total.valueGroth, locale: 'en_US'),
        ),
        findsOneWidget,
      );
      await _golden('assets_list_phone');

      // Further down: pool shares, then what has no price.
      final list = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        find.byKey(const Key('beamAssetRow_175')),
        200,
        scrollable: list,
      );
      // A pool share is named after its pair, with its fee tier and a
      // pair icon.
      expect(find.text('BEAM/FOMO LP'), findsOneWidget);
      expect(find.text('Pool share · 1% fee'), findsWidgets);
      expect(find.text('0.46659234 LP'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('beamAssetRow_175')),
          matching: find.byType(BeamPairLogo),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('beamAssetRow_$fakeFomoId')),
        200,
        scrollable: list,
      );
      await tester.pumpAndSettle();
      // The copycat is flagged in its own row; unpriced assets say so.
      expect(
        find.byKey(const Key('beamAssetWarning_$fakeFomoId')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Not the verified FOMO (#174)'),
        findsOneWidget,
      );
      expect(find.text('PEPE · Unverified #$pepeId'), findsOneWidget);
      expect(find.text(BeamAssetText.noPrice), findsNWidgets(2));
      await _golden('assets_list_end_phone');
    });

    testWidgets('desktop: the same list embedded in the wallet page', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        desktopFrame(MyTokensView(walletId: wallet.walletId)),
        wallet: wallet,
        desktop: true,
        market: market,
      );
      expect(find.byKey(const Key('beamAssetsManageButton')), findsOneWidget);
      await _golden('assets_list_desktop');
    });

    testWidgets('prices not loaded yet: no fake zeros, the total says why', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        MyTokensView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
      );
      expect(
        find.text('Prices load once the wallet is connected.'),
        findsOneWidget,
      );
      expect(find.text(BeamAssetText.noPrice), findsNothing);
      expect(find.textContaining('0 BEAM'), findsNothing);
    });

    testWidgets('hidden assets: out of the list and the total, one tap to '
        'see them again; hiding persists', (tester) async {
      await tester.runAsync(() async {
        for (final id in [pepeId, fakeFomoId]) {
          await BeamHiddenAssets.setHidden(
            info: wallet.info,
            isar: isar,
            assetId: id,
            hidden: true,
          );
        }
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          for (final id in [pepeId, fakeFomoId]) {
            await BeamHiddenAssets.setHidden(
              info: wallet.info,
              isar: isar,
              assetId: id,
              hidden: false,
            );
          }
        });
      });
      await pumpAssets(
        tester,
        MyTokensView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
      );
      expect(find.byKey(const Key('beamAssetRow_$pepeId')), findsNothing);
      expect(find.byKey(const Key('beamAssetRow_$fakeFomoId')), findsNothing);
      expect(find.textContaining('no price'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('beamAssetsShowHidden')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(
        find.text('Show 2 hidden assets', findRichText: true),
        findsOneWidget,
      );
      await _golden('assets_hidden_phone');

      await tester.tap(find.byKey(const Key('beamAssetsShowHidden')));
      await tester.pumpAndSettle();
      expect(find.text('Show or hide assets'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('beamAssetRow_$fakeFomoId')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await _golden('assets_manage_phone');

      // In this mode a tap shows the asset again (written to the wallet).
      Opacity pepeOpacity() => tester.widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const Key('beamAssetRow_$pepeId')),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(pepeOpacity().opacity, 0.5);
      await tester.tap(find.byKey(const Key('beamAssetRow_$pepeId')));
      // The write and the wallet-info watcher run on real I/O.
      for (var i = 0; i < 80 && pepeOpacity().opacity != 1; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      expect(BeamHiddenAssets.read(wallet.info), {fakeFomoId});
      expect(pepeOpacity().opacity, 1);
    });

    testWidgets('no assets: what to do, with one tap to the address', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        MyTokensView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        totals: {0: wallet.info.beamAssetTotals[0]!},
      );
      expect(find.text('No assets yet'), findsOneWidget);
      expect(find.byKey(const Key('beamAssetsReceive')), findsOneWidget);
      expect(find.byKey(const Key('beamAssetsManageButton')), findsNothing);
      // Not the empty history's sticker: on desktop the two sit side by
      // side.
      expect(_emptySticker(tester), BeamMoments.emptyAssets);
      expect(BeamMoments.emptyAssets, isNot(BeamMoments.emptyHistory));
      await _golden('assets_empty_phone');
    });

    testWidgets('no assets during a restore scan: they are on their way', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        MyTokensView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        totals: {0: wallet.info.beamAssetTotals[0]!},
        coinScan: (percent: 43),
      );
      expect(find.text('No assets yet'), findsNothing);
      expect(find.text('Still looking for your assets'), findsOneWidget);
      expect(
        textOf(tester, const Key('beamAssetsEmptyDetail')),
        'Your assets appear here as your coins are found. You can receive '
        'meanwhile.',
      );
      // Still one tap to receive.
      final receive = find.byKey(const Key('beamAssetsReceive'));
      expect(receive, findsOneWidget);
      expect(tester.getRect(receive).bottom, lessThanOrEqualTo(phone.height));
      expect(_emptySticker(tester), BeamMoments.emptyAssets);
      await _golden('assets_empty_scanning_phone');
    });
  });

  group('asset page', () {
    testWidgets('phone: FOMO balance, value, history, Receive / Send', (
      tester,
    ) async {
      final fomo = assetWallet(174);
      await pumpAssets(
        tester,
        BeamAssetView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: fomo,
      );
      final balance = Amount(
        rawValue: fixtureAvailable()[174]!,
        fractionDigits: 8,
      );
      expect(
        find.text(
          BeamAssetText.amount(balance, contracts[174]!, locale: 'en_US'),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          BeamAssetText.beamEstimate(
            market.pricer.valueInGroth(174, balance.raw)!,
            locale: 'en_US',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Receive'), findsOneWidget);
      expect(find.byKey(const Key('beamAssetNoTransactions')), findsNothing);
      // The bridge does not carry FOMO.
      expect(find.byKey(const Key('beamAssetBridgeButton')), findsNothing);
      await _golden('asset_page_fomo_phone');
    });

    testWidgets('phone: a bridged asset (bETH) offers Bridge beside Send', (
      tester,
    ) async {
      BridgeSides.debugAvailable = true;
      addTearDown(() => BridgeSides.debugAvailable = null);
      final beth = BeamAssetWallet.load(
        parent: wallet,
        asset: BeamAssetContract(
          address: 'beamAsset:36',
          assetId: 36,
          name: 'bETH',
          symbol: 'bETH',
          decimals: 8,
          verified: true,
          metadataKnown: true,
        ),
      );
      await pumpAssets(
        tester,
        BeamAssetView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: beth,
      );
      expect(find.byKey(const Key('beamAssetBridgeButton')), findsOneWidget);
      expect(find.text('Bridge'), findsOneWidget);
      await _golden('asset_page_beth_phone');
    });

    testWidgets('phone: a copycat says so under its balance; no price', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        BeamAssetView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: assetWallet(fakeFomoId),
      );
      expect(
        find.textContaining('Not the verified FOMO (#174)'),
        findsOneWidget,
      );
      expect(find.text('FOMO #$fakeFomoId'), findsOneWidget);
      expect(find.text(BeamAssetText.noPrice), findsOneWidget);
      expect(find.byKey(const Key('beamAssetNoTransactions')), findsOneWidget);
      await _golden('asset_page_copycat_phone');
    });

    testWidgets('phone: a pool share names its pool', (tester) async {
      await pumpAssets(
        tester,
        BeamAssetView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: assetWallet(175),
      );
      expect(
        find.text('Your share of the BEAM/FOMO pool (1% fee)'),
        findsOneWidget,
      );
      expect(find.text('BEAM/FOMO LP'), findsOneWidget);
      await _golden('asset_page_lp_phone');
    });

    testWidgets('desktop: summary, Send / Receive tabs, history', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        BeamDesktopAssetView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: true,
        market: market,
        assetWallet: assetWallet(174),
      );
      expect(find.byKey(const Key('beamAssetSendReview')), findsOneWidget);
      await _golden('asset_page_fomo_desktop');
    });

    testWidgets('receive: the BEAM address, its QR and a copy button', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        BeamAssetReceiveView(walletId: wallet.walletId, asset: contracts[174]),
        wallet: wallet,
        desktop: false,
      );
      expect(find.text(testOwnAddress), findsOneWidget);
      expect(find.text(BeamAssetText.receiveLine('FOMO')), findsOneWidget);
      await _golden('asset_receive_phone');
    });
  });

  group('send', () {
    testWidgets('phone form: the BEAM fee is stated before anything is '
        'typed; too much is caught on the spot', (tester) async {
      await pumpAssets(
        tester,
        BeamAssetSendView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: assetWallet(174),
      );
      expect(
        find.text('Network fee: 0.001 BEAM, paid in BEAM'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('beamAssetSendAddress')),
        vectorAddress('regular'),
      );
      await tester.enterText(
        find.byKey(const Key('beamAssetSendAmount')),
        '12.5',
      );
      await tester.pumpAndSettle();
      await _golden('asset_send_phone');

      await tester.enterText(
        find.byKey(const Key('beamAssetSendAmount')),
        '9999999',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('More than you have'), findsOneWidget);
    });

    testWidgets('phone form: no BEAM for the fee says how much to add and '
        'offers to receive BEAM', (tester) async {
      final totals = Map.of(wallet.info.beamAssetTotals);
      totals[0] = BeamCachedAssetTotals(
        assetId: 0,
        available: BigInt.zero,
        receiving: BigInt.zero,
        sending: BigInt.zero,
        maturing: BigInt.zero,
        change: BigInt.zero,
      );
      await pumpAssets(
        tester,
        BeamAssetSendView(walletId: wallet.walletId),
        wallet: wallet,
        desktop: false,
        market: market,
        assetWallet: assetWallet(174),
        totals: totals,
      );
      expect(find.byKey(const Key('beamAssetSendNoBeam')), findsOneWidget);
      expect(
        find.textContaining('Add at least 0.001 BEAM first.'),
        findsOneWidget,
      );
      expect(find.text('Receive BEAM', findRichText: true), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('beamAssetSendReview')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await _golden('asset_send_no_beam_phone');
    });

    testWidgets('phone confirm: asset, amount, BEAM fee, destination, how '
        'it arrives; nothing moves without the PIN', (tester) async {
      var asked = 0;
      await pumpAssets(
        tester,
        BeamAssetConfirmView(
          walletId: wallet.walletId,
          assetWallet: assetWallet(174),
          txData: fomoTx,
          authorize: (_) async {
            asked++;
            return false;
          },
        ),
        wallet: wallet,
        desktop: false,
      );
      expect(find.text('12.5 FOMO'), findsOneWidget);
      expect(find.text('FOMO · verified'), findsOneWidget);
      expect(find.text(vectorAddress('regular')), findsOneWidget);
      expect(find.text('0.001 BEAM, paid in BEAM'), findsOneWidget);
      expect(find.text('Send 12.5 FOMO'), findsOneWidget);
      await _golden('asset_confirm_phone');

      await tester.tap(find.byKey(const Key('beamAssetConfirmSend')));
      await tester.pumpAndSettle();
      expect(asked, 1);
      expect(h.core.sent, isEmpty);
    });

    testWidgets('phone confirm of a copycat repeats the warning', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        BeamAssetConfirmView(
          walletId: wallet.walletId,
          assetWallet: assetWallet(fakeFomoId),
          txData: copycatTx,
          authorize: (_) async => false,
        ),
        wallet: wallet,
        desktop: false,
      );
      expect(find.text('FOMO #$fakeFomoId · unverified'), findsOneWidget);
      expect(
        find.textContaining('Not the verified FOMO (#174)'),
        findsOneWidget,
      );
      // The number is part of what is sent: amount and button carry it.
      expect(
        textOf(tester, const Key('beamAssetConfirmAmount')),
        '250 FOMO #$fakeFomoId',
      );
      expect(find.text('Send 250 FOMO #$fakeFomoId'), findsOneWidget);
      await _golden('asset_confirm_copycat_phone');
    });

    testWidgets('outcome unknown: says so, never offers Send again, and '
        'leaves for the history (M-6)', (tester) async {
      final unsure = _UnsureAssetWallet(wallet, contracts[174]!);
      bool? result;
      var asked = 0;
      await pumpAssets(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () async {
                  result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => BeamAssetConfirmView(
                        walletId: wallet.walletId,
                        assetWallet: unsure,
                        txData: fomoTx,
                        authorize: (_) async {
                          asked++;
                          return true;
                        },
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
        wallet: wallet,
        desktop: false,
      );
      await tester.tap(find.byKey(const Key('open')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('beamAssetConfirmSend')));
      await tester.pumpAndSettle();
      expect(unsure.confirmCalls, 1);
      expect(find.text('Not sure it was sent'), findsOneWidget);
      expect(find.text('Payment not sent'), findsNothing);
      expect(
        find.textContaining("We couldn't confirm it went out"),
        findsWidgets,
      );
      // Behind the dialog the Send button is already gone for good.
      expect(find.byKey(const Key('beamAssetConfirmSend')), findsNothing);
      expect(find.byKey(const Key('beamAssetConfirmHistory')), findsOneWidget);
      await _golden('asset_confirm_unknown_phone');

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // Back to the asset page (its history), as handed to the wallet.
      expect(find.byType(BeamAssetConfirmView), findsNothing);
      expect(result, isTrue);
      expect(unsure.confirmCalls, 1);
      expect(asked, 1);
    });

    testWidgets('desktop confirm; a failed send says what happened', (
      tester,
    ) async {
      await pumpAssets(
        tester,
        Builder(
          builder: (context) => Material(
            child: Center(
              child: SizedBox(
                width: 580,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: BeamAssetConfirmView(
                    walletId: wallet.walletId,
                    assetWallet: assetWallet(174),
                    txData: fomoTx,
                    authorize: (_) async => true,
                  ),
                ),
              ),
            ),
          ),
        ),
        wallet: wallet,
        desktop: true,
      );
      await _golden('asset_confirm_desktop');

      // Authorised, but the wallet is closed: nothing is sent and the
      // dialog says why, without blaming the user.
      await tester.tap(find.byKey(const Key('beamAssetConfirmSend')));
      await tester.pumpAndSettle();
      expect(find.text('Payment not sent'), findsOneWidget);
      expect(find.textContaining('still connecting'), findsOneWidget);
      expect(h.core.sent, isEmpty);
    });
  });
}
