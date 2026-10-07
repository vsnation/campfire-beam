/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The owner's report from the DMG test: Create a pool → "Second asset"
// listed "#2 / Not verified · Asset #2", "#3", "#8"…, although every asset
// has an on-chain name. Only assets the wallet held were ever looked up.
// Now the DEX names every asset it lists from the explorer's /assets table
// (BeamAssetDirectory), still marked "Not verified" with their #id, and the
// pickers say what a holding is worth.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_create_pool_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_pools_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_swap_view.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_directory.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';

import 'dex_ui_harness.dart';

/// The trimmed real /assets table (test/beam/sync/fixtures).
Map<int, String> _explorerAssets() => BeamExplorerClient.decodeAssetTable(
  jsonDecode(
    File('test/beam/sync/fixtures/explorer_assets.json').readAsStringSync(),
  ),
);

void main() {
  Future<BeamAssetDirectory> openCreate(
    WidgetTester tester, {
    bool namesFirst = true,
  }) async {
    final names = BeamAssetDirectory(readTable: () async => _explorerAssets());
    if (namesFirst) await names.ensure();
    final fake = DexUiFake({DexArgs.poolsView(): () => recorded('pools_view')});
    final deps = makeDeps(
      fake,
      // 3 FOMO and 50 BB held; BB's pool holds 2,089 BEAM, so it has a
      // price (what that pool would pay for it).
      balances: {0: beam('12.5'), 174: beam('3'), 3: beam('50')},
      metadataOf: names.metadataOf,
      assetNames: names,
      fiat: roundUsd,
    );
    await pumpDex(tester, BeamDexCreatePoolView(deps: deps));
    await tester.pump();
    await tester.pump();
    return names;
  }

  Future<void> openSecondAsset(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dex-create-asset-b')));
    await tester.pumpAndSettle();
  }

  Finder option(int id) => find.byKey(Key('dex-asset-option-$id'));

  testWidgets('Create a pool → Second asset: every asset by its name', (
    tester,
  ) async {
    await openCreate(tester);
    await openSecondAsset(tester);

    // Unverified: the on-chain ticker with its #id, "Not verified" and the
    // on-chain name. Never "Asset #2".
    for (final (id, title, subtitle) in [
      (2, 'RAYS #2', 'Not verified · RAYS'),
      (3, 'BB #3', 'Not verified · BeamBots Token'),
      (8, 'POUND #8', 'Not verified · POUND'),
    ]) {
      expect(
        find.descendant(of: option(id), matching: find.text(title)),
        findsOneWidget,
        reason: '#$id',
      );
      expect(
        find.descendant(of: option(id), matching: find.text(subtitle)),
        findsOneWidget,
        reason: '#$id',
      );
    }
    expect(find.text('Not verified · Asset #2'), findsNothing);
    // Verified assets keep Campfire's names.
    expect(
      find.descendant(of: option(4), matching: find.text('Gothic Crown')),
      findsOneWidget,
    );

    // Holdings say what they are worth; BB at what its pool would pay.
    expect(textOf(tester, const Key('dex-asset-worth-0')), '≈ 25.00 USD');
    expect(textOf(tester, const Key('dex-asset-worth-3')), '≈ 0.98 USD');
    expect(textOf(tester, const Key('dex-asset-sold-3')), 'if sold now');
    expect(find.byKey(const Key('dex-asset-sold-0')), findsNothing);

    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/create_pool_picker_mobile.png'),
    );

    // Search finds them by name.
    await tester.enterText(
      find.byKey(const Key('dex-asset-search')),
      'beambots',
    );
    await tester.pump();
    expect(option(3), findsOneWidget);
    expect(option(2), findsNothing);

    // Choosing one shows its name on the form.
    await tester.enterText(find.byKey(const Key('dex-asset-search')), '');
    await tester.pump();
    await tester.tap(option(2));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('dex-create-asset-b')),
        matching: find.text('RAYS #2'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('names that arrive while the list is open appear in it', (
    tester,
  ) async {
    final names = await openCreate(tester, namesFirst: false);
    await openSecondAsset(tester);
    expect(
      find.descendant(of: option(2), matching: find.text('#2')),
      findsOneWidget,
    );

    await names.ensure();
    await tester.pump();
    expect(
      find.descendant(of: option(2), matching: find.text('RAYS #2')),
      findsOneWidget,
    );
  });

  testWidgets('pools list and swap picker read the same names', (tester) async {
    final names = BeamAssetDirectory(readTable: () async => _explorerAssets());
    await names.ensure();
    final fake = DexUiFake({DexArgs.poolsView(): () => recorded('pools_view')});
    final deps = makeDeps(
      fake,
      balances: {0: beam('12.5')},
      metadataOf: names.metadataOf,
      assetNames: names,
    );
    await pumpDex(tester, BeamDexPoolsView(deps: deps));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('dex-pools-search')), 'rays');
    await tester.pump();
    expect(find.byKey(const Key('dex-pool-0-2-2')), findsOneWidget);
    expect(find.text('BEAM / RAYS #2'), findsOneWidget);

    await pumpDex(tester, BeamDexSwapView(deps: deps));
    await tester.pump();
    await tester.tap(find.byKey(const Key('dex-receive-asset')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dex-asset-search')), 'rays');
    await tester.pump();
    expect(
      find.descendant(of: option(2), matching: find.text('RAYS #2')),
      findsOneWidget,
    );
    // A copy of FOMO is never shown as FOMO: it has no pool here, but a
    // name it borrows is flagged wherever it appears (BeamAssetCatalog).
    expect(names.metadataOf(999)!.name, 'FOMO');
  });
}
