/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Seen on the iOS simulator of a Mac set to Russia: the decimal pad offers
// "," only, and the DEX and send fields expect "." — an amount like 0.5
// could not be typed at all.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/beam_decimal_input.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';

TextEditingValue _v(String text, [int? cursor]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: cursor ?? text.length),
);

void main() {
  final dot = BeamDecimalKeyFormatter('.');
  final comma = BeamDecimalKeyFormatter(',');

  test('a typed "," becomes "." where "." is expected, and back', () {
    expect(dot.formatEditUpdate(_v('0'), _v('0,')).text, '0.');
    expect(comma.formatEditUpdate(_v('0'), _v('0.')).text, '0,');
    // In the middle of the text, the cursor stays where it was.
    final mid = dot.formatEditUpdate(_v('15', 1), _v('1,5', 2));
    expect(mid.text, '1.5');
    expect(mid.selection.baseOffset, 2);
  });

  test('the expected separator and digits pass untouched', () {
    expect(dot.formatEditUpdate(_v('0'), _v('0.')).text, '0.');
    expect(dot.formatEditUpdate(_v('0.'), _v('0.5')).text, '0.5');
  });

  test('pasted text is never rewritten: "1,000" may be a thousand', () {
    expect(dot.formatEditUpdate(_v(''), _v('1,000')).text, '1,000');
    expect(dot.formatEditUpdate(_v('1'), _v('1,000')).text, '1,000');
  });

  testWidgets('typing 0,5 on a field that reads "." gives 0.5', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              BeamDecimalKeyFormatter('.'),
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    for (final step in ['0', '0,', '0,5']) {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: step.replaceAll(',', controller.text.contains('.') ? '.' : ','),
          selection: TextSelection.collapsed(offset: step.length),
        ),
      );
      await tester.pump();
    }
    expect(controller.text, '0.5');
    expect(DexFormat.parse(controller.text).value, BigInt.from(50000000));
  });

  // iOS's decimal pad has no Done key, and on phones Flutter keeps a field
  // focused on a touch outside it: the keyboard could not be put away.
  testWidgets('a tap outside puts the keyboard away; a tap into another '
      'field moves to it', (tester) async {
    final amount = FocusNode();
    final comment = FocusNode();
    addTearDown(amount.dispose);
    addTearDown(comment.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Material(
          child: BeamCloseKeyboardOnTapOutside(
            child: Column(
              children: [
                TextField(key: const Key('amount'), focusNode: amount),
                TextField(key: const Key('comment'), focusNode: comment),
                const SizedBox(height: 200, child: Text('elsewhere')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('amount')));
    await tester.pump();
    expect(amount.hasFocus, isTrue);
    await tester.tap(find.text('elsewhere'));
    await tester.pump();
    expect(amount.hasFocus, isFalse);

    await tester.tap(find.byKey(const Key('amount')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('comment')));
    await tester.pump();
    expect(comment.hasFocus, isTrue);
  });
}
