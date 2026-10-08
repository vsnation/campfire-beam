/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Split coins (B-UTXO-1): the screen and its review, phone (375 x 667) and
// desktop (1280 x 800), over a scripted backend. The wallet side (tx_split,
// the gate, sync, a dropped connection) is tested in beam_wallet_test.dart.
//
//   scripts/beam/host_test.sh --copy-goldens --update-goldens \
//       test/beam/split_ui                         (write the goldens)

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/split/beam_split_confirm_view.dart';
import 'package:stackwallet/pages/beam/split/beam_split_view.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_lp_tokens.dart';
import 'package:stackwallet/wallets/beam/models/beam_utxo.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coin_split.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coins.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';
import 'package:stackwallet/widgets/beam/split/beam_split_backend.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import '../airdrop_ui/beam_ui_harness.dart';

const _phone = Size(375, 667);

BigInt _g(num beam) => BigInt.from((beam * 100000000).round());

Map<int, BeamCoinSummary> _coins(List<(int, num)> coins) => BeamCoinSummary.of([
  for (final (i, (aid, amount)) in coins.indexed)
    BeamUtxo(
      id: 'c$i',
      assetId: aid,
      amount: _g(amount),
      type: 'norm',
      statusCode: 1,
      statusString: 'available',
    ),
]);

class FakeSplitBackend implements BeamSplitBackend {
  FakeSplitBackend(this.coinsNow, {BeamSyncAssessment? sync})
    : syncNow = ValueNotifier(sync ?? synced());

  Map<int, BeamCoinSummary> coinsNow;
  final ValueNotifier<BeamSyncAssessment> syncNow;
  final changes = ValueNotifier<int>(0);
  String? blockedText;
  Object? prepareError;
  final prepared = <BeamSplitPlan>[];
  final confirmed = <BeamPreparedSplit>[];
  int discarded = 0;

  @override
  final names = BeamAssetNames();

  int receiveOpened = 0;

  @override
  VoidCallback get addFunds =>
      () => receiveOpened++;

  @override
  ValueListenable<BeamSyncAssessment> get sync => syncNow;

  @override
  Listenable get coinsChanged => changes;

  @override
  Future<Map<int, BeamCoinSummary>> coins() async => coinsNow;

  @override
  bool isPoolShare(int assetId) => beamIsPoolShare(assetId);

  @override
  String? get blocked => blockedText;

  @override
  Future<BeamPreparedSplit> prepare(BeamSplitPlan plan) async {
    final e = prepareError;
    if (e != null) throw e;
    prepared.add(plan);
    return BeamPreparedSplit(
      plan: plan,
      before: coinsNow[plan.assetId] ?? BeamCoinSummary.empty(plan.assetId),
      beamAvailable: coinsNow[0]?.availableTotal ?? BigInt.zero,
      onDiscard: () => discarded++,
    );
  }

  @override
  Future<String> confirm(BeamPreparedSplit split) async {
    confirmed.add(split);
    split.handedOff = 'fe' * 16;
    split.discard();
    return 'fe' * 16;
  }
}

Finder _key(String k) => find.byKey(ValueKey(k));

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PrimaryButton>(_key(key)).enabled;

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

Future<FakeSplitBackend> _open(
  WidgetTester tester, {
  FakeSplitBackend? backend,
  bool desktop = false,
  FakeAuth? auth,
}) async {
  final b = backend ?? FakeSplitBackend(_coins([(0, 45.2)]));
  await pumpBeamPage(
    tester,
    BeamSplitView(backend: b, authorize: (auth ?? FakeAuth()).authorizer),
    desktop: desktop,
    size: desktop ? desktopSize : _phone,
  );
  await tester.pumpAndSettle();
  return b;
}

