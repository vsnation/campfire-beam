/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Security review part 2, L-17 / dApp review L5: text a dApp writes
// (confirm_comment, kernel comments, payment comments) reaches Campfire's
// approval sheet. Bidi controls could make it read as something else.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_text.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';

void main() {
  group('dappDisplayText', () {
    test('bidi overrides and isolates are removed', () {
      // "Receive 1 BEAM" with U+202E would render reversed after it.
      expect(dappDisplayText('Pay \u202e01\u202c BEAM'), 'Pay 01 BEAM');
      expect(dappDisplayText('a\u2066b\u2069c\u061cd'), 'abcd');
    });

    test('zero-width characters and the BOM are removed', () {
      expect(dappDisplayText('\ufeffFO\u200bMO\u2060'), 'FOMO');
    });

    test('control characters become spaces; line breaks stay, at most '
        'two', () {
      expect(dappDisplayText('a\u0000b\u0007c\u009bd'), 'a b c d');
      expect(dappDisplayText('one\r\ntwo\n\n\n\n\nthree'), 'one\ntwo\n\nthree');
      expect(dappDisplayText('x\u2028y'), 'x y');
    });

    test('long text is cut, never inside a surrogate pair', () {
      expect(dappDisplayText('abcdef', maxLength: 4), 'abcd…');
      const emoji = 'ab\u{1F525}cd';
      expect(dappDisplayText(emoji, maxLength: 3), 'ab…');
      expect(dappDisplayText(emoji, maxLength: 4), 'ab\u{1F525}…');
    });

    test('dappTextHasHidden', () {
      expect(dappTextHasHidden('plain text\nwith a break\tand tab'), isFalse);
      expect(dappTextHasHidden('x\u202ey'), isTrue);
      expect(dappTextHasHidden('x\u0001y'), isTrue);
      expect(dappTextHasHidden('x\ry'), isTrue);
    });
  });

  test('the approval sheet shows the cleaned text, never the raw', () {
    final m = DappApprovalModel.build(
      DappConsentRequest(
        kind: DappConsentKind.contract,
        dapp: const DappIdentity(
          guid: 'ab12ab12ab12ab12ab12ab12ab12ab12',
          name: 'Test',
          origin: 'http://127.0.0.1:40000',
          startUrl: 'http://127.0.0.1:40000/index.html',
        ),
        requestId: 1,
        pays: const [],
        receives: const [],
        fee: BigInt.from(1100000),
        digest: 'ab',
        dappMessage: 'You \u202eevieceR\u202c 10 BEAM',
      ),
    );
    expect(m.message, 'You evieceR 10 BEAM');
  });
}
