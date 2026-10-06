/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The asset picker of the airdrop and burn screens: assets the user hid
// are left out, and verified assets list first, so spam with a low id
// never sits above FOMO (L-14).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';

import 'beam_ui_harness.dart';

void main() {
  final one = BigInt.from(100000000);
  // #150: an asset anyone could mint, with an id below FOMO's (#174).
  // #999: spam the user hid.
  final held = [
    BeamHeldAsset(999, one),
    BeamHeldAsset(174, one),
    BeamHeldAsset(150, one),
    BeamHeldAsset(7, one),
  ];
  BeamAssetNames names() => BeamAssetNames(hiddenAssetIds: () => {999, 0});

  test('hidden assets left out; verified first, then the rest by id', () {
    expect(
      [for (final a in beamPickerOrder(held, names())) a.assetId],
      [7, 174, 150],
    );
    // BEAM is never hidden, even if a stale list says so.
    expect(
      [
        for (final a in beamPickerOrder([BeamHeldAsset(0, one)], names()))
          a.assetId,
      ],
      [0],
    );
    // Without a hidden list nothing is left out.
    expect(beamPickerOrder(held, BeamAssetNames()), hasLength(4));
  });

  testWidgets('the picker says how many hidden assets it left out', (
    tester,
  ) async {
    final n = names()
      ..remember(150, 'STD:SCH_VER=1;N=Aardvark;UN=AARD')
      ..remember(999, 'STD:SCH_VER=1;N=Free Money;UN=FREE');
    await pumpBeamPage(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () => showBeamAssetPicker(
                context: context,
                assets: held,
                names: n,
                title: 'What to give away',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await settle(tester);
    expect(find.byKey(const ValueKey('beam-asset-option-999')), findsNothing);
    final fomo = tester.getTopLeft(
      find.byKey(const ValueKey('beam-asset-option-174')),
    );
    final aardvark = tester.getTopLeft(
      find.byKey(const ValueKey('beam-asset-option-150')),
    );
    expect(fomo.dy, lessThan(aardvark.dy));
    expect(
      find.text(
        '1 asset you hid is not listed. Show it again from the asset list.',
      ),
      findsOneWidget,
    );
  });
}