void main() {
  tearDown(BeamLpTokens.clear);

  testWidgets('phone 375 x 667: the gain first, the coins now, the advised '
      'count, what you will have, and the button in view', (tester) async {
    await _open(tester);

    expect(find.text('Send several payments at once'), findsOneWidget);
    expect(find.textContaining('Nothing leaves your wallet'), findsOneWidget);
    expect(
      find.text('45.2 BEAM in 1 coin: one payment at a time'),
      findsOneWidget,
    );
    expect(find.textContaining('All your BEAM is in one coin'), findsOneWidget);
    // 45.2 BEAM: one coin per 10 BEAM, so 5 is picked for the user.
    expect(find.text('Split into 5 coins'), findsOneWidget);
    expect(_text(tester, 'split-new-coins'), '5 coins of 8.1 BEAM');
    expect(_text(tester, 'split-change'), '4.69882 BEAM');
    expect(_text(tester, 'split-fee'), '0.00118 BEAM');
    expect(_enabled(tester, 'split-cta'), isTrue);
    final cta = tester.getRect(_key('split-cta'));
    expect(cta.bottom, lessThanOrEqualTo(_phone.height));
    // No technical word for coins anywhere on screen.
    expect(find.textContaining('UTXO'), findsNothing);
    expect(find.textContaining('utxo'), findsNothing);

    await expectScreen(tester, 'split_phone');
  });

  testWidgets('desktop 1280 x 800', (tester) async {
    await _open(
      tester,
      desktop: true,
      backend: FakeSplitBackend(_coins([(0, 45.2), (0, 0.3)])),
    );
    expect(
      find.text('45.5 BEAM in 2 coins; the largest holds 99%'),
      findsOneWidget,
    );
    expect(find.textContaining('Most of your BEAM'), findsOneWidget);
    expect(find.text('Split into 4 coins'), findsOneWidget);
    await expectScreen(tester, 'split_desktop');
  });

  testWidgets('another count, the review, the PIN, then what happens next', (
    tester,
  ) async {
    final auth = FakeAuth();
    final b = await _open(tester, auth: auth);

    await tester.tap(_key('split-count-8'));
    await tester.pumpAndSettle();
    expect(find.text('Split into 8 coins'), findsOneWidget);
    expect(_text(tester, 'split-new-coins'), '8 coins of 5 BEAM');

    await tester.tap(_key('split-cta'));
    await tester.pumpAndSettle();
    expect(b.prepared.single.count, 8);
    expect(find.byType(BeamSplitConfirmView), findsOneWidget);
    expect(find.text('Nothing leaves your wallet'), findsOneWidget);
    expect(_text(tester, 'split-review-now'), '45.2 BEAM in 1 coin');
    expect(_text(tester, 'split-review-new'), '8 coins of 5 BEAM');
    expect(_text(tester, 'split-review-fee'), '0.00172 BEAM');
    expect(_text(tester, 'split-review-leaves'), '0.00172 BEAM');
    expect(b.confirmed, isEmpty, reason: 'nothing signed yet');
    await expectScreen(tester, 'split_review_phone');

    await tester.tap(_key('split-confirm-cta'));
    await tester.pumpAndSettle();
    expect(auth.reasons, ['Split 40 BEAM into 8 coins']);
    expect(b.confirmed, hasLength(1));
    expect(find.text('Splitting into 8 coins'), findsOneWidget);
    expect(find.textContaining('ready in about a minute'), findsOneWidget);
    await expectScreen(tester, 'split_done_phone');
  });

  testWidgets('a wrong PIN signs nothing; backing out of the review lets the '
      'node switch go', (tester) async {
    final auth = FakeAuth(answer: false);
    final b = await _open(tester, auth: auth);
    await tester.tap(_key('split-cta'));
    await tester.pumpAndSettle();
    await tester.tap(_key('split-confirm-cta'));
    await tester.pumpAndSettle();
    expect(b.confirmed, isEmpty);
    expect(find.byType(BeamSplitConfirmView), findsOneWidget);

    Navigator.of(tester.element(find.byType(BeamSplitConfirmView))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(BeamSplitConfirmView), findsNothing);
    expect(b.discarded, greaterThanOrEqualTo(1));
    expect(b.confirmed, isEmpty);
  });

  testWidgets('another payment still open: the button waits and says why, '
      'then comes back by itself', (tester) async {
    final b = FakeSplitBackend(_coins([(0, 45.2)]))
      ..blockedText =
          'A swap is still being confirmed. Splitting turns back on by '
          'itself once it is done, usually within a few minutes.';
    await _open(tester, backend: b);
    expect(_key('split-blocked'), findsOneWidget);
    expect(_enabled(tester, 'split-cta'), isFalse);
    await expectScreen(tester, 'split_waiting_phone');

    b.blockedText = null;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(_key('split-blocked'), findsNothing);
    expect(_enabled(tester, 'split-cta'), isTrue);
  });

  testWidgets('not up to date: splitting waits for the wallet', (tester) async {
    await _open(
      tester,
      backend: FakeSplitBackend(_coins([(0, 45.2)]), sync: catchingUp()),
    );
    expect(_key('beam-sync-notice'), findsOneWidget);
    expect(
      find.textContaining('Splitting turns back on by itself'),
      findsOneWidget,
    );
    expect(_enabled(tester, 'split-cta'), isFalse);
  });

  testWidgets('assets: pool shares are never offered; an asset split needs '
      'BEAM for its fee', (tester) async {
    BeamLpTokens.learn(
      const BeamLpPool(lpToken: 9175, aid1: 0, aid2: 174, kind: 2),
    );
    final b = await _open(
      tester,
      backend: FakeSplitBackend(_coins([(0, 0.0005), (174, 25), (9175, 3)])),
    );
    await tester.tap(_key('split-asset'));
    await tester.pumpAndSettle();
    expect(_key('beam-asset-option-0'), findsOneWidget);
    expect(_key('beam-asset-option-174'), findsOneWidget);
    expect(_key('beam-asset-option-9175'), findsNothing);

    await tester.tap(_key('beam-asset-option-174'));
    await tester.pumpAndSettle();
    expect(find.textContaining('paid in BEAM'), findsOneWidget);
    expect(_enabled(tester, 'split-cta'), isFalse);
    expect(b.prepared, isEmpty);
    await tester.tap(find.text('Receive BEAM'));
    expect(b.receiveOpened, 1, reason: 'never a dead end');
  });

  testWidgets('nothing to split: says why and what fills it', (tester) async {
    await _open(tester, backend: FakeSplitBackend(_coins([(0, 0.002)])));
    expect(find.textContaining('too little here to split'), findsOneWidget);
    expect(_enabled(tester, 'split-cta'), isFalse);
  });

  testWidgets('no coins at all: says what fills it, one tap away', (
    tester,
  ) async {
    final b = await _open(tester, backend: FakeSplitBackend({}));
    await tester.tap(find.text('Receive BEAM'));
    expect(b.receiveOpened, 1);
    expect(find.textContaining('no BEAM it can spend'), findsOneWidget);
    expect(_enabled(tester, 'split-cta'), isFalse);
  });
}
