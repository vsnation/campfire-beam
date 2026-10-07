/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_pool_detail_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_pools_view.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/widgets/beam/dex/dex_deps.dart';

import 'dex_ui_harness.dart';

void main() {
  Future<DexUiFake> openPools(
    WidgetTester tester, {
    Map<int, BigInt>? balances,
    Object? Function()? pools,
    BeamDexFiat? fiat,
  }) async {
    final fake = DexUiFake({
      DexArgs.poolsView(): pools ?? () => recorded('pools_view'),
    });
    final deps = makeDeps(
      fake,
      balances: balances ?? {0: beam('12.5'), 175: beam('1')},
      fiat: fiat,
    );
    await pumpDex(tester, BeamDexPoolsView(deps: deps));
    await tester.pump();
    await tester.pump();
    return fake;
  }

  testWidgets('my pools first with my share; then the deepest pools', (
    tester,
  ) async {
    await openPools(tester, fiat: roundUsd);
    expect(find.text('Your pools'), findsOneWidget);
    // 1 of 21,252.57813880 LP tokens.
    expect(
      textOf(tester, const Key('dex-pool-share-175')),
      'Your share of the pool: < 0.01%',
    );
    expect(find.text('All pools · 74'), findsOneWidget);
    // Fee tiers by kind: 0 → 0.05%, 1 → 0.3%, 2 → 1%.
    expect(
      find.descendant(
        of: find.byKey(const Key('dex-pool-0-174-2')),
        matching: find.text('1% fee'),
      ),
      findsOneWidget,
    );
    // Each pool's size, both sides valued by the dashboard's pricer: the
    // BEAM/FOMO pool holds 6,373.04 BEAM and the same worth of FOMO.
    expect(
      textOf(tester, const Key('dex-pool-size-175')),
      'Pool size ≈ 25,492.16 USD',
    );
    // #26 trades only against 1 groth of BEAM: no price, no number.
    expect(
      textOf(tester, const Key('dex-pool-size-85')),
      'Pool size: no price',
    );
    final mine = tester.getRect(find.byKey(const Key('dex-pool-0-174-2')));
    final deepest = tester.getRect(find.byKey(const Key('dex-pool-0-7-2')));
    expect(mine.top, lessThan(deepest.top));
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/pools_mobile.png'),
    );
  });

  testWidgets('without a fiat price the size is in BEAM', (tester) async {
    await openPools(tester);
    expect(
      textOf(tester, const Key('dex-pool-size-175')),
      'Pool size ≈ 12,746.08 BEAM',
    );
  });

  testWidgets('fee tier labels follow the measured kinds', (tester) async {
    await openPools(tester);
    await tester.enterText(find.byKey(const Key('dex-pools-search')), 'tico');
    await tester.pump();
    // BEAM/TICO exists as kind 0 and kind 2.
    expect(
      find.descendant(
        of: find.byKey(const Key('dex-pool-0-9-0')),
        matching: find.text('0.05% fee'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('dex-pool-0-9-2')),
        matching: find.text('1% fee'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('search with no match says what to do', (tester) async {
    await openPools(tester);
    await tester.enterText(find.byKey(const Key('dex-pools-search')), 'zzz');
    await tester.pump();
    expect(find.byKey(const Key('dex-pools-no-match')), findsOneWidget);
    expect(find.text('No pool matches "zzz"'), findsOneWidget);
  });

  testWidgets('no pools at all: one tap to create the first', (tester) async {
    await openPools(
      tester,
      pools: () => {
        'output': '{"res": []}',
        'txid': '00000000000000000000000000000000',
      },
    );
    expect(find.byKey(const Key('dex-pools-empty')), findsOneWidget);
    expect(find.byKey(const Key('dex-pools-empty-create')), findsOneWidget);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/pools_mobile_empty.png'),
    );
  });

  testWidgets('pools failed to load: not the user\'s fault, retry', (
    tester,
  ) async {
    var fail = true;
    await openPools(
      tester,
      pools: () => fail
          ? throw const BeamRpcException(-32603, 'Internal JSON-RPC error.')
          : recorded('pools_view'),
    );
    expect(find.byKey(const Key('dex-pools-error')), findsOneWidget);
    expect(find.textContaining('not something you did'), findsOneWidget);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/pools_mobile_error.png'),
    );
    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dex-pools-error')), findsNothing);
    expect(find.text('Your pools'), findsOneWidget);
  });

  testWidgets('tapping a pool opens it', (tester) async {
    await openPools(tester);
    await tester.tap(find.byKey(const Key('dex-pool-0-174-2')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexPoolDetailView), findsOneWidget);
    expect(find.text('BEAM/FOMO pool'), findsOneWidget);
  });
}
