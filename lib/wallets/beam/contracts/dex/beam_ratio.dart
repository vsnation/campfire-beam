/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

/// An exact rational number (prices, rates, shares, price impact).
///
/// Money and prices in this module never go through `double`. A ratio is
/// kept reduced with a positive denominator, so `==` is value equality.
@immutable
class BeamRatio implements Comparable<BeamRatio> {
  factory BeamRatio(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) {
      throw ArgumentError.value(denominator, 'denominator', 'zero');
    }
    final n = denominator.isNegative ? -numerator : numerator;
    final d = denominator.abs();
    final g = n.gcd(d);
    return BeamRatio._(
      g > BigInt.one ? n ~/ g : n,
      g > BigInt.one ? d ~/ g : d,
    );
  }

  const BeamRatio._(this.numerator, this.denominator);

  factory BeamRatio.fromInt(int v) => BeamRatio._(BigInt.from(v), BigInt.one);

  static final zero = BeamRatio._(BigInt.zero, BigInt.one);
  static final one = BeamRatio._(BigInt.one, BigInt.one);

  final BigInt numerator;

  /// Always positive.
  final BigInt denominator;

  /// Parses a decimal as the AMM shader prints rates (`k1_2`, `k2_1`):
  /// `12.5`, `0.00003917486936274595045`, and scientific `1.25e-7` /
  /// `3E+5`, optionally signed.
  static BeamRatio parseDecimal(String text) {
    final m = _decimal.firstMatch(text.trim());
    if (m == null) throw FormatException('not a decimal number', text);
    final negative = m.group(1) == '-';
    final whole = m.group(2) ?? '';
    final fraction = m.group(3) ?? '';
    if (whole.isEmpty && fraction.isEmpty) {
      throw FormatException('not a decimal number', text);
    }
    final exponent = int.parse(m.group(4) ?? '0') - fraction.length;
    var n = BigInt.parse('${whole.isEmpty ? '0' : whole}$fraction');
    if (negative) n = -n;
    final ten = BigInt.from(10);
    return exponent >= 0
        ? BeamRatio(n * ten.pow(exponent), BigInt.one)
        : BeamRatio(n, ten.pow(-exponent));
  }

  static final _decimal = RegExp(
    r'^([+-])?([0-9]*)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]{1,4}))?$',
  );

  bool get isZero => numerator == BigInt.zero;
  bool get isNegative => numerator.isNegative;

  BeamRatio operator +(BeamRatio o) => BeamRatio(
    numerator * o.denominator + o.numerator * denominator,
    denominator * o.denominator,
  );

  BeamRatio operator -(BeamRatio o) => BeamRatio(
    numerator * o.denominator - o.numerator * denominator,
    denominator * o.denominator,
  );

  BeamRatio operator *(BeamRatio o) =>
      BeamRatio(numerator * o.numerator, denominator * o.denominator);

  BeamRatio operator /(BeamRatio o) {
    if (o.isZero) throw ArgumentError.value(o, 'divisor', 'zero');
    return BeamRatio(numerator * o.denominator, denominator * o.numerator);
  }

  BeamRatio operator -() => BeamRatio._(-numerator, denominator);

  bool operator <(BeamRatio o) => compareTo(o) < 0;
  bool operator <=(BeamRatio o) => compareTo(o) <= 0;
  bool operator >(BeamRatio o) => compareTo(o) > 0;
  bool operator >=(BeamRatio o) => compareTo(o) >= 0;

  /// The largest integer not above this value.
  BigInt floor() {
    final q = numerator ~/ denominator; // truncates toward zero
    return (numerator.isNegative && q * denominator != numerator)
        ? q - BigInt.one
        : q;
  }

  /// floor([amount] × this): e.g. an amount at a rate, rounded down.
  BigInt floorTimes(BigInt amount) =>
      BeamRatio(amount * numerator, denominator).floor();

  /// A fixed-point decimal with [fractionDigits] digits, truncated toward
  /// zero (never shows more than the exact value).
  String toDecimalString(int fractionDigits) {
    if (fractionDigits < 0) {
      throw ArgumentError.value(fractionDigits, 'fractionDigits');
    }
    final scale = BigInt.from(10).pow(fractionDigits);
    final scaled = (numerator.abs() * scale) ~/ denominator;
    final digits = scaled.toString().padLeft(fractionDigits + 1, '0');
    final cut = digits.length - fractionDigits;
    final sign = (numerator.isNegative && scaled != BigInt.zero) ? '-' : '';
    return fractionDigits == 0
        ? '$sign$digits'
        : '$sign${digits.substring(0, cut)}.${digits.substring(cut)}';
  }

  @override
  int compareTo(BeamRatio o) =>
      (numerator * o.denominator).compareTo(o.numerator * denominator);

  @override
  bool operator ==(Object other) =>
      other is BeamRatio &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => '$numerator/$denominator';
}
