/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The token screens (create, my tokens, mint more, burn) over the real
// BeamMinterService and BeamBurnService on a FakeTransport, with the
// recorded Minter / BlackHole answers and wallet_status fixture.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/minter/beam_burn_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_mint_token_view.dart';
import 'package:stackwallet/pages/beam/minter/beam_my_tokens_view.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/burn/burn.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_asset_names.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import '../airdrop_ui/beam_ui_harness.dart';
import 'minter_fakes.dart';

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PrimaryButton>(find.byKey(ValueKey(key))).enabled;

Finder _field(String key) => find.byKey(ValueKey(key));

const _emberMeta =
    'STD:SCH_VER=1;N=Ember Token;SN=EMB;UN=EMB;NTHUN=groth;'
    'NTH_RATIO=100000000';

void main() {
  late FakeMinterShader minter;
  late FakeBurnShader burner;
  late FakeTransport t;
  late BeamMinterService mintService;
  late BeamBurnService burnService;
  late ValueNotifier<BeamSyncAssessment> sync;
  late FakeAuth auth;
  late BeamAssetNames names;

  // Built inside each test body: a service made in setUp() holds
  // Futures of the real zone, whose callbacks never run under the widget
  // test's fake clock.
  void init() {
    minter = FakeMinterShader();
    burner = FakeBurnShader();
    t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) {
        final args = p['args']! as String;
        return args.contains('cid=$kBlackHoleContractId')
            ? burner(p)
            : minter(p);
      },
      'process_invoke_data': (Map<String, Object?> p) => {'txid': 'ef' * 16},
      'wallet_status': jsonDecode(
        File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
      ),
    });
    final api = BeamApi(t);
    mintService = BeamMinterService(api, minterAppShader(MemoryShaderSource()));
    burnService = BeamBurnService(
      api,
      blackHoleAppShader(MemoryShaderSource()),
    );
    sync = ValueNotifier(synced());
    auth = FakeAuth();
    names = BeamAssetNames();
  }

  Widget mintView() => BeamMintTokenView(
    service: mintService,
    sync: sync,
    assetNames: names,
    authorize: auth.authorizer,
  );

  Future<void> fill(
    WidgetTester tester, {
    required String name,
    required String ticker,
    String supply = '1000000',
  }) async {
    await tester.enterText(_field('mint-name'), name);
    await tester.enterText(_field('mint-ticker'), ticker);
    await tester.enterText(_field('mint-supply'), supply);
    await tester.pumpAndSettle();
  }

  group('create a token', () {
    testWidgets('the cost comes first, fields explain their own mistakes, and '
        'the confirmation shows 50 + 10 BEAM and the decoded fee', (
      tester,
    ) async {
      init();
      await pumpBeamPage(tester, mintView());
      await tester.pumpAndSettle();

      // Read from view_params, not assumed.
      expect(find.text('50 BEAM'), findsOneWidget);
      expect(find.text('10 BEAM'), findsOneWidget);
      expect(_textOf(tester, 'mint-cost-total'), '60 BEAM + network fee');
      expect(_enabled(tester, 'mint-cta'), isFalse);

      await fill(tester, name: 'Ember;Token', ticker: 'embers7');
      expect(
        find.text(
          'Name can use English letters, digits, spaces and . , - _ only.',
        ),
        findsOneWidget,
      );
      expect(find.text('Ticker can be at most 6 characters.'), findsOneWidget);
      expect(_enabled(tester, 'mint-cta'), isFalse);
      await expectScreen(tester, 'mint_form');

      await fill(tester, name: 'Ember Token', ticker: 'emb');
      expect(find.text('Create EMB'), findsOneWidget);
      expect(_enabled(tester, 'mint-cta'), isTrue);

      await tester.tap(_field('mint-cta'));
      await tester.tap(_field('mint-cta'));
      await tester.pumpAndSettle();
      expect(
        minter.seen.where((a) => a.contains('action=create_token')),
        hasLength(1),
      );
      expect(minter.seen.last, contains('SN=EMB'));
      expect(_textOf(tester, 'minter-issue-fee'), '50 BEAM');
      expect(_textOf(tester, 'minter-deposit'), '10 BEAM');
      expect(_textOf(tester, 'minter-network-fee'), '0.0167 BEAM');
      expect(_textOf(tester, 'minter-total'), '60.0167 BEAM');
      expect(find.text('Create EMB for 60.0167 BEAM'), findsOneWidget);
      await expectScreen(tester, 'mint_confirm');

      await tester.tap(_field('minter-confirm-cta'));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(auth.reasons, ['Create the token EMB']);
      expect(find.byKey(const ValueKey('mint-done')), findsOneWidget);
      expect(mintService.isBusy, isFalse);
      await expectScreen(tester, 'mint_done');
    });

    testWidgets('a name that copies a verified asset is warned about', (
      tester,
    ) async {
      init();
      await pumpBeamPage(tester, mintView());
      await tester.pumpAndSettle();
      await fill(tester, name: 'Fomo', ticker: 'FOMO');
      expect(
        find.byKey(const ValueKey('mint-copies-verified')),
        findsOneWidget,
      );
    });

    testWidgets('while the wallet catches up, creating waits', (tester) async {
      init();
      sync.value = catchingUp();
      await pumpBeamPage(tester, mintView());
      await tester.pumpAndSettle();
      await fill(tester, name: 'Ember Token', ticker: 'EMB');
      expect(_enabled(tester, 'mint-cta'), isFalse);
      expect(find.byKey(const ValueKey('beam-sync-notice')), findsOneWidget);
    });

    testWidgets('desktop layout', (tester) async {
      init();
      await pumpBeamPage(tester, mintView(), desktop: true);
      await tester.pumpAndSettle();
      await fill(tester, name: 'Ember Token', ticker: 'EMB');
      await expectScreen(tester, 'desktop_mint_form');
    });
  });

  group('my tokens', () {
    testWidgets('shows minted of maximum; "Mint more" mints after the '
        'confirmation', (tester) async {
      init();
      minter.owned[4242] = (
        BigInt.parse('25000000000000'),
        BigInt.parse('100000000000000'),
        _emberMeta,
      );
      await pumpBeamPage(
        tester,
        BeamMyTokensView(
          service: mintService,
          sync: sync,
          assetNames: names,
          authorize: auth.authorizer,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Minted 250,000 of 1,000,000'), findsOneWidget);
      expect(find.text('Ember Token (EMB)'), findsOneWidget);
      await expectScreen(tester, 'my_tokens');

      await tester.tap(_field('token-mint-4242'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('mint-more-amount'), '1000');
      await tester.pumpAndSettle();
      expect(find.text('Mint 1,000 EMB'), findsOneWidget);
      await tester.tap(_field('mint-more-cta'));
      await tester.pumpAndSettle();
      expect(_textOf(tester, 'minter-mint-amount'), '1,000 EMB');
      expect(_textOf(tester, 'minter-network-fee'), '0.011 BEAM');
      await tester.tap(_field('minter-confirm-cta'));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(find.byKey(const ValueKey('tokens-done')), findsOneWidget);
    });

    testWidgets('no tokens yet: says what to do and offers it', (tester) async {
      init();
      await pumpBeamPage(
        tester,
        BeamMyTokensView(service: mintService, sync: sync, assetNames: names),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tokens-empty')), findsOneWidget);
      expect(_enabled(tester, 'tokens-create'), isTrue);
      await expectScreen(tester, 'tokens_empty');
    });
  });

  group('burn', () {
    testWidgets('BEAM is never offered; the confirmation is heavy and sends '
        'only after the ticker is typed', (tester) async {
      init();
      await pumpBeamPage(
        tester,
        BeamBurnView(
          service: burnService,
          sync: sync,
          assetNames: names,
          authorize: auth.authorizer,
          initialAssetId: 6,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('burn-intro')), findsOneWidget);

      await tester.tap(_field('burn-asset'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('beam-asset-option-0')), findsNothing);
      expect(
        find.byKey(const ValueKey('beam-asset-option-174')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('beam-asset-option-6')));
      await tester.pumpAndSettle();

      await tester.enterText(_field('burn-amount'), '0.01');
      await tester.pumpAndSettle();
      expect(find.text('Burn 0.01 RFC'), findsOneWidget);
      await tester.tap(_field('burn-cta'));
      await tester.pumpAndSettle();

      expect(find.text('This destroys 0.01 RFC forever'), findsOneWidget);
      expect(_textOf(tester, 'burn-amount-confirm'), '0.01 RFC');
      expect(_textOf(tester, 'burn-fee'), '0.011 BEAM');
      expect(_enabled(tester, 'burn-confirm-cta'), isFalse);
      await expectScreen(tester, 'burn_confirm');

      await tester.tap(_field('burn-confirm-cta'));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), isEmpty);

      await tester.enterText(_field('burn-type-ticker'), 'rfc');
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'burn-confirm-cta'), isTrue);
      await tester.tap(_field('burn-confirm-cta'));
      await tester.pumpAndSettle();
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(auth.reasons, ['Burn 0.01 RFC forever']);
      expect(find.byKey(const ValueKey('burn-done')), findsOneWidget);
      expect(
        burner.seen.where((a) => a.contains('action=deposit')).single,
        contains('aid=6,amount=1000000'),
      );
    });
  });
}
