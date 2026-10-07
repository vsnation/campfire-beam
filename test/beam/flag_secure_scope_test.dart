/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/add_wallet_views/new_wallet_recovery_phrase_view/sub_widgets/mnemonic_table.dart';
import 'package:stackwallet/pages/add_wallet_views/verify_recovery_phrase_view/sub_widgets/word_table.dart';
import 'package:stackwallet/widgets/flag_secure_scope.dart';

Widget _app(Widget child) => ProviderScope(
  child: Directionality(textDirection: TextDirection.ltr, child: child),
);

void main() {
  late List<bool> calls;

  setUp(() {
    calls = [];
    FlagSecureScope.debugSetFlagSecure = (enable) async => calls.add(enable);
  });

  tearDown(() {
    FlagSecureScope.debugSetFlagSecure = null;
    FlagSecureScope.debugUserWantsSecure = null;
  });

  testWidgets('on while shown, back to the user setting (off) when gone', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const FlagSecureScope(child: SizedBox())));
    expect(calls, [true]);
    expect(FlagSecureScope.activeCount, 1);

    await tester.pumpWidget(_app(const SizedBox()));
    expect(calls, [true, false]);
    expect(FlagSecureScope.activeCount, 0);
  });

  testWidgets('stacked screens: the flag stays on until the last one goes', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            FlagSecureScope(child: SizedBox()), // phrase screen
            FlagSecureScope(child: SizedBox()), // verify screen on top
          ],
        ),
      ),
    );
    expect(calls, [true]);

    // The verify screen pops: the phrase screen is still showing its words.
    await tester.pumpWidget(
      _app(const Column(children: [FlagSecureScope(child: SizedBox())])),
    );
    expect(calls, [true]);

    await tester.pumpWidget(_app(const SizedBox()));
    expect(calls, [true, false]);
  });

  testWidgets('a user who disabled screenshots keeps the flag after', (
    tester,
  ) async {
    FlagSecureScope.debugUserWantsSecure = () => true;
    await tester.pumpWidget(_app(const FlagSecureScope(child: SizedBox())));
    await tester.pumpWidget(_app(const SizedBox()));
    expect(calls, [true, true]);
  });

  testWidgets('the widgets that show recovery words are wrapped in it', (
    tester,
  ) async {
    const words = [
      'alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot', //
      'golf', 'hotel', 'india', 'juliet', 'kilo', 'lima',
    ];
    Widget? table, quiz;
    // Their items need the app theme to render; what matters here is what
    // build() returns, so build without mounting the items.
    await tester.pumpWidget(
      _app(
        Consumer(
          builder: (context, ref, _) {
            table = const MnemonicTable(
              words: words,
              isDesktop: false,
            ).build(context);
            quiz = WordTable(
              words: words.take(9).toList(),
              isDesktop: false,
            ).build(context, ref);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(table, isA<FlagSecureScope>());
    expect(quiz, isA<FlagSecureScope>());
  });
}
