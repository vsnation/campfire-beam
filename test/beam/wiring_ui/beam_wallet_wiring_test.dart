/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamWalletWiring over a REAL BeamWallet (fake host on FakeTransport, real
// Isar): one instance per wallet, sync and balances that follow the wallet,
// and the airdrop service's voucher store being the app's secure one no
// matter which screen created the wallet's services first.
//
//   scripts/beam/host_test.sh --no-analyze test/beam/wiring_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/airdrop/beam_claim_voucher_view.dart';
import 'package:stackwallet/route_generator.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/secure_voucher_code_store.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/voucher_code_store.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_source.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_wallet_listenables.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'wiring_harness.dart';

/// A store that is not the app's: must never replace the secure one.
class _MemoryStore implements VoucherCodeStore {
  @override
  Future<List<AirdropSavedBatch>> all() async => const [];

  @override
  Future<void> delete(String localId) async {}

  @override
  Future<void> put(AirdropSavedBatch batch) async {}
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('one wiring per wallet; sync and balances follow the wallet', (
    tester,
  ) async {
    final core = WiringCore();
    final wallet = await openBeamWallet(tester, db, core: core);
    final w = BeamWalletWiring.of(wallet);

    expect(identical(BeamWalletWiring.of(wallet), w), isTrue);
    expect(identical(w.dex, BeamWalletWiring.of(wallet).dex), isTrue);
    expect(identical(w.names, BeamWalletWiring.of(wallet).names), isTrue);
    expect(identical(w.services, BeamWalletServices.of(wallet)), isTrue);

    expect(w.sync.value, isA<BeamSynced>());
    expect(w.sync.value.canSpend, isTrue);
    expect(w.balances.value[0]!.available, g(12.5));
    expect(w.balances.value[174]!.available, g(1000));
    expect(w.dex.available(0), g(12.5));
    expect(w.names.available(174), g(1000));
    expect(w.dex.canSpend, isTrue);

    // A new wallet_status reaches the listenable through Campfire's cache.
    var notified = 0;
    w.balances.addListener(() => notified++);
    core.status = statusJson(
      height: kTip,
      available: g(7.25),
      extraTotals: [totalsJson(174, available: g(1000))],
    );
    await tester.runAsync(wallet.updateBalance);
    // Isar's change events reach the listener in the test's zone on a pump.
    for (var i = 0; i < 100; i++) {
      if (w.balances.value[0]!.available == g(7.25)) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(w.balances.value[0]!.available, g(7.25));
    expect(w.dex.available(0), g(7.25));
    expect(notified, greaterThan(0));
    await finish(tester);
  });

  testWidgets('a wallet behind the network: the listenable says so', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db, explorerHeight: kTip + 42);
    final w = BeamWalletWiring.of(wallet);
    expect(w.sync.value.canSpend, isFalse);
    expect(w.sync.value, isA<BeamSyncCatchingUp>());
    expect((w.sync.value as BeamSyncCatchingUp).blocksBehind, 42);
    expect(w.dex.canSpend, isFalse);
    expect(w.names.canSpend, isFalse);
    await finish(tester);
  });

  group('the airdrop voucher store is the secure one', () {
    testWidgets('when the wallet home created the services first', (
      tester,
    ) async {
      final wallet = await openBeamWallet(tester, db);
      // The wallet home is always first: it builds the services, no store.
      final home = BeamWalletHomeSource(wallet);
      expect(home.services.voucherStore, isNull);
      // Something even read the airdrop service before any store existed.
      final early = home.services.airdrop;
      expect(early.store, isNull);

      final w = BeamWalletWiring.of(wallet);
      expect(w.airdrop.store, isA<SecureVoucherCodeStore>());
      expect(
        (w.airdrop.store! as SecureVoucherCodeStore).walletId,
        wallet.walletId,
      );
      expect(identical(home.services.airdrop, w.airdrop), isTrue);
      expect(home.services.voucherStore, isA<SecureVoucherCodeStore>());
      await finish(tester);
    });

    testWidgets('when an airdrop screen opened first (its route)', (
      tester,
    ) async {
      final wallet = await openBeamWallet(tester, db);
      final route = RouteGenerator.generateRoute(
        RouteSettings(name: BeamClaimVoucherView.routeName, arguments: wallet),
      );
      expect(route, isA<MaterialPageRoute<dynamic>>());
      await tester.pumpWidget(const SizedBox());
      final page = (route as MaterialPageRoute<dynamic>).builder(
        tester.element(find.byType(SizedBox)),
      );
      expect(page, isA<BeamClaimVoucherView>());
      expect(
        (page as BeamClaimVoucherView).service.store,
        isA<SecureVoucherCodeStore>(),
      );
      // The home comes later and gets the same services, store included.
      final home = BeamWalletHomeSource(wallet);
      expect(home.services.voucherStore, isA<SecureVoucherCodeStore>());
      expect(identical(home.services.airdrop, page.service), isTrue);
      await finish(tester);
    });

    testWidgets('a later, different store never replaces it', (tester) async {
      final wallet = await openBeamWallet(tester, db);
      final w = BeamWalletWiring.of(wallet);
      final secure = w.airdrop.store;
      final services = BeamWalletServices.of(
        wallet,
        voucherStore: _MemoryStore(),
      );
      expect(identical(services.voucherStore, secure), isTrue);
      expect(identical(services.airdrop.store, secure), isTrue);
      await finish(tester);
    });
  });
}
