/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// DMG test #26: the desktop password prompt during a swap said "Enter your
// wallet password to send BEAM". It now names what the password is for.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/widgets/beam/dex/dex_auth_gate.dart';

import 'dex_ui_harness.dart';

void main() {
  test('the DEX reasons map to what the password is for', () {
    expect(dexAuthAction('Authenticate to swap'), 'swap');
    expect(dexAuthAction('Authenticate to add liquidity'), 'add liquidity');
    expect(dexAuthAction('Authenticate to withdraw'), 'withdraw');
    expect(dexAuthAction('Authenticate to create the pool'), 'create the pool');
    expect(dexAuthAction('Confirm transaction'), isNull);
  });

  testWidgets('a swap asks for the password "to swap", not "to send BEAM"', (
    tester,
  ) async {
    await pumpDex(
      tester,
      Builder(
        builder: (context) => TextButton(
          key: const Key('open-gate'),
          onPressed: () =>
              campfireDexAuthGate(context, reason: 'Authenticate to swap'),
          child: const Text('open'),
        ),
      ),
      size: desktopWindow,
      pixelRatio: 1,
    );
    await tester.tap(find.byKey(const Key('open-gate')));
    await tester.pumpAndSettle();
    expect(find.text('Enter your wallet password to swap'), findsOneWidget);
    expect(find.textContaining('to send BEAM'), findsNothing);
  }, skip: !isMacHost);

  testWidgets('everything else keeps Campfire\'s own prompt', (tester) async {
    await pumpDex(
      tester,
      Material(child: DesktopAuthSend(coin: Beam(CryptoCurrencyNetwork.main))),
      size: desktopWindow,
      pixelRatio: 1,
    );
    expect(
      find.text('Enter your wallet password to send BEAM'),
      findsOneWidget,
    );
  });
}
