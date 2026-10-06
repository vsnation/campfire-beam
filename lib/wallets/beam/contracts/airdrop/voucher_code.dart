/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;

import 'airdrop_constants.dart';

/// Voucher codes: the secret that redeems a voucher.
///
/// A code is 16 symbols from a 32-symbol alphabet (80 bits), shown as
/// `XXXX-XXXX-XXXX-XXXX`. The contract stores only SHA-256 of the
/// **normalised** code; redeeming sends the normalised code itself (the
/// preimage) and the contract hashes it on chain. Whoever holds a code can
/// redeem it, and the creator needs the codes to hand them out, so codes are
/// kept like keys (see `VoucherCodeStore`).
abstract final class AirdropVoucherCode {
  /// No I, O, 0 or 1, which are easy to misread. Same as LightWallet.
  static const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// Symbols per generated code.
  static const length = 16;

  /// Symbols per dash-separated group in [format].
  static const groupSize = 4;

  /// A new code from [random] (default `Random.secure()`), formatted.
  ///
  /// Each symbol is one uniform draw over [alphabet] by rejection sampling.
  /// With 32 symbols nothing is ever rejected, but the guard keeps the
  /// distribution uniform if the alphabet changes. LightWallet once used
  /// `Math.random()`, whose state a few published codes reveal; never pass a
  /// non-cryptographic [random] outside tests.
  static String generate([Random? random]) {
    final rng = random ?? Random.secure();
    const n = alphabet.length;
    const limit = 256 - 256 % n;
    final out = StringBuffer();
    for (var i = 0; i < length; i++) {
      int b;
      do {
        b = rng.nextInt(256);
      } while (b >= limit);
      out.write(alphabet[b % n]);
    }
    return format(out.toString());
  }

  /// The code exactly as the app shader normalises it before hashing
  /// (`On_user_redeem`): ASCII `a`-`z` become upper case, every byte that
  /// is not `A`-`Z` or `0`-`9` is dropped, and at most
  /// [kAirdropMaxCodeLength] symbols are kept.
  ///
  /// Works on UTF-8 bytes like the shader, so non-ASCII letters are dropped
  /// rather than upper-cased (`String.toUpperCase` would turn `ß` into
  /// `SS`; the shader does not).
  static String normalise(String input) {
    final out = StringBuffer();
    var n = 0;
    for (final byte in utf8.encode(input)) {
      if (n == kAirdropMaxCodeLength) break;
      var c = byte;
      if (c >= 0x61 && c <= 0x7a) c -= 0x20;
      final isUpper = c >= 0x41 && c <= 0x5a;
      final isDigit = c >= 0x30 && c <= 0x39;
      if (isUpper || isDigit) {
        out.writeCharCode(c);
        n++;
      }
    }
    return out.toString();
  }

  /// [input] normalised and regrouped for display: `ABCD-EFGH-…`. Partial
  /// input is grouped as far as it goes, for an input field.
  static String format(String input) {
    final s = normalise(input);
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && i % groupSize == 0) out.write('-');
      out.write(s[i]);
    }
    return out.toString();
  }

  /// Whether [input] normalises to a code this module would have generated:
  /// [length] symbols, all from [alphabet]. Codes made elsewhere can differ
  /// and still redeem; this is for input hints, not a gate.
  static bool isWellFormed(String input) {
    final s = normalise(input);
    return s.length == length && s.split('').every(alphabet.contains);
  }

  /// Lowercase hex SHA-256 of the normalised [code]: the contract's key
  /// for the voucher. Throws [ArgumentError] when nothing is left after
  /// normalising.
  static String hashHex(String code) {
    final s = normalise(code);
    if (s.isEmpty) {
      throw ArgumentError.value(code, 'code', 'no letters or digits');
    }
    return crypto.sha256.convert(ascii.encode(s)).toString();
  }
}
