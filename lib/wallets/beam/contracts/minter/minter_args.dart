/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'minter_constants.dart';
import 'token_metadata.dart';

/// `args` strings for the Minter app shader (`bvm/Shaders/minter/app.cpp`,
/// tag `beam-7.5.14493`).
///
/// The Minter shader reads only `action`: it has no roles. LightWallet
/// sends `role=manager` with `withdraw`; the shader never reads it.
/// Numbers are canonical decimals (`strtoull(.., 0)` would read a leading
/// zero as octal).
abstract final class MinterArgs {
  static final _maxU64 = (BigInt.one << 64) - BigInt.one;
  static final _cid = RegExp(r'^[0-9a-f]{64}$');

  /// `view_params`: `{"res": {tokenIssueFee, cidDaoVault}}`.
  static String viewParams({String cid = kMinterContractId}) =>
      _join('view_params', cid, const {});

  /// `view_owned`: the tokens this wallet created,
  /// `{"res": [{aid, mintedLo, mintedHi, limitLo, limitHi, owner_pk,
  /// metadata?}]}`.
  static String viewOwned({String cid = kMinterContractId}) =>
      _join('view_owned', cid, const {});

  /// `view_token`: one token, `{"res": {mintedLo, …, is_owner?}}`, or the
  /// error `no such token`.
  static String viewToken({
    required int assetId,
    String cid = kMinterContractId,
  }) {
    if (assetId <= 0 || assetId > 0xffffffff) {
      // aid=0 would list every token instead.
      throw ArgumentError.value(assetId, 'assetId', 'a CA id, 1..2^32-1');
    }
    return _join('view_token', cid, {'aid': '$assetId'});
  }

  /// `create_token`: a new asset with [metadata] that can ever be minted
  /// up to [limit] (in its smallest unit, up to 2^128-1; the shader takes
  /// it as `limit` + `limitHi`).
  ///
  /// The metadata is the last argument and is quoted: its own `,` and `=`
  /// stay inside the value. [BeamTokenMetadata] guarantees it holds no
  /// `"` or `\`, which would end or escape the quoted value.
  static String createToken({
    required BeamTokenMetadata metadata,
    required BigInt limit,
    String cid = kMinterContractId,
  }) {
    if (limit <= BigInt.zero || limit.bitLength > 128) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..2^128-1');
    }
    final text = metadata.encode();
    if (text.contains('"') || text.contains(r'\')) {
      throw ArgumentError.value(text, 'metadata', 'contains " or \\');
    }
    return _join('create_token', cid, {
      'limit': (limit & _maxU64).toString(),
      'limitHi': (limit >> 64).toString(),
      'metadata': '"$text"',
    });
  }

  /// `withdraw`: mint [value] of a token this wallet created.
  static String mint({
    required int assetId,
    required BigInt value,
    String cid = kMinterContractId,
  }) {
    if (assetId <= 0 || assetId > 0xffffffff) {
      throw ArgumentError.value(assetId, 'assetId', 'a CA id, 1..2^32-1');
    }
    if (value <= BigInt.zero || value > _maxU64) {
      throw ArgumentError.value(value, 'value', 'must be 1..2^64-1');
    }
    return _join('withdraw', cid, {'aid': '$assetId', 'value': '$value'});
  }

  static String _join(String action, String cid, Map<String, String> p) {
    if (!_cid.hasMatch(cid)) {
      throw ArgumentError.value(cid, 'cid', '64 lowercase hex chars');
    }
    return [
      'action=$action',
      'cid=$cid',
      for (final e in p.entries) '${e.key}=${e.value}',
    ].join(',');
  }
}
