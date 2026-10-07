/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// "Import wallet.db" screen: one job (a wallet from its file and password),
// one primary button that names the outcome, the original file's safety said
// first, the missing recovery phrase said plainly, errors that say what to
// do next. Phone 375 × 667 and desktop.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/import/beam_import_wallet_file_view.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_file_import.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import '../airdrop_ui/beam_ui_harness.dart';

const _path = '/Users/someone/Library/Beam Wallet/wallets/alice/wallet.db';

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<PrimaryButton>(find.byKey(ValueKey(key))).enabled;

void main() {
  for (final desktop in [false, true]) {
    final layout = desktop ? 'desktop' : 'phone';

    testWidgets('$layout: choose the file, then name and password; the '
        'button names the outcome and waits for both', (tester) async {
      final imports = <String>[];
      await pumpBeamPage(
        tester,
        BeamImportWalletFileView(
          pickFile: () async => _path,
          nameTaken: (_) => false,
          import:
              ({
                required String name,
                required String sourcePath,
                required String password,
              }) async {
                imports.add('$name|$sourcePath');
                throw const BeamWalletException(
                  BeamWalletProblem.wrongPassword,
                  BeamImportMessages.wrongPassword,
                );
              },
        ),
        desktop: desktop,
      );
      await tester.pumpAndSettle();

      // First screen: what it is, that the file stays as it is, one button.
      expect(find.text(BeamImportWalletFileView.title), findsOneWidget);
      expect(find.text(BeamImportText.intro), findsOneWidget);
      expect(find.text(BeamImportText.choose), findsOneWidget);
      await expectScreen(tester, 'import_start_$layout');

      await tester.tap(find.byKey(const ValueKey('import-choose')));
      await tester.pumpAndSettle();

      // The folder name is offered as the wallet's name.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('import-name')),
            )
            .controller!
            .text,
        'alice',
      );
      expect(find.text('wallet.db'), findsOneWidget);
      expect(find.text(BeamImportText.noPhrase), findsOneWidget);
      expect(find.text(BeamImportText.cta), findsOneWidget);
      expect(_enabled(tester, 'import-cta'), isFalse, reason: 'no password');

      await tester.enterText(
        find.byKey(const ValueKey('import-password')),
        'not-the-password',
      );
      await tester.pumpAndSettle();
      expect(_enabled(tester, 'import-cta'), isTrue);
      // The password is hidden as typed.
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('import-password')),
            )
            .obscureText,
        isTrue,
      );
      await expectScreen(tester, 'import_ready_$layout');

      await tester.tap(find.byKey(const ValueKey('import-cta')));
      await tester.pumpAndSettle();
      expect(imports, ['alice|$_path']);
      expect(find.byKey(const ValueKey('import-problem')), findsOneWidget);
      expect(find.text(BeamImportMessages.wrongPassword), findsOneWidget);
      await expectScreen(tester, 'import_wrong_password_$layout');
    });
  }

  testWidgets('a picker that fails says so instead of doing nothing',
      (tester) async {
    await pumpBeamPage(
      tester,
      BeamImportWalletFileView(
        pickFile: () async => throw Exception('no panel'),
        import:
            ({
              required String name,
              required String sourcePath,
              required String password,
            }) async => throw UnimplementedError(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('import-choose')));
    await tester.pumpAndSettle();
    expect(find.text(BeamImportText.pickFailed), findsOneWidget);
  });

  test('the texts never blame and always say what to do next', () {
    for (final t in [
      BeamImportMessages.wrongPassword,
      BeamImportMessages.inUse,
      BeamImportMessages.gone,
      BeamImportMessages.failed,
    ]) {
      expect(t.toLowerCase(), isNot(contains('you entered a wrong')));
      expect(
        RegExp(r'(try again|choose it again|close that|import the file)')
            .hasMatch(t.toLowerCase()),
        isTrue,
        reason: t,
      );
    }
  });
}
