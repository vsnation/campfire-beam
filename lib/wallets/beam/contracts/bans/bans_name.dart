/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'bans_constants.dart';
import 'bans_exceptions.dart';

/// A name the BANS contract accepts, in its one canonical form.
///
/// The rules are the shader's, exactly (`contract.h:41-51`,
/// `app.cpp:252-272`): 3 to 64 characters, each one of `a-z`, `0-9`, `_`,
/// `-`, `~`. Upper case is **invalid** on-chain (`Beam` gives
/// `"name is invalid"`), so [BansName.new] rejects it.
///
/// [BansName.fromUserInput] is the lenient door for text a person typed or
/// pasted: it trims, lower-cases and strips a `.beam` suffix first, the way
/// the official dApp does. The result is still checked by the same rules.
///
/// Only a [BansName] can reach an argument builder, so nothing outside the
/// charset (in particular `,` and `=`, which delimit shader arguments) can
/// ever be sent.
@immutable
final class BansName {
  /// Takes [name] exactly as the contract stores it. Throws
  /// [BansInvalidName] if the contract would refuse it.
  factory BansName(String name) {
    final problem = check(name);
    if (problem != null) {
      throw BansInvalidName(name, problem, describe(problem));
    }
    return BansName._(name);
  }

  const BansName._(this.value);

  /// Normalises typed or pasted text, then validates it:
  /// `"  Alice.BEAM "` becomes `alice`.
  factory BansName.fromUserInput(String input) => BansName(normalise(input));

  /// Like [BansName.new], but returns null instead of throwing.
  static BansName? tryParse(String name) =>
      check(name) == null ? BansName._(name) : null;

  /// The canonical name, without any `.beam` suffix.
  final String value;

  int get length => value.length;

  /// How the name is shown where it stands in for an address.
  String get display => '$value.beam';

  /// USD per period for this name's length tier.
  int get usdPerPeriod => bansUsdPerPeriod(value.length);

  /// What the contract would object to in [name], or null if it is valid.
  static BansNameProblem? check(String name) {
    if (name.isEmpty) return BansNameProblem.empty;
    if (name.length < kBansNameMinLength) return BansNameProblem.tooShort;
    if (name.length > kBansNameMaxLength) return BansNameProblem.tooLong;
    for (final unit in name.codeUnits) {
      if (!isValidCodeUnit(unit)) return BansNameProblem.invalidCharacter;
    }
    return null;
  }

  /// `Domain::IsValidChar`: `_`, `-`, `~`, `a-z`, `0-9`.
  static bool isValidCodeUnit(int c) =>
      c == 0x5f || // _
      c == 0x2d || // -
      c == 0x7e || // ~
      (c >= 0x61 && c <= 0x7a) || // a-z
      (c >= 0x30 && c <= 0x39); // 0-9

  /// Trims, lower-cases (ASCII only) and removes one trailing `.beam`.
  /// Does not validate.
  static String normalise(String input) {
    var s = input.trim();
    final lower = StringBuffer();
    for (final unit in s.codeUnits) {
      lower.writeCharCode(unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit);
    }
    s = lower.toString();
    if (s.endsWith('.beam')) s = s.substring(0, s.length - '.beam'.length);
    return s;
  }

  /// Plain wording for [problem], for an inline hint under the field.
  static String describe(BansNameProblem problem) => switch (problem) {
    BansNameProblem.empty => 'Type a name.',
    BansNameProblem.tooShort => 'Names need at least 3 characters.',
    BansNameProblem.tooLong => 'Names can be at most 64 characters.',
    BansNameProblem.invalidCharacter =>
      'Use only lowercase letters, numbers, - _ and ~.',
  };

  @override
  bool operator ==(Object other) => other is BansName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A 33-byte BVM public key as wallet-api prints it: 64 hex characters of X
/// followed by the Y-parity byte, `00` or `01`.
abstract final class BansKey {
  static final _re = RegExp(r'^[0-9a-f]{64}0[01]$');

  /// The all-zero key, which the shader reads as "no key" (`view_domain`
  /// lists every name; `receive` claims sale proceeds).
  static final zero = '00' * 33;

  static bool isValid(String key) => _re.hasMatch(key);

  /// Lower-cases and trims [key], then checks it. Throws [BansInvalidKey].
  static String require(String key) {
    final k = key.trim().toLowerCase();
    if (!isValid(k) || k == zero) throw BansInvalidKey(key);
    return k;
  }

  /// A short, recognisable form for confirmation screens:
  /// `72e368c0…570d51ef01` becomes `72e3…51ef`.
  static String fingerprint(String key) {
    if (key.length < 12) return key;
    final end = key.length - 2;
    return '${key.substring(0, 4)}…${key.substring(end - 4, end)}';
  }
}
