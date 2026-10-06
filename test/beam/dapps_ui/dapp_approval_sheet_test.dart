/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The approval sheet driven end to end: a real DappSession on a
// FakeTransport, the committed consent queue, Campfire's approval presenter
// and this sheet. Amounts come from the committed DEX raw_data vectors and
// the real mainnet-built trade (test/beam/contracts/dex/fixtures).
//
//   CFB_HOST_WORKDIR=/private/tmp/cfb-dappui \
//     scripts/beam/host_test.sh --no-analyze test/beam/dapps_ui

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_presenter.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_shared_transport.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_watched_consent_queue.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_approval_sheet.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import '../contracts/dex/dex_fixtures.dart';
import '../dapps/dapp_invoke_builder.dart';
import '../dapps/dapp_session_fixtures.dart';
import 'dapp_ui_harness.dart';

const _dexGuid = 'db851322f6674a6da3e84e9953db2ffd';
const _origin = 'http://127.0.0.1:40000';

/// The bundled Beam DEX dApp, installed from its pinned package.
const _dex = DappIdentity(
  guid: _dexGuid,
  name: 'Beam DEX',
  origin: _origin,
  startUrl: '$_origin/app/index.html',
  version: '1.0.0',
  checkedByCampfire: true,
);

/// A dApp installed from a file.
const _sideloaded = DappIdentity(
  guid: 'ab12ab12ab12ab12ab12ab12ab12ab12',
  name: 'Yield Farm',
  origin: 'http://127.0.0.1:40001',
  startUrl: 'http://127.0.0.1:40001/index.html',
  version: '0.9.1',
);

/// Not a real wallet's address: 33 bytes of a counting pattern.
final _recipient = [
  for (var i = 0; i < 33; i++) (i * 7 + 3).toRadixString(16).padLeft(2, '0'),
].join();

List<int> _realTrade() {
  final f = jsonDecode(
    File('$dexFixtureDir/trade_built_raw_data.json').readAsStringSync(),
  ) as Map;
  return base64.decode((f['result']! as Map)['raw_data_base64']! as String);
}

class _Rig {
  _Rig(
    this.tester, {
    required this.desktop,
    this.auth = true,
    this.identity = _dex,
  });

  final WidgetTester tester;
  final bool desktop;
  final DappIdentity identity;
  bool? auth;
  late final FakeTransport core;
  late final FakeWalletLink link;
  late final DappApprovalPresenter presenter;
  late final DappWatchedConsentQueue queue;
  late final DappSession session;
  late BuildContext context;
  int sent = 0;
  int authAsked = 0;

  Future<void> pump({
    Map<int, BigInt>? balances,
    Map<int, BeamAssetMetadata> metadata = const {},
    String? blocked,
  }) async {
    core = FakeTransport({
      'process_invoke_data': (Map<String, Object?> p) => {'txid': txId(++sent)},
      'sign_message': {'signature': 'ab' * 65},
      'validate_address': {
        'is_valid': true,
        'is_mine': false,
        'type': 'regular',
      },
      'tx_send': (Map<String, Object?> p) => {'txId': txId(++sent)},
    });
    link = FakeWalletLink(
      root: '/nonexistent',
      transport: DappSharedTransport(core),
      balances: balances,
      metadata: metadata,
      blocked: blocked,
    );
    presenter = DappApprovalPresenter(link);
    queue = DappWatchedConsentQueue(presenter);
    session = DappSession(
      identity: identity,
      apiVersion: DappApiVersion.v7_4,
      transport: link.dappTransport(identity),
      consent: queue,
    );
    await tester.pumpWidget(
      campfireApp(
        home: Builder(
          builder: (c) {
            context = c;
            return Scaffold(
              backgroundColor: const Color(0xFFFFF1F1),
              body: Center(child: Text('dApp page', key: UniqueKey())),
            );
          },
        ),
      ),
    );
    presenter.attach(
      (model) => showDappApprovalSheet(
        context,
        model,
        pending: queue.pending,
        desktop: desktop,
        authenticate: (_) async {
          authAsked++;
          return auth;
        },
      ),
    );
  }

  /// Sends one request through the dApp session; the sheet opens.
  Future<String> Function() ask(String method, Map<String, Object?> params) {
    String? answer;
    unawaited(
      session.handle(rq(method, method, params)).then((r) => answer = r),
    );
    return () async {
      await tester.pumpAndSettle();
      return answer!;
    };
  }

