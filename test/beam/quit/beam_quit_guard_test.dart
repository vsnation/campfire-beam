/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop quit guard: quitting while a DEX transaction is still being
// confirmed asks first (patches/0006). Transaction IDs are synthetic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_swaps_in_flight.dart';
import 'package:stackwallet/widgets/beam/quit/beam_quit_guard.dart';

import '../airdrop_ui/beam_ui_harness.dart';

BeamTransaction _swap(String id, {int status = 1}) => BeamTransaction.fromJson({
  'txId': id,
  'status': status,
  'status_string': 'x',
  'tx_type': 12,
  'tx_type_string': 'contract',
  'income': false,
  'fee': 1100000,
  'sender': '',
  'receiver': '',
  'comment': '',
  'create_time': 1790000100,
  'invoke_data': const [
    {
      'contract_id': kDexContractId,
      'amounts': [
        {'asset_id': 0, 'amount': 2000000},
        {'asset_id': 174, 'amount': -16000000},
      ],
    },
  ],
});

class _Quitter extends StatelessWidget {
  const _Quitter(this.swaps, this.answers);

  final BeamSwapsInFlight swaps;
  final List<bool> answers;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('quit'),
        onPressed: () async =>
            answers.add(await confirmBeamQuit(context, swaps: swaps)),
        child: const Text('Quit'),
      ),
    ),
  );
}

void main() {
  late BeamSwapsInFlight swaps;
  late List<bool> answers;

  setUp(() {
    swaps = BeamSwapsInFlight();
    answers = [];
  });

  Future<void> pumpQuitter(WidgetTester tester) =>
      pumpBeamPage(tester, _Quitter(swaps, answers), desktop: true);

  testWidgets('nothing in flight: quits at once, no dialog', (tester) async {
    await pumpQuitter(tester);
    await tester.tap(find.byKey(const Key('quit')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamQuitDialog), findsNothing);
    expect(answers, [true]);
  });

  testWidgets('a swap in flight: asks; "Wait" keeps Campfire open', (
    tester,
  ) async {
    swaps.update('w1', [_swap('a1' * 16)]);
    await pumpQuitter(tester);
    await tester.tap(find.byKey(const Key('quit')));
    await tester.pumpAndSettle();

    expect(find.text('A swap is still being confirmed'), findsOneWidget);
    expect(
      find.text(
        'This usually takes under a minute. Quitting now can make it run '
        'again.',
      ),
      findsOneWidget,
    );
    await expectScreen(tester, 'quit_guard_desktop');

    await tester.tap(find.byKey(const Key('beamQuitWait')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamQuitDialog), findsNothing);
    expect(answers, [false]);
  });

  testWidgets('"Quit anyway" quits', (tester) async {
    swaps.update('w1', [_swap('a1' * 16)]);
    await pumpQuitter(tester);
    await tester.tap(find.byKey(const Key('quit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('beamQuitAnyway')));
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('the swap settles while asking: the quit goes ahead', (
    tester,
  ) async {
    swaps.update('w1', [_swap('a1' * 16), _swap('b2' * 16)]);
    await pumpQuitter(tester);
    await tester.tap(find.byKey(const Key('quit')));
    await tester.pumpAndSettle();
    expect(find.text('2 swaps are still being confirmed'), findsOneWidget);

    swaps.update('w1', [_swap('a1' * 16, status: 3), _swap('b2' * 16)]);
    await tester.pumpAndSettle();
    expect(find.text('A swap is still being confirmed'), findsOneWidget);
    expect(answers, isEmpty);

    swaps.update('w1', [_swap('b2' * 16, status: 3)]);
    await tester.pumpAndSettle();
    expect(find.byType(BeamQuitDialog), findsNothing);
    expect(answers, [true]);
  });

  testWidgets('a second quit request while asking shows no second dialog', (
    tester,
  ) async {
    swaps.update('w1', [_swap('a1' * 16)]);
    await pumpQuitter(tester);
    await tester.tap(find.byKey(const Key('quit')));
    await tester.pumpAndSettle();
    // Cmd-Q again, from behind the barrier: through the API, as main.dart does
    final ctx = tester.element(find.byKey(const Key('quit')));
    final second = confirmBeamQuit(ctx, swaps: swaps);
    await tester.pumpAndSettle();
    expect(find.byType(BeamQuitDialog), findsOneWidget);

    await tester.tap(find.byKey(const Key('beamQuitWait')));
    await tester.pumpAndSettle();
    expect(await second, isFalse);
    expect(answers, [false]);
  });
}
