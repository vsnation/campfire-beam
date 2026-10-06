/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_json.dart';

/// Address (token) types as wallet-api names them (`_ttypesMap`,
/// `v6_0/v6_api.cpp`).
enum BeamAddressType {
  /// Hex SBBS address. Interactive: the receiver must be online.
  regular('regular'),

  /// Base58 token with the identity (needed for payment proofs).
  regularNew('regular_new'),

  /// Base58 token with one-time shielded vouchers. Sent as an online tx
  /// unless `tx_send` passes `offline: true`.
  offline('offline'),

  /// Single-use shielded address.
  maxPrivacy('max_privacy'),

  /// Reusable, publishable shielded address.
  publicOffline('public_offline'),

  unknown('unknown');

  const BeamAddressType(this.wireName);

  final String wireName;

  static BeamAddressType fromWire(String name) => values.firstWhere(
    (t) => t.wireName == name,
    orElse: () => unknown,
  );
}

/// `expiration` values accepted by `create_address` / `edit_address`.
enum BeamAddressExpiration {
  expired('expired'),
  hours24('24h'),
  auto('auto'),
  never('never');

  const BeamAddressExpiration(this.wireName);

  final String wireName;
}

/// An `addr_list` entry.
@immutable
class BeamAddress {
  const BeamAddress({
    required this.address,
    required this.type,
    required this.own,
    required this.expired,
    required this.comment,
    required this.category,
    required this.createTime,
    required this.duration,
    required this.walletId,
    this.identity,
    this.ownId,
  });

  factory BeamAddress.fromJson(Map<String, Object?> json) => BeamAddress(
    address: BeamJson.string(json, 'address'),
    type: BeamAddressType.fromWire(BeamJson.optString(json, 'type') ?? ''),
    own: BeamJson.boolean(json, 'own'),
    expired: BeamJson.boolean(json, 'expired'),
    comment: BeamJson.optString(json, 'comment') ?? '',
    category: BeamJson.optString(json, 'category') ?? '',
    createTime: BeamJson.integer(json, 'create_time'),
    duration: BeamJson.integer(json, 'duration'),
    walletId: BeamJson.string(json, 'wallet_id'),
    identity: BeamJson.nonEmpty(json, 'identity'),
    ownId: BeamJson.optAmount(json, 'own_id'),
  );

  /// The token a payer uses: hex for [BeamAddressType.regular], base58
  /// otherwise.
  final String address;
  final BeamAddressType type;
  final bool own;
  final bool expired;
  final String comment;
  final String category;

  /// Unix seconds.
  final int createTime;

  /// Lifetime in seconds from [createTime]; 0 means it never expires.
  final int duration;

  /// The SBBS address (hex) underneath the token.
  final String walletId;

  /// The endpoint key; absent for contacts the wallet knows only by SBBS.
  final String? identity;

  /// Key-derivation index of an own address (uint64).
  final BigInt? ownId;

  DateTime get createdAt => BeamJson.unixSeconds(createTime);

  /// Null when the address never expires.
  DateTime? get expiresAt => duration == 0
      ? null
      : BeamJson.unixSeconds(createTime + duration);
}

/// `validate_address` result.
@immutable
class BeamAddressValidation {
  const BeamAddressValidation({
    required this.isValid,
    required this.isMine,
    required this.type,
    this.payments,
  });

  factory BeamAddressValidation.fromJson(Map<String, Object?> json) =>
      BeamAddressValidation(
        isValid: BeamJson.boolean(json, 'is_valid'),
        isMine: BeamJson.boolean(json, 'is_mine'),
        type: BeamAddressType.fromWire(BeamJson.optString(json, 'type') ?? ''),
        payments: BeamJson.optInt(json, 'payments'),
      );

  /// The token parses and its key is a valid point; for an own address it is
  /// also not expired.
  final bool isValid;
  final bool isMine;
  final BeamAddressType type;

  /// Offline tokens only: vouchers now stored for it. Validating an offline
  /// token writes its vouchers into the wallet, although the call is "read".
  final int? payments;
}