  /// The sheet is on screen and Approve takes taps (after
  /// [DappApprovalSheet.armDelay]), as the user sees it a moment later.
  Future<void> settle() async {
    await tester.pumpAndSettle();
    await tester.pump(DappApprovalSheet.armDelay);
    await precacheImages(tester);
  }

  /// The sheet has just appeared: Approve does not take taps yet.
  Future<void> justOpened() async {
    await tester.pumpAndSettle();
  }

  bool get approveEnabled => tester
      .widget<PrimaryButton>(find.byKey(DappApprovalSheet.approveKey))
      .enabled;
}

void main() {
  const g = BigInt.from;

  group('approval sheet', () {
    testWidgets('DEX swap: decoded amounts, fee, contract and the dApp\'s '
        'message; approve executes exactly the approved data', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(balances: {0: g(500000000), 174: g(0)});

      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
        'confirm_comment': 'Swap 0.1 BEAM for FOMO',
      });
      await rig.settle();

      expect(find.text('Beam DEX'), findsOneWidget);
      expect(find.text('$_origin · version 1.0.0'), findsOneWidget);
      expect(find.text('Asks you to approve a swap.'), findsOneWidget);
      expect(find.text('−0.1 BEAM'), findsOneWidget);
      expect(find.text('+0.80368764 FOMO'), findsOneWidget);
      expect(find.text('0.011 BEAM'), findsOneWidget, reason: 'network fee');
      expect(find.text('0.111 BEAM'), findsOneWidget, reason: 'total out');
      expect(find.text('Message from Beam DEX'), findsOneWidget);
      expect(find.text('“Swap 0.1 BEAM for FOMO”'), findsOneWidget);
      expect(find.text('Beam DEX · ${dappShortHex(dexCid)}'), findsOneWidget);
      expect(find.text('Approve swap'), findsOneWidget);
      expect(find.text('Reject'), findsOneWidget);
      expect(rig.link.holds, 1, reason: 'node switch held while on screen');

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_dex_swap_mobile.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      final res = await answer();
      expect(rig.authAsked, 1, reason: 'Campfire PIN/password asked first');
      expect(resultOf(res), {'txid': txId(1)});
      expect(rig.core.callsTo('process_invoke_data'), hasLength(1));
      final sent = rig.core.lastParams('process_invoke_data');
      expect(sent['data'], rawDataVector('trade_plain'));
      expect(sent['confirm_comment'], 'Swap 0.1 BEAM for FOMO');
      expect(find.byType(DappApprovalSheet), findsNothing);
      expect(rig.link.releases, 1);
    });

    testWidgets('a real mainnet-built DEX trade from a dApp is refused '
        'before any sheet: it is HFT data the core could rebuild', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(1280, 900));
      final rig = _Rig(tester, desktop: true);
      await rig.pump(balances: {0: g(500000000)});

      final answer = rig.ask('process_invoke_data', {'data': _realTrade()});
      await rig.justOpened();
      expect(find.byType(DappApprovalSheet), findsNothing);
      final res = await answer();
      expect(errorCode(res), -32020);
      expect(errorData(res), contains("can't show you what would be signed"));
      expect(errorData(res), contains('use Swap in Campfire'));
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
      expect(rig.link.holds, 0, reason: 'nothing was put to the user');
    });

    testWidgets('a DEX trade on desktop', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(1280, 900));
      final rig = _Rig(tester, desktop: true);
      await rig.pump(balances: {0: g(500000000)});

      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.settle();

      expect(find.text('−0.1 BEAM'), findsOneWidget);
      expect(find.text('+0.80368764 FOMO'), findsOneWidget);
      expect(find.text('“Amm trade”'), findsOneWidget);
      expect(find.text('Review request'), findsOneWidget);
      expect(find.text('Beam DEX · ${dappShortHex(dexCid)}'), findsOneWidget);
      expect(find.textContaining('not checked by Campfire'), findsNothing);

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_dex_trade_desktop.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      final res = await answer();
      expect(errorCode(res), -32021);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });

    testWidgets('tx_send: amount, asset, fee and the shortened recipient; '
        'reject answers -32021 and nothing is sent', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(balances: {0: g(1000000000)});

      final answer = rig.ask('tx_send', {
        'address': _recipient,
        'value': 150000000,
        'asset_id': 0,
        'comment': 'Order 1042',
      });
      await rig.settle();

      expect(find.text('Asks you to approve a payment.'), findsOneWidget);
      expect(find.text('−1.5 BEAM'), findsOneWidget);
      expect(find.text('0.001 BEAM'), findsOneWidget);
      expect(find.text('1.501 BEAM'), findsOneWidget);
      expect(
        find.text(dappShortHex(_recipient, head: 10, tail: 8)),
        findsOneWidget,
      );
      expect(
        find.textContaining('must come online within 12 hours'),
        findsOneWidget,
      );
      expect(find.text('“Order 1042”'), findsOneWidget);
      expect(find.text('Approve payment'), findsOneWidget);

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_payment_mobile.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      final res = await answer();
      expect(errorCode(res), -32021);
      expect(rig.core.callsTo('tx_send'), isEmpty);
      expect(rig.authAsked, 0);
    });

    testWidgets('an unverified asset named like a verified one is flagged', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(
        metadata: {
          175: BeamAssetMetadata.parse(
            'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO;NTHUN=GROTH',
          ),
        },
      );

      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('withdraw'),
      });
      await rig.settle();

      expect(find.text('Unverified asset #175'), findsOneWidget);
      // The look-alike always carries its id, in the row and the total.
      expect(find.text('−1 FOMO (#175)'), findsOneWidget);
      expect(find.text('1 FOMO (#175)'), findsOneWidget);
      expect(
        find.textContaining('not the verified FOMO (#174)'),
        findsOneWidget,
      );
      expect(find.text('Approve swap'), findsOneWidget);

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_lookalike_asset_mobile.png'),
      );

      // Closing the sheet (tap outside) is a rejection.
      await tester.tapAt(const Offset(20, 20));
      final res = await answer();
      expect(errorCode(res), -32021);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });

    testWidgets('one request at a time: "2 more requests waiting"', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(
        balances: {0: g(5000000000), 174: g(1000000000), 175: g(500000000)},
      );

      final a = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      final b = rig.ask('process_invoke_data', {
        'data': rawDataVector('create_pool'),
      });
      final c = rig.ask('process_invoke_data', {
        'data': rawDataVector('withdraw'),
      });
      await rig.settle();

      expect(find.byType(DappApprovalSheet), findsOneWidget);
      expect(
        find.text('2 more requests waiting after this one'),
        findsOneWidget,
      );
      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_queue_mobile.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await a()), -32021);
      await rig.settle();
      expect(find.byType(DappApprovalSheet), findsOneWidget);
      expect(
        find.text('1 more request waiting after this one'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await b()), -32021);
      await rig.settle();
      expect(find.textContaining('waiting after this one'), findsNothing);
      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      expect(resultOf(await c()), {'txid': txId(1)});
      expect(rig.core.callsTo('process_invoke_data'), hasLength(1));
      expect(
        rig.core.lastParams('process_invoke_data')['data'],
        rawDataVector('withdraw'),
      );
    });

    testWidgets('a wrong PIN keeps the sheet open and sends nothing', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false, auth: false);
      await rig.pump(balances: {0: g(500000000)});
      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.settle();
      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      await tester.pump();
      expect(find.text('Invalid PIN'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(DappApprovalSheet), findsOneWidget);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await answer()), -32021);
    });

    testWidgets('not enough funds or a wallet that is behind: approve is '
        'disabled and the sheet says why', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(
        balances: {0: g(5000000)},
        blocked:
            'Catching up with the network. Sending is paused until '
            "it's done.",
      );
      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.settle();
      expect(
        find.textContaining(
          'Not enough BEAM: this needs 0.111 BEAM and the '
          'wallet has 0.05 BEAM available.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Catching up with the network'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      await tester.pumpAndSettle();
      expect(rig.authAsked, 0);
      expect(find.byType(DappApprovalSheet), findsOneWidget);
      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await answer()), -32021);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });

    testWidgets('closing the dApp withdraws its request and the sheet', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(balances: {0: g(500000000)});
      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.settle();
      expect(find.byType(DappApprovalSheet), findsOneWidget);
      // Not awaited: close() awaits a broadcast subscription's cancel(),
      // whose root-zone future never resumes inside testWidgets' fake
      // async. The withdrawal itself happens synchronously in close().
      unawaited(rig.session.close());
      final res = await answer();
      expect(errorCode(res), -32021);
      expect(find.byType(DappApprovalSheet), findsNothing);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });
  });

  // Security review part 2, M-8: a page can time its request so the
  // user's next tap lands where Approve appears.
  group('tap-jacking', () {
    testWidgets('Approve takes no taps right after the sheet appears', (
      tester,
    ) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(balances: {0: g(500000000)});
      final answer = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.justOpened();
      expect(find.byType(DappApprovalSheet), findsOneWidget);
      expect(rig.approveEnabled, isFalse);
      await tester.tap(
        find.byKey(DappApprovalSheet.approveKey),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(rig.authAsked, 0, reason: 'the early tap did nothing');

      await tester.pump(DappApprovalSheet.armDelay);
      expect(rig.approveEnabled, isTrue);
      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      expect(resultOf(await answer()), {'txid': txId(1)});
      expect(rig.authAsked, 1);
    });

    testWidgets('a layout change (another request queues) re-arms the '
        'delay', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false);
      await rig.pump(balances: {0: g(500000000)});
      final a = rig.ask('process_invoke_data', {
        'data': rawDataVector('trade_plain'),
      });
      await rig.settle();
      expect(rig.approveEnabled, isTrue);

      // The page queues a second request: the "1 more request waiting"
      // note pushes Approve down.
      final b = rig.ask('process_invoke_data', {
        'data': rawDataVector('withdraw'),
      });
      await tester.pump();
      await tester.pump();
      expect(
        find.text('1 more request waiting after this one'),
        findsOneWidget,
      );
      expect(rig.approveEnabled, isFalse);
      await tester.tap(
        find.byKey(DappApprovalSheet.approveKey),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(rig.authAsked, 0);

      await tester.pump(DappApprovalSheet.armDelay);
      expect(rig.approveEnabled, isTrue);
      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await a()), -32021);
      await rig.settle();
      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await b()), -32021);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });
  });

  // Security review part 2, H-1: the sheet used to net all calls and say
  // "No funds move" while one call emptied a contract and another locked
  // the funds elsewhere.
  group('each call on its own', () {
    testWidgets('two calls that net to zero: each one\'s flows, the key '
        'it signs with, and an unchecked dApp', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false, identity: _sideloaded);
      await rig.pump(balances: {0: g(500000000)});

      final answer = rig.ask('process_invoke_data', {
        'data': invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            method: 3,
            spend: {0: -1000000000},
            sigs: ['c7' * 32],
          ),
          invokeEntry(contractId: dexCid, method: 7, spend: {0: 1000000000}),
        ]),
        'confirm_comment': 'Harvest your rewards',
      });
      await rig.settle();

      expect(find.textContaining('No funds move'), findsNothing);
      expect(find.textContaining('Nothing you hold moves'), findsNothing);
      expect(
        find.text('Asks you to approve 2 contract calls. Check what each '
            'one moves.'),
        findsOneWidget,
      );
      expect(
        find.text('Call 1 · Contract a1a1a1a1…a1a1a1 · method 3'),
        findsOneWidget,
      );
      expect(find.text('Call 2 · Beam DEX · method 7'), findsOneWidget);
      expect(find.text('+10 BEAM'), findsOneWidget);
      expect(find.text('−10 BEAM'), findsOneWidget);
      expect(find.text("Signs with your wallet's key"), findsOneWidget);
      expect(
        find.textContaining('Call 1 signs with your wallet\'s key for '
            'Contract a1a1a1a1…a1a1a1'),
        findsOneWidget,
      );
      expect(
        find.textContaining('paid into another contract'),
        findsOneWidget,
      );
      expect(
        find.text('Installed from a file · not checked by Campfire'),
        findsOneWidget,
      );
      expect(find.text('Approve contract calls'), findsOneWidget);

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_two_calls_mobile.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.rejectKey));
      expect(errorCode(await answer()), -32021);
      expect(rig.core.callsTo('process_invoke_data'), isEmpty);
    });
  });

  // M-7: a signature used to need no approval at all.
  group('sign_message', () {
    testWidgets('the message, the key, and "Sign message"', (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(375, 812));
      final rig = _Rig(tester, desktop: false, identity: _sideloaded);
      await rig.pump(balances: {0: g(500000000)});

      final answer = rig.ask('sign_message', {
        'message': 'Log in to Yield Farm\nNonce 81f3',
        'key_material': '6b3f1a2000aa00bb00cc00dd00ee00ffc09e11',
      });
      await rig.settle();

      expect(
        find.text('Asks you to sign a message with a key from this wallet.'),
        findsOneWidget,
      );
      expect(
        find.text('Message to sign, from Yield Farm'),
        findsOneWidget,
      );
      expect(find.text('“Log in to Yield Farm\nNonce 81f3”'), findsOneWidget);
      expect(
        find.text('Key id 6b3f1a20…c09e11, chosen by Yield Farm'),
        findsOneWidget,
      );
      expect(find.text('Network fee'), findsNothing);
      expect(find.text('Total leaving your wallet'), findsNothing);
      expect(find.text('Sign message'), findsOneWidget);

      await expectLater(
        find.byKey(const ValueKey('golden')),
        matchesGoldenFile('goldens/approval_sign_message_mobile.png'),
      );

      await tester.tap(find.byKey(DappApprovalSheet.approveKey));
      expect(resultOf(await answer()), {'signature': 'ab' * 65});
      expect(rig.authAsked, 1);
      expect(rig.core.lastParams('sign_message'), {
        'message': 'Log in to Yield Farm\nNonce 81f3',
        'key_material': '6b3f1a2000aa00bb00cc00dd00ee00ffc09e11',
      });
    });
  });

  group('presenter', () {
    test('with no page attached every request is rejected', () async {
      final link = FakeWalletLink(root: '/x');
      final p = DappApprovalPresenter(link);
      final r = DappConsentRequest(
        kind: DappConsentKind.contract,
        dapp: _dex,
        requestId: 1,
        pays: const [],
        receives: const [],
        fee: g(1100000),
        digest: 'ab',
      );
      expect(await p.approve(r), isFalse);
      expect(link.holds, 0);
    });

    test('a failing UI is a rejection and the hold is released', () async {
      final link = FakeWalletLink(root: '/x');
      final p = DappApprovalPresenter(link)
        ..attach((_) => Future.error(StateError('boom')));
      final r = DappConsentRequest(
        kind: DappConsentKind.contract,
        dapp: _dex,
        requestId: 1,
        pays: [DappAssetAmount(0, g(1))],
        receives: const [],
        fee: g(1100000),
        digest: 'ab',
      );
      expect(await p.approve(r), isFalse);
      expect(link.holds, 1);
      expect(link.releases, 1);
    });
  });

  group('model', () {
    DappConsentRequest req({
      List<DappAssetAmount> pays = const [],
      List<DappAssetAmount> receives = const [],
      DappConsentKind kind = DappConsentKind.contract,
    }) => DappConsentRequest(
      kind: kind,
      dapp: _dex,
      requestId: 1,
      pays: pays,
      receives: receives,
      fee: g(1100000),
      digest: 'ab',
      dappMessage: '   ',
    );

    test('the outcome label follows what moves', () {
      expect(
        DappApprovalModel.build(
          req(
            pays: [DappAssetAmount(0, g(1))],
            receives: [DappAssetAmount(174, g(1))],
          ),
        ).cta,
        'Approve swap',
      );
      expect(
        DappApprovalModel.build(req(pays: [DappAssetAmount(0, g(1))])).cta,
        'Approve payment',
      );
      expect(
        DappApprovalModel.build(req(receives: [DappAssetAmount(174, g(1))]))
            .cta,
        'Approve withdrawal',
      );
      final feeOnly = DappApprovalModel.build(req());
      expect(feeOnly.cta, 'Approve request');
      expect(feeOnly.isFeeOnly, isTrue);
      expect(feeOnly.message, isNull, reason: 'blank dApp text is not shown');
    });

    test('amounts are exact, grouped, never rounded', () {
      expect(dappFormatAmount(g(10000000)), '0.1');
      expect(dappFormatAmount(g(80368764)), '0.80368764');
      expect(dappFormatAmount(g(1)), '0.00000001');
      expect(dappFormatAmount(g(123456789012345678)), '1,234,567,890.12345678');
      expect(dappFormatAmount(g(100000000000)), '1,000');
      expect(dappShortHex(dexCid), '729fe098…ef9cbf');
    });
  });
}
