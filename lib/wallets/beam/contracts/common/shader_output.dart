/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

/// An app shader refused the call: its output was `{"error": "..."}`.
///
/// wallet-api reports this as a *successful* `invoke_contract` whose
/// `output` carries the error, so it has to be detected here.
class BeamShaderException implements Exception {
  const BeamShaderException(this.message);

  /// The shader's own text, e.g. `no such pool`, `invalid kind`,
  /// `val1 too large`.
  final String message;

  @override
  String toString() => 'BeamShaderException: $message';
}

/// Decodes an app shader's `output` text with every integer exact.
///
/// Shaders print amounts as bare JSON integers of up to 2^64-1. `jsonDecode`
/// turns integers beyond 2^63-1 into lossy doubles (and beyond 2^53 on the
/// web), so here every integer literal becomes a [BigInt] instead. Strings,
/// booleans and null are unchanged; a number with a fraction or exponent
/// (shaders never print one) stays a [double].
abstract final class ShaderOutput {
  /// Prefix marking a rewritten integer literal. U+0000 cannot appear raw
  /// in a JSON string; a shader string that *escapes* one and continues with
  /// digits would be misread as a number, and typed reads would then fail
  /// with a [FormatException] rather than return a wrong value.
  static const _mark = '\u0000';

  /// [_mark] as it is written into the JSON text: the escape, since a raw
  /// control character is not valid inside a JSON string.
  static const _markEscape = r'\u0000';

  /// Parses [output]. Throws [BeamShaderException] when the root object has
  /// an `error` entry, and [FormatException] when it is not a JSON object.
  static Map<String, Object?> decode(String output) {
    final Object? tree;
    try {
      tree = _restore(jsonDecode(_markIntegers(output)));
    } on FormatException catch (e) {
      throw FormatException('shader output is not JSON: ${e.message}');
    }
    if (tree is! Map<String, Object?>) {
      throw const FormatException('shader output: expected a JSON object');
    }
    final error = tree['error'];
    if (error != null) {
      throw BeamShaderException(error is String ? error : '$error');
    }
    return tree;
  }

  static String _markIntegers(String s) {
    final out = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        // A string: copy through the closing quote, honouring escapes.
        final start = i++;
        while (i < s.length) {
          final d = s.codeUnitAt(i++);
          if (d == 0x5c) {
            i++;
          } else if (d == 0x22) {
            break;
          }
        }
        out.write(s.substring(start, i));
      } else if (c == 0x2d || (c >= 0x30 && c <= 0x39)) {
        final start = i++;
        while (i < s.length && _isNumberChar(s.codeUnitAt(i))) {
          i++;
        }
        final token = s.substring(start, i);
        if (_integer.hasMatch(token)) {
          out.write('"$_markEscape$token"');
        } else {
          out.write(token);
        }
      } else {
        out.writeCharCode(c);
        i++;
      }
    }
    return out.toString();
  }

  static final _integer = RegExp(r'^-?(0|[1-9][0-9]*)$');

  static bool _isNumberChar(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2e ||
      c == 0x65 ||
      c == 0x45 ||
      c == 0x2b ||
      c == 0x2d;

  static Object? _restore(Object? v) {
    if (v is String && v.startsWith(_mark)) {
      return BigInt.parse(v.substring(_mark.length));
    }
    if (v is Map) {
      return <String, Object?>{
        for (final e in v.entries) e.key as String: _restore(e.value),
      };
    }
    if (v is List) return [for (final e in v) _restore(e)];
    return v;
  }

  // ------------------------------------------------------------ typed reads

  static Map<String, Object?> map(Object? value, String what) {
    if (value is Map<String, Object?>) return value;
    throw FormatException('$what: expected a JSON object');
  }

  static List<Object?> list(Object? value, String what) {
    if (value is List<Object?>) return value;
    throw FormatException('$what: expected a JSON array');
  }

  /// A non-negative integer of at most 64 bits (an `Amount`).
  static BigInt amount(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is BigInt && !v.isNegative && v.bitLength <= 64) return v;
    throw FormatException('$key: expected an unsigned 64-bit integer');
  }

  static BigInt? optAmount(Map<String, Object?> json, String key) =>
      json[key] == null ? null : amount(json, key);

  /// A non-negative integer of at most 32 bits (an `AssetID`, a kind).
  static int uint32(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is BigInt && !v.isNegative && v.bitLength <= 32) return v.toInt();
    throw FormatException('$key: expected an unsigned 32-bit integer');
  }

  static String string(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is String) return v;
    throw FormatException('$key: expected a string');
  }

  static String? optString(Map<String, Object?> json, String key) =>
      json[key] == null ? null : string(json, key);
}
