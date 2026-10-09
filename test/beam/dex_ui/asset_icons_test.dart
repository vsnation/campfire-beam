/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Reported: the DEX pool icons jumped about and looked wrong.
// NPH's logo is a bare triangle, so BEAM/NPH, bUSDT/NPH and bDAI/NPH looked
// broken next to the round logos, and icons popped in as they loaded.
//
// Every asset icon is the same coin: the same diameter, clipped to a
// circle, a neutral disc behind a logo that is not round itself, a box of
// fixed size from the first frame, and a fresh picture (never the last
// asset's) when a row is reused.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/widgets/beam/assets/beam_asset_logo.dart';
import 'package:stackwallet/widgets/beam/dex/dex_asset_icon.dart';

import 'dex_ui_harness.dart';

/// Every verified asset, an unverified one, an unknown id, and LP tokens:
/// BEAM/FOMO, BEAM/NPH, bUSDT/NPH and an LP-of-LP pool (BEAM / BEAM/NPH LP).
const _assetIds = [0, 4, 6, 7, 9, 36, 37, 38, 39, 47, 174, 186, 187, 3];
const _lpIds = [175, 60, 73, 67];

/// The pairs from that report, and a few more.
const _pairs = [
  (0, 47),
  (0, 36),
  (0, 37),
  (0, 39),
  (37, 47),
  (39, 47),
  (7, 47),
  (0, 174),
  (9, 47),
  (0, 186),
];

Widget _sheet() {
  BeamAssetDisplay d(int id) => BeamAssetCatalog.display(id, null);
  return Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in [..._assetIds, ..._lpIds])
                BeamAssetLogo(d(id), key: Key('logo-$id'), size: 28),
              const BeamAssetLogo.missing(key: Key('logo-missing'), size: 28),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (a, b) in _pairs)
                Container(
                  width: 163,
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      DexPairIcon(
                        key: Key('pair-$a-$b'),
                        first: d(a),
                        second: d(b),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${d(a).label}/${d(b).label}',
                          style: const TextStyle(fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(() => BeamAssetMarket(recordedPools()));

  List<Size> logoSizes(WidgetTester tester) => [
    for (final id in [..._assetIds, ..._lpIds, 'missing'])
      tester.getSize(find.byKey(Key('logo-$id'))),
  ];

  List<Size> pairSizes(WidgetTester tester) => [
    for (final (a, b) in _pairs) tester.getSize(find.byKey(Key('pair-$a-$b'))),
  ];

  testWidgets('every icon is the same size before and after its picture '
      'loads', (tester) async {
    await pumpDex(tester, _sheet());
    // First frame: nothing has loaded yet.
    final before = logoSizes(tester);
    final pairsBefore = pairSizes(tester);
    await settleImages(tester);
    expect(logoSizes(tester), before);
    expect(pairSizes(tester), pairsBefore);
    expect(before.toSet(), {const Size(28, 28)});
    // A pair is two 28 px coins in a 44.8 × 28 box: the same for BEAM/NPH
    // as for BEAM/FOMO, and the same as before this change, so no screen
    // moves.
    expect(pairsBefore.toSet(), {const Size(28 * 1.6, 28)});
    // Both coins of every pair are full size.
    for (final (a, b) in _pairs) {
      final coins = find.descendant(
        of: find.byKey(Key('pair-$a-$b')),
        matching: find.byType(BeamAssetCoin),
      );
      expect(coins, findsNWidgets(2));
      for (final e in coins.evaluate()) {
        expect(e.size, const Size(28, 28));
      }
    }

    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/asset_icons_mobile.png'),
    );
  });

  testWidgets('a logo that is not round sits on a neutral disc; round ones '
      'are clipped to their circle', (tester) async {
    await pumpDex(tester, _sheet());
    await settleImages(tester);
    final colors = StackColors.fromStackColorTheme(campfireLight);

    bool onDisc(int id) => find
        .descendant(
          of: find.byKey(Key('logo-$id')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle &&
                (w.decoration as BoxDecoration).color == colors.textSubtitle5,
          ),
        )
        .evaluate()
        .isNotEmpty;

    // NPH's triangle, GIGA's cut-out face, CHAD's white square.
    for (final id in [47, 186, 187]) {
      expect(onDisc(id), isTrue, reason: 'asset $id');
    }
    // Round logos fill their own circle once loaded.
    for (final id in [0, 7, 174, 36, 3]) {
      expect(onDisc(id), isFalse, reason: 'asset $id');
    }
    // Every picture is clipped to a circle.
    for (final id in _assetIds) {
      expect(
        find.descendant(
          of: find.byKey(Key('logo-$id')),
          matching: find.byType(ClipOval),
        ),
        findsOneWidget,
        reason: 'asset $id',
      );
    }
  });

  testWidgets('an LP token shows its pair in the same space', (tester) async {
    await pumpDex(tester, _sheet());
    await settleImages(tester);
    final pair = find.descendant(
      of: find.byKey(const Key('logo-60')),
      matching: find.byType(BeamPairLogo),
    );
    expect(pair, findsOneWidget);
    final coins = find.descendant(
      of: pair,
      matching: find.byType(BeamAssetCoin),
    );
    expect(coins, findsNWidgets(2));
    // Both coins the same size, together inside the 28 px box.
    expect(
      {for (final e in coins.evaluate()) e.size},
      {const Size.square(28 * BeamPairLogo.coinShare)},
    );
    final box = tester.getRect(find.byKey(const Key('logo-60')));
    expect(box.size, const Size(28, 28));
    for (final e in coins.evaluate()) {
      final render = e.renderObject! as RenderBox;
      final r = render.localToGlobal(Offset.zero) & render.size;
      expect(box.intersect(r), r, reason: '$r inside $box');
    }
  });

  testWidgets('a reused icon starts fresh: never the last asset\'s '
      'picture', (tester) async {
    final which = ValueNotifier<int>(3);
    await pumpDex(
      tester,
      Scaffold(
        body: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: which,
            builder: (_, id, _) =>
                BeamAssetLogo(BeamAssetCatalog.display(id, null), size: 28),
          ),
        ),
      ),
    );
    await settleImages(tester);
    final first = tester.element(find.byType(SvgPicture));
    which.value = 0;
    await tester.pump();
    // A new element for the new picture: the SVG state that painted #3 is
    // gone, so the next frame shows the disc, then BEAM.
    final second = tester.element(find.byType(SvgPicture));
    expect(identical(first, second), isFalse);
    expect(tester.getSize(find.byType(BeamAssetLogo)), const Size(28, 28));
  });
}
