/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

import '../../../bridge/bridge_routes.dart';
import '../../../bridge/bridge_sides.dart';
import '../common/shader_output.dart';

/// Reads what the pipe app shaders print for the view actions of
/// [PipeArgs], exactly as recorded on mainnet (research 06, §B.2).
///
/// Every amount stays an exact [BigInt]. Anything that is not the shape
/// the pipe prints, including a shader error other than "absent", is a
/// [BridgeException] with [BridgeErrorCode.badPipe]: an answer of the
/// wrong shape most likely comes from the wrong contract, and a guess
/// could send a crossing where nobody can claim it.
abstract final class PipeOutput {
  /// What both shaders print for a `local_msg` / `remote_msg` id that
  /// holds no message (never recorded, already claimed, not yet pushed).
  static const absentError = 'msg with current id is absent';

  /// The secp256k1 field prime.
  static final _p = (BigInt.one << 256) - (BigInt.one << 32) - BigInt.from(977);

  /// `get_pk`: the 33-byte receive key. The forward shader names it `pk`,
  /// the reverse one `pubkey`; each must use its own name, so a route
  /// driven by the wrong shader is noticed here.
  static Uint8List receiveKey(String output, BridgeShader shader) {
    final json = _decode(output, 'get_pk');
    final name = switch (shader) {
      BridgeShader.forward => 'pk',
      BridgeShader.reverse => 'pubkey',
    };
    final v = json[name];
    if (v is! String) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        'get_pk printed no "$name"',
      );
    }
    final key = _hex(v, 33, 'get_pk $name');
    checkKey(key);
    return key;
  }

  /// Refuses (badPipe) anything that is not a BEAM public key: `X[32]`
  /// then a parity byte 00 or 01, with X a non-zero field element that is
  /// the x of a secp256k1 point. A key that fails this could never sign a
  /// claim, and Ethereum would still accept it in `sendFunds`.
  static void checkKey(List<int> key) {
    if (key.length != 33) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        'a receive key is 33 bytes, not ${key.length}',
      );
    }
    if (key[32] > 1) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        'receive key parity byte ${key[32]}, expected 0 or 1',
      );
    }
    var x = BigInt.zero;
    for (var i = 0; i < 32; i++) {
      x = (x << 8) | BigInt.from(key[i]);
    }
    if (x == BigInt.zero || x >= _p) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'receive key X is not a field element',
      );
    }
    // On the curve y² = x³ + 7 exactly when x³ + 7 is a square mod p
    // (Euler's criterion); it is never 0 on secp256k1.
    final rhs = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
    if (rhs.modPow((_p - BigInt.one) >> 1, _p) != BigInt.one) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'receive key is not a secp256k1 point',
      );
    }
  }

  /// `local_msg_count`: `{"count": n}`.
  static int count(String output) =>
      _int(_decode(output, 'local_msg_count'), 'count');

  /// `local_msg`, or null when there is no message with that id.
  static BeamPipeLocalMessage? localMessage(String output) {
    final json = _decodeOrAbsent(output, 'local_msg');
    if (json == null) return null;
    final receiver = _string(json, 'receiver');
    return BeamPipeLocalMessage(
      receiver: '0x${_hexString(receiver, 20, 'local_msg receiver')}',
      amount: _amount(json, 'amount'),
      relayerFee: _amount(json, 'relayerFee'),
      height: _int(json, 'height'),
    );
  }

  /// `remote_msg`, or null when it is absent (claimed or never pushed).
  static BeamPipeRemoteMessage? remoteMessage(String output) {
    final json = _decodeOrAbsent(output, 'remote_msg');
    if (json == null) return null;
    final receiver = _string(json, 'receiver');
    return BeamPipeRemoteMessage(
      amount: _amount(json, 'amount'),
      relayerFee: _amount(json, 'relayerFee'),
      receiver: _hex(receiver, 33, 'remote_msg receiver'),
    );
  }

  /// `view_incoming`: `{"incoming": [{"MsgId": n, "amount": a}, …]}`.
  ///
  /// The id is spelled `MsgId` by both shaders; `msgId` and `id` are
  /// accepted too, but never two different ids in one entry. On a
  /// contract with no pipe params the shader prints `{"incoming":
  /// ["error": "no params"]}`, which is not JSON at all: that is badPipe
  /// here, never an empty list (an empty list would say "nothing to
  /// claim" about a contract that cannot hold anything).
  static List<BeamPipeIncoming> incoming(String output) {
    final json = _decode(output, 'view_incoming');
    final Object? list = json['incoming'];
    if (list is! List<Object?>) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'view_incoming printed no "incoming" list',
      );
    }
    return List.unmodifiable([for (final item in list) _incomingEntry(item)]);
  }

  static BeamPipeIncoming _incomingEntry(Object? item) {
    if (item is! Map<String, Object?>) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'view_incoming: an entry is not an object',
      );
    }
    int? id;
    for (final name in const ['MsgId', 'msgId', 'id']) {
      if (!item.containsKey(name)) continue;
      final v = _int(item, name);
      if (id != null && id != v) {
        throw const BridgeException(
          BridgeErrorCode.badPipe,
          'view_incoming: an entry has two different ids',
        );
      }
      id = v;
    }
    if (id == null) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'view_incoming: an entry has no MsgId',
      );
    }
    return BeamPipeIncoming(id, _amount(item, 'amount'));
  }

  // ---------------------------------------------------------------- helpers

  static Map<String, Object?> _decode(String output, String what) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        '$what: the pipe said "${e.message}"',
      );
    } on FormatException catch (e) {
      throw BridgeException(BridgeErrorCode.badPipe, '$what: ${e.message}');
    }
  }

  /// Like [_decode], but null for exactly the shader's "absent" error.
  static Map<String, Object?>? _decodeOrAbsent(String output, String what) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      if (e.message == absentError) return null;
      throw BridgeException(
        BridgeErrorCode.badPipe,
        '$what: the pipe said "${e.message}"',
      );
    } on FormatException catch (e) {
      throw BridgeException(BridgeErrorCode.badPipe, '$what: ${e.message}');
    }
  }

  static BigInt _amount(Map<String, Object?> json, String key) {
    try {
      return ShaderOutput.amount(json, key);
    } on FormatException catch (e) {
      throw BridgeException(BridgeErrorCode.badPipe, e.message);
    }
  }

  /// A non-negative integer small enough for an `int` everywhere,
  /// the web included.
  static int _int(Map<String, Object?> json, String key) {
    final v = _amount(json, key);
    if (v.bitLength > 53) {
      throw BridgeException(BridgeErrorCode.badPipe, '$key: $v is too large');
    }
    return v.toInt();
  }

  static String _string(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is String) return v;
    throw BridgeException(BridgeErrorCode.badPipe, '$key: expected a string');
  }

  static String _hexString(String hex, int bytes, String what) {
    if (!RegExp('^[0-9a-f]{${2 * bytes}}\$').hasMatch(hex)) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        '$what: expected ${2 * bytes} lowercase hex characters',
      );
    }
    return hex;
  }

  static Uint8List _hex(String hex, int bytes, String what) {
    _hexString(hex, bytes, what);
    return Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }
}
