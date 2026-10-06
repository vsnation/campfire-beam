/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Typed reads from decoded wallet-api JSON.
///
/// Every failure is a [FormatException] that names the field, so a changed
/// response shape is reported as such rather than as a bare cast error.
abstract final class BeamJson {
  static Map<String, Object?> map(Object? value, String what) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return value.cast<String, Object?>();
    throw FormatException('$what: expected a JSON object');
  }

  static List<Object?> list(Object? value, String what) {
    if (value is List<Object?>) return value;
    if (value is List) return value.cast<Object?>();
    throw FormatException('$what: expected a JSON array');
  }

  static List<Map<String, Object?>> mapList(Object? value, String what) => [
    for (final e in list(value, what)) map(e, '$what[]'),
  ];

  static String string(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is String) return v;
    throw FormatException('$key: expected a string');
  }

  static String? optString(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null || v is String) return v as String?;
    throw FormatException('$key: expected a string');
  }

  static int integer(Map<String, Object?> json, String key) =>
      optInt(json, key) ?? (throw FormatException('$key: missing'));

  static int? optInt(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null || v is int) return v as int?;
    throw FormatException('$key: expected an integer');
  }

  /// wallet-api writes some flags as 0/1 (`isOwned`) and most as booleans.
  static bool boolean(Map<String, Object?> json, String key) =>
      optBool(json, key) ?? (throw FormatException('$key: missing'));

  static bool? optBool(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null || v is bool) return v as bool?;
    if (v == 0 || v == 1) return v == 1;
    throw FormatException('$key: expected a boolean');
  }

  static double? optDouble(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw FormatException('$key: expected a number');
  }

  static BigInt amount(Map<String, Object?> json, String key) =>
      optAmount(json, key) ?? (throw FormatException('$key: missing'));

  /// An amount in the asset's smallest unit.
  ///
  /// `<key>_str` is preferred whenever present: wallet-api leaves the plain
  /// number out above 2^53-1, and even below that a JSON number is not safe on
  /// every platform. The plain number is used only when there is no `_str`
  /// twin. A plain number beyond 64-bit range is decoded by `jsonDecode` as a
  /// double; it is accepted as such (only uint64 fields without a twin can do
  /// this, at 2^63 and above).
  static BigInt? optAmount(Map<String, Object?> json, String key) {
    final s = json['${key}_str'];
    if (s != null) {
      final parsed = s is String ? BigInt.tryParse(s) : null;
      if (parsed == null) {
        throw FormatException('${key}_str: expected an integer string');
      }
      return parsed;
    }
    final v = json[key];
    if (v == null) return null;
    if (v is int) return BigInt.from(v);
    if (v is double && v.isFinite && v == v.truncateToDouble()) {
      return BigInt.from(v);
    }
    throw FormatException('$key: expected an integer amount');
  }

  /// A block height, or null when absent or a sentinel beyond 64-bit signed
  /// range (`MaxHeight` = 2^64-1 marks "not yet known", e.g. the maturity of
  /// an incoming coin).
  static int? optHeight(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null || v is double) return null;
    if (v is int) return v;
    throw FormatException('$key: expected a height');
  }

  /// An empty string means "none" in several wallet-api fields.
  static String? nonEmpty(Map<String, Object?> json, String key) {
    final v = optString(json, key);
    return (v == null || v.isEmpty) ? null : v;
  }

  static DateTime unixSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
