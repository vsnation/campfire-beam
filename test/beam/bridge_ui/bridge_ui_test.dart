/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge screens on Campfire's theme, phone (375 × 667) and desktop
// (1280 × 800), over the fake halves (../bridge/bridge_fakes.dart): Move
// empty, priced, frozen, without the BEAM to collect, without an Ethereum
// wallet; the review both ways and its PIN; a crossing waiting for its 61
// blocks and one ready to collect; the history.
//
//   CFB_HOST_WORKDIR=/private/tmp/cfb-h-ui scripts/beam/host_test.sh \
//       --no-analyze --update-goldens --copy-goldens test/beam/bridge_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/bridge/bridge_crossing_view.dart';
import 'package:stackwallet/pages/bridge/bridge_crossings_view.dart';
import 'package:stackwallet/pages/bridge/bridge_deps.dart';
import 'package:stackwallet/pages/bridge/bridge_move_view.dart';
import 'package:stackwallet/pages/bridge/bridge_review_view.dart';
import 'package:stackwallet/pages_desktop_specific/bridge/desktop_bridge_view.dart';
import 'package:stackwallet/wallets/bridge/bridge_controller.dart';
import 'package:stackwallet/wallets/bridge/bridge_crossing.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/bridge/bridge_store.dart';
import 'package:stackwallet/widgets/beam/dex/dex_widgets.dart';

import '../bridge/bridge_fakes.dart';
import '../wiring_ui/wiring_harness.dart';

Finder _k(String key) => find.byKey(Key(key));

String _text(WidgetTester tester, String key) {
  final w = tester.widget(_k(key));
  if (w is Text) return w.data ?? w.textSpan!.toPlainText();
  throw StateError('$key is ${w.runtimeType}');
}

/// Lets the fakes' futures finish and the screen redraw.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

Future<void> _type(WidgetTester tester, String amount) async {
  await tester.enterText(_k('bridge-amount'), amount);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 470));
  await _flush(tester);
}

bool _icons = false;

Future<void> _pump(
  WidgetTester tester,
  Widget w, {
  required bool desktop,
}) async {
  await pumpWiring(tester, w, desktop: desktop);
  if (!_icons) {
    _icons = true;
    await loadMaterialIcons(tester);
    await tester.pump();
  }
  await _flush(tester);
}

Future<void> _golden(String name) =>
    expectLater(find.byKey(goldenKey), matchesGoldenFile('goldens/$name.png'));

/// Counts PIN prompts; answers [answer].
class _Gate {
  bool? answer = true;
  final List<String> reasons = [];

  Future<bool?> call(BuildContext context, {required String reason}) async {
    reasons.add(reason);
    return answer;
  }
}

class _Rig {
  _Rig({FakeBeamSide? beam, FakeEthSide? eth, this.withEth = true})
    : beam = beam ?? FakeBeamSide(),
      eth = eth ?? FakeEthSide() {
    this.eth.clock = clock;
  }

  final FakeBridgeClock clock = FakeBridgeClock();
  final FakeBeamSide beam;
  final FakeEthSide eth;
  final MemoryBridgeStore store = MemoryBridgeStore();
  final _Gate gate = _Gate();
  final bool withEth;

  late final BridgeController controller = BridgeController(
    beam: beam,
    eth: eth,
    store: store,
    beamWalletId: 'beam-wallet',
    ethWalletId: 'eth-wallet',
    clock: clock,
    autoPoll: false,
  );

  BridgeDeps deps({required bool desktop}) => BridgeDeps(
    beamWallets: const [BridgeWalletOption(id: 'beam-wallet', name: 'My BEAM')],
    ethWallets: withEth
        ? const [
            BridgeWalletOption(
              id: 'eth-wallet',
              name: 'My Ethereum',
              address: kFakeEthAddress,
            ),
          ]
        : const [],
    controllerFor: (_, _) async {
      await controller.resumeAll();
      return controller;
    },
    authenticate: gate.call,
    ethExplorerTx: (h) => Uri.parse('https://etherscan.io/tx/$h'),
    ethExplorerAddress: (a) => Uri.parse('https://etherscan.io/address/$a'),
    onGetBeam: () {},
    onAddEthereumWallet: () {},
    isDesktop: desktop,
  );

