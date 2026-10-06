/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../common/shader_output.dart';

/// The Minter's settings (`view_params`).
@immutable
class MinterParams {
  const MinterParams({required this.issueFee, required this.daoVaultCid});

  factory MinterParams.fromOutput(Map<String, Object?> out) {
    final r = ShaderOutput.map(out['res'], 'res');
    final cid = ShaderOutput.string(r, 'cidDaoVault');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(cid)) {
      throw const FormatException('cidDaoVault: not a contract id');
    }
    return MinterParams(
      issueFee: ShaderOutput.amount(r, 'tokenIssueFee'),
      daoVaultCid: cid,
    );
  }

  /// BEAM groth paid to the DAO vault for each new token. 50 BEAM on
  /// mainnet (explorer, 2026-10-06), but always read from here.
  final BigInt issueFee;

  /// Where the issuance fee goes.
  final String daoVaultCid;
}

/// A token the Minter manages (`view_owned` / `view_token`).
@immutable
class MinterToken {
  const MinterToken({
    required this.assetId,
    required this.minted,
    required this.limit,
    required this.isOwner,
    this.ownerKey,
    this.ownerCid,
    this.metadata,
  });

  /// One row; [assetId] is given for `view_token`, which prints no `aid`.
  /// [owned]: the row came from `view_owned`, which prints only this
  /// wallet's tokens and no `is_owner`.
  factory MinterToken.fromJson(
    Map<String, Object?> json, {
    int? assetId,
    bool owned = false,
  }) {
    BigInt big(String lo, String hi) =>
        (ShaderOutput.amount(json, hi) << 64) | ShaderOutput.amount(json, lo);
    final isOwner = json['is_owner'];
    return MinterToken(
      assetId: assetId ?? ShaderOutput.uint32(json, 'aid'),
      minted: big('mintedLo', 'mintedHi'),
      limit: big('limitLo', 'limitHi'),
      isOwner: owned || (isOwner is BigInt && isOwner == BigInt.one),
      ownerKey: ShaderOutput.optString(json, 'owner_pk'),
      ownerCid: ShaderOutput.optString(json, 'owner_cid'),
      metadata: ShaderOutput.optString(json, 'metadata'),
    );
  }

  /// `view_owned`: `{"res": [...]}`.
  static List<MinterToken> ownedFromOutput(Map<String, Object?> out) =>
      List.unmodifiable([
        for (final row in ShaderOutput.list(out['res'], 'res'))
          MinterToken.fromJson(ShaderOutput.map(row, 'res[]'), owned: true),
      ]);

  final int assetId;

  /// Minted so far and the ceiling, in the smallest unit (128-bit).
  final BigInt minted;
  final BigInt limit;

  /// This wallet can mint it (`withdraw`).
  final bool isOwner;
  final String? ownerKey;

  /// Set when another contract owns the token.
  final String? ownerCid;

  /// The asset's on-chain metadata. Untrusted: anyone can create an asset.
  final String? metadata;

  /// How much more can ever be minted.
  BigInt get mintable => limit > minted ? limit - minted : BigInt.zero;
}