  /// Starts [a] of [r] going [d] through the controller, as Review does.
  Future<BridgeCrossing> start(
    WidgetTester tester,
    BridgeRoute r,
    BridgeDirection d,
    BigInt a,
  ) async {
    late BridgeCrossing x;
    await tester.runAsync(() async {
      final q = await controller.quote(r, d, a);
      x = await controller.start(await controller.prepare(q));
      await pumpEventQueue();
    });
    return controller.crossing(x.id)!;
  }

  Future<BridgeCrossing> poll(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      await controller.poll(id);
      await pumpEventQueue();
    });
    return controller.crossing(id)!;
  }
}

/// A screen opened the way the app opens it (page / dialog) from a button.
Widget _opener(Future<void> Function(BuildContext) open) => Builder(
  builder: (context) => Center(
    child: TextButton(
      key: const Key('open'),
      onPressed: () => open(context),
      child: const Text('open'),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(_k('open'));
  await _flush(tester);
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  // --------------------------------------------------------------- Move

  testWidgets('phone: Move, empty, states the limits before typing', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(
      tester,
      BridgeMoveView(deps: rig.deps(desktop: false)),
      desktop: false,
    );
    expect(_text(tester, 'dex-cta-reason'), 'Enter how much BEAM to move.');
    expect(find.text('Move to Ethereum'), findsOneWidget);
    expect(_text(tester, 'bridge-balance'), 'Balance 5,000 BEAM');
    expect(
      _text(tester, 'bridge-limits'),
      'More than the bridge fee (now 72.5683 BEAM), at most 3,000,000 BEAM '
      'per move.',
    );
    expect(_text(tester, 'bridge-time'), 'About 1 hour');
    expect(find.textContaining('relayer'), findsNothing);
    await _golden('phone_bridge_move_empty');
    await finish(tester);
  });

  testWidgets('phone: Move, priced: what arrives, every fee, the time', (
    tester,
  ) async {
    final rig = _Rig();
    await _pump(
      tester,
      BridgeMoveView(deps: rig.deps(desktop: false)),
      desktop: false,
    );
    await _type(tester, '1000');
    expect(_text(tester, 'bridge-receive'), '1,000 WBEAM');
    expect(_text(tester, 'bridge-fee'), '72.5683 BEAM');
    expect(_text(tester, 'bridge-beam-fee'), '0.011 BEAM');
    expect(find.text('Move 1,000 BEAM to Ethereum'), findsOneWidget);
    expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
    await _golden('phone_bridge_move_quoted');
    await finish(tester);
  });

  testWidgets('phone: Move, a frozen coin says why and blocks', (tester) async {
    final rig = _Rig();
    rig.eth.frozen['usdt'] = const [
      BridgeFreeze("Tether has frozen the bridge's USDT"),
    ];
    await _pump(
      tester,
      BridgeMoveView(deps: rig.deps(desktop: false), initialRoute: usdtRoute),
      desktop: false,
    );
    await _type(tester, '100');
    expect(find.byKey(const Key('bridge-block')), findsOneWidget);
    expect(_text(tester, 'dex-cta-reason'), 'Tether cannot be moved right now');
    await tester.ensureVisible(_k('bridge-block'));
    await tester.pump();
    await _golden('phone_bridge_move_frozen');
    await finish(tester);
  });

  testWidgets('phone: Move to BEAM, no BEAM to collect it: blocked, with '
      'Get BEAM', (tester) async {
    final rig = _Rig(beam: FakeBeamSide(available: {0: beams(0.05)}));
    await _pump(
      tester,
      BridgeMoveView(
        deps: rig.deps(desktop: false),
        initialRoute: usdtRoute,
        initialDirection: BridgeDirection.toBeam,
      ),
      desktop: false,
    );
    expect(
      _text(tester, 'bridge-limits'),
      'Collecting it on BEAM costs 0.121 BEAM from your BEAM wallet.',
    );
    await _type(tester, '100');
    expect(
      _text(tester, 'dex-cta-reason'),
      'Your BEAM wallet needs 0.121 BEAM to collect it',
    );
    expect(find.text('Get BEAM'), findsOneWidget);
    await tester.ensureVisible(_k('bridge-block'));
    await tester.pump();
    await _golden('phone_bridge_move_no_claim_fee');
    await finish(tester);
  });

  testWidgets('phone: no Ethereum wallet: the next step, not a dead end', (
    tester,
  ) async {
    final rig = _Rig(withEth: false);
    await _pump(
      tester,
      BridgeMoveView(deps: rig.deps(desktop: false)),
      desktop: false,
    );
    expect(find.text('Add an Ethereum wallet'), findsOneWidget);
    expect(find.byKey(const Key('bridge-no-wallet')), findsOneWidget);
    await _golden('phone_bridge_no_eth_wallet');
    await finish(tester);
  });

  testWidgets('desktop: the form and the crossings side by side', (
    tester,
  ) async {
    final rig = _Rig();
    final x = await rig.start(
      tester,
      beamRoute,
      BridgeDirection.toEthereum,
      beams(2500),
    );
    rig.beam
      ..mine(x.beamTxId!, 4072810)
      ..tip = 4072837;
    await rig.poll(tester, x.id);
    await _pump(
      tester,
      DesktopBridgeView(deps: rig.deps(desktop: true), now: rig.clock.now),
      desktop: true,
    );
    await _type(tester, '1000');
    expect(find.text('Move 1,000 BEAM to Ethereum'), findsOneWidget);
    expect(_text(tester, 'bridge-row-status-${x.id}'), '34 blocks to go');
    await _golden('desktop_bridge_move');
    await finish(tester);
  });

  testWidgets('desktop: a frozen coin, and no BEAM to collect', (tester) async {
    final rig = _Rig(beam: FakeBeamSide(available: {0: beams(0.05)}));
    rig.eth.frozen['usdt'] = const [
      BridgeFreeze("Tether has frozen the bridge's USDT"),
    ];
    await _pump(
      tester,
      DesktopBridgeView(
        deps: rig.deps(desktop: true),
        initialRoute: usdtRoute,
        now: rig.clock.now,
      ),
      desktop: true,
    );
    expect(find.text('Tether cannot be moved right now'), findsWidgets);
    await _golden('desktop_bridge_move_frozen');
    // To BEAM on WBTC: not frozen, but nothing to collect it with.
    await tester.tap(_k('bridge-route-wbtc'));
    await _flush(tester);
    await tester.tap(find.byKey(const Key('dex-flip')));
    await _flush(tester);
    await _type(tester, '0.0005');
    expect(
      _text(tester, 'dex-cta-reason'),
      'Your BEAM wallet needs 0.121 BEAM to collect it',
    );
    await _golden('desktop_bridge_move_no_claim_fee');
    await finish(tester);
  });

  testWidgets('desktop: no Ethereum wallet', (tester) async {
    final rig = _Rig(withEth: false);
    await _pump(
      tester,
      DesktopBridgeView(deps: rig.deps(desktop: true)),
      desktop: true,
    );
    expect(find.text('Add an Ethereum wallet'), findsOneWidget);
    await _golden('desktop_bridge_no_eth_wallet');
    await finish(tester);
  });

  // ------------------------------------------------------------- Review

  testWidgets('phone: Review to Ethereum, then the PIN starts it', (
    tester,
  ) async {
    final rig = _Rig();
    final deps = rig.deps(desktop: false);
    String? started;
    late BridgePrepared prepared;
    await tester.runAsync(() async {
      await rig.controller.resumeAll();
      prepared = await rig.controller.prepare(
        await rig.controller.quote(
          beamRoute,
          BridgeDirection.toEthereum,
          beams(1000),
        ),
      );
    });
    await _pump(
      tester,
      _opener((c) async {
        started = await BridgeReviewView.show(
          c,
          deps: deps,
          controller: rig.controller,
          prepared: prepared,
        );
      }),
      desktop: false,
    );
    await _open(tester);
    expect(_text(tester, 'bridge-review-receive'), '1,000 WBEAM');
    // 1,000 + the bridge fee (72.57…) + the 0.011 network fee.
    expect(_text(tester, 'bridge-review-total'), startsWith('1,072.5'));
    expect(find.byKey(const Key('bridge-review-public')), findsOneWidget);
    expect(find.byKey(const Key('bridge-review-freeze')), findsOneWidget);
    expect(find.byKey(const Key('bridge-auto-claim')), findsNothing);
    await _golden('phone_bridge_review_to_eth');
    await tester.tap(_k('bridge-review-cta'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await _flush(tester);
    expect(rig.gate.reasons, ['Authenticate to move']);
    expect(started, isNotNull);
    expect(rig.controller.crossing(started!)!.state, BridgeCrossingState.sent);
    await finish(tester);
  });

  testWidgets('phone: Review to BEAM names the approval and offers to '
      'collect automatically', (tester) async {
    final rig = _Rig();
    final deps = rig.deps(desktop: false);
    late BridgePrepared prepared;
    await tester.runAsync(() async {
      prepared = await rig.controller.prepare(
        await rig.controller.quote(
          usdtRoute,
          BridgeDirection.toBeam,
          BigInt.from(100000000),
        ),
      );
    });
    await _pump(
      tester,
      _opener(
        (c) => BridgeReviewView.show(
          c,
          deps: deps,
          controller: rig.controller,
          prepared: prepared,
        ),
      ),
      desktop: false,
    );
    await _open(tester);
    expect(_text(tester, 'bridge-review-receive'), '100 bUSDT');
    expect(find.byKey(const Key('bridge-review-approval')), findsOneWidget);
    expect(find.byKey(const Key('bridge-auto-claim')), findsOneWidget);
    await tester.ensureVisible(_k('bridge-auto-claim'));
    await tester.pump();
    await _golden('phone_bridge_review_to_beam');
    await finish(tester);
  });

  testWidgets('desktop: Review in a dialog', (tester) async {
    final rig = _Rig();
    final deps = rig.deps(desktop: true);
    late BridgePrepared prepared;
    await tester.runAsync(() async {
      prepared = await rig.controller.prepare(
        await rig.controller.quote(
          ethRoute,
          BridgeDirection.toBeam,
          ethUnits(0.01),
        ),
      );
    });
    await _pump(
      tester,
      _opener(
        (c) => BridgeReviewView.show(
          c,
          deps: deps,
          controller: rig.controller,
          prepared: prepared,
        ),
      ),
      desktop: true,
    );
    await _open(tester);
    expect(find.text('Move 0.01 ETH to BEAM'), findsOneWidget);
    await _golden('desktop_bridge_review');
    await finish(tester);
  });

  // ------------------------------------------------------------ Crossing

  Future<void> openCrossing(
    WidgetTester tester,
    _Rig rig,
    String id, {
    required bool desktop,
  }) async {
    final deps = rig.deps(desktop: desktop);
    await _pump(
      tester,
      _opener(
        (c) => showDexPageForTest(
          c,
          deps,
          BridgeCrossingView(
            deps: deps,
            controller: rig.controller,
            id: id,
            now: rig.clock.now,
          ),
        ),
      ),
      desktop: desktop,
    );
    await _open(tester);
  }

  testWidgets('phone: a crossing to Ethereum waiting for its blocks', (
    tester,
  ) async {
    final rig = _Rig();
    var x = await rig.start(
      tester,
      beamRoute,
      BridgeDirection.toEthereum,
      beams(1000),
    );
    rig.beam
      ..mine(x.beamTxId!, 4072810)
      ..tip = 4072837;
    rig.clock.advance(const Duration(minutes: 27));
    x = await rig.poll(tester, x.id);
    expect(x.state, BridgeCrossingState.confirmed);
    await openCrossing(tester, rig, x.id, desktop: false);
    expect(find.text('On its way: 34 BEAM blocks to go'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(_text(tester, 'bridge-crossing-number'), '#1');
    await _golden('phone_bridge_crossing_blocks');
    await finish(tester);
  });

  testWidgets('phone: a crossing to BEAM ready to collect, after the PIN', (
    tester,
  ) async {
    final rig = _Rig();
    var x = await rig.start(
      tester,
      usdtRoute,
      BridgeDirection.toBeam,
      BigInt.from(100000000),
    );
    rig.eth.mineLock(x.lockHash!, msgId: 110);
    rig.beam.deliver(usdtRoute, 110, x.receives);
    rig.clock.advance(const Duration(minutes: 3));
    x = await rig.poll(tester, x.id);
    expect(x.state, BridgeCrossingState.delivered);
    await openCrossing(tester, rig, x.id, desktop: false);
    expect(find.text('Arrived on BEAM: collect it'), findsOneWidget);
    expect(find.text('Collect 100 bUSDT'), findsOneWidget);
    await _golden('phone_bridge_crossing_collect');
    await tester.tap(_k('bridge-crossing-cta'));
    await tester.runAsync(() => pumpEventQueue());
    await _flush(tester);
    expect(rig.gate.reasons, ['Authenticate to collect']);
    expect(rig.controller.crossing(x.id)!.state, BridgeCrossingState.claiming);
    await finish(tester);
  });

  testWidgets('desktop: a crossing to BEAM ready to collect', (tester) async {
    final rig = _Rig();
    var x = await rig.start(
      tester,
      ethRoute,
      BridgeDirection.toBeam,
      ethUnits(0.01),
    );
    rig.eth.mineLock(x.lockHash!, msgId: 0); // Ethereum ids start at 0
    rig.beam.deliver(ethRoute, 0, x.receives);
    rig.clock.advance(const Duration(minutes: 2));
    x = await rig.poll(tester, x.id);
    expect(x.state, BridgeCrossingState.delivered);
    expect(x.msgId, 0);
    await openCrossing(tester, rig, x.id, desktop: true);
    expect(find.text('Collect 0.01 bETH'), findsOneWidget);
    await _golden('desktop_bridge_crossing_collect');
    await finish(tester);
  });

  testWidgets('desktop: a crossing waiting for Ethereum gas', (tester) async {
    final rig = _Rig();
    var x = await rig.start(
      tester,
      usdtRoute,
      BridgeDirection.toEthereum,
      beams(250) - beams(1),
    );
    rig.beam
      ..mine(x.beamTxId!, 4072810)
      ..tip = 4072900;
    x = await rig.poll(tester, x.id);
    rig.clock.advance(const Duration(minutes: 31));
    x = await rig.poll(tester, x.id);
    expect(x.state, BridgeCrossingState.waitingForGas);
    await openCrossing(tester, rig, x.id, desktop: true);
    expect(find.text('Waiting for Ethereum gas to come down'), findsOneWidget);
    await _golden('desktop_bridge_crossing_gas');
    await finish(tester);
  });

  // ------------------------------------------------------------- History

  Future<_Rig> historyRig(WidgetTester tester) async {
    final rig = _Rig();
    // Finished ones first, hours ago.
    final paid = await rig.start(
      tester,
      beamRoute,
      BridgeDirection.toEthereum,
      beams(1500),
    );
    rig.beam
      ..mine(paid.beamTxId!, 4072700)
      ..tip = 4072800;
    rig.eth.paid.add(1);
    await rig.poll(tester, paid.id);
    rig.clock.advance(const Duration(hours: 2));
    final claimed = await rig.start(
      tester,
      ethRoute,
      BridgeDirection.toBeam,
      ethUnits(0.004),
    );
    rig.eth.mineLock(claimed.lockHash!, msgId: 127);
    rig.beam.deliver(ethRoute, 127, claimed.receives);
    await rig.poll(tester, claimed.id);
    await tester.runAsync(() async {
      final p = await rig.controller.prepareClaim(claimed.id);
      final c = await rig.controller.claim(claimed.id, p);
      rig.beam.mine(c.claimTxId!, 4072805);
    });
    await rig.poll(tester, claimed.id);
    rig.clock.advance(const Duration(minutes: 50));
    // Still on their way.
    final waiting = await rig.start(
      tester,
      beamRoute,
      BridgeDirection.toEthereum,
      beams(1000),
    );
    rig.beam
      ..mine(waiting.beamTxId!, 4072810)
      ..tip = 4072837;
    await rig.poll(tester, waiting.id);
    rig.clock.advance(const Duration(minutes: 12));
    final collect = await rig.start(
      tester,
      usdtRoute,
      BridgeDirection.toBeam,
      BigInt.from(100000000),
    );
    rig.eth.mineLock(collect.lockHash!, msgId: 110);
    rig.beam.deliver(usdtRoute, 110, collect.receives);
    rig.clock.advance(const Duration(minutes: 3));
    await rig.poll(tester, collect.id);
    return rig;
  }

  testWidgets('phone: the history, the ones on their way first', (
    tester,
  ) async {
    final rig = await historyRig(tester);
    final deps = rig.deps(desktop: false);
    await _pump(
      tester,
      _opener(
        (c) => showDexPageForTest(
          c,
          deps,
          BridgeCrossingsView(
            deps: deps,
            controller: rig.controller,
            now: rig.clock.now,
          ),
        ),
      ),
      desktop: false,
    );
    await _open(tester);
    expect(find.text('On their way'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    final list = rig.controller.crossings;
    expect(list.map((c) => c.isOpen), [true, true, false, false]);
    expect(_text(tester, 'bridge-row-status-${list[0].id}'), 'Collect');
    expect(_text(tester, 'bridge-row-status-${list[1].id}'), '34 blocks to go');
    expect(_text(tester, 'bridge-row-status-${list[2].id}'), 'Arrived');
    await _golden('phone_bridge_history');
    await finish(tester);
  });

  testWidgets('desktop: the history beside the form', (tester) async {
    final rig = await historyRig(tester);
    await _pump(
      tester,
      DesktopBridgeView(deps: rig.deps(desktop: true), now: rig.clock.now),
      desktop: true,
    );
    expect(find.text('On their way'), findsOneWidget);
    await _golden('desktop_bridge_history');
    await finish(tester);
  });

  testWidgets('phone: an empty history offers to move', (tester) async {
    final rig = _Rig();
    final deps = rig.deps(desktop: false);
    await tester.runAsync(rig.controller.resumeAll);
    await _pump(
      tester,
      _opener(
        (c) => showDexPageForTest(
          c,
          deps,
          BridgeCrossingsView(deps: deps, controller: rig.controller),
        ),
      ),
      desktop: false,
    );
    await _open(tester);
    expect(find.text('No crossings yet'), findsOneWidget);
    expect(find.text('Move coins'), findsOneWidget);
    await finish(tester);
  });
}

/// [screen] opened as the app opens a bridge screen (`showDexPage`).
Future<void> showDexPageForTest(
  BuildContext context,
  BridgeDeps deps,
  Widget screen,
) => showDexPage<void>(context, deps, (_) => screen);
