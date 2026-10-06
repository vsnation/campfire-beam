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

/// Coin status, read from `status_string`.
///
/// Regular and shielded coins number their statuses differently
/// (`wallet_db.h`), so the number is never used to decide anything.
enum BeamUtxoStatus {
  unavailable('unavailable'),
  available('available'),
  maturing('maturing'),
  outgoing('outgoing'),
  incoming('incoming'),
  spent('spent'),
  consumed('consumed'),
  unknown('');

  const BeamUtxoStatus(this.wireName);

  final String wireName;

  static BeamUtxoStatus fromWire(String name) => values.firstWhere(
    (s) => s.wireName == name && s != unknown,
    orElse: () => unknown,
  );
}

/// A `get_utxo` entry.
@immutable
class BeamUtxo {
  const BeamUtxo({
    required this.id,
    required this.assetId,
    required this.amount,
    required this.type,
    required this.statusCode,
    required this.statusString,
    this.maturity,
    this.createTxId,
    this.spentTxId,
  });

  factory BeamUtxo.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    return BeamUtxo(
      id: id is int ? id.toString() : BeamJson.string(json, 'id'),
      assetId: BeamJson.integer(json, 'asset_id'),
      amount: BeamJson.amount(json, 'amount'),
      type: BeamJson.string(json, 'type'),
      statusCode: BeamJson.integer(json, 'status'),
      statusString: BeamJson.optString(json, 'status_string') ?? '',
      maturity: BeamJson.optHeight(json, 'maturity'),
      createTxId: BeamJson.nonEmpty(json, 'createTxId'),
      spentTxId: BeamJson.nonEmpty(json, 'spentTxId'),
    );
  }

  /// Coin id string for regular coins, TxoID for shielded ones.
  final String id;
  final int assetId;
  final BigInt amount;

  /// FourCC for regular coins (`norm`, `chng`, `fees`, `mine`, `treasury`),
  /// `shld` for shielded ones.
  final String type;
  final int statusCode;
  final String statusString;

  /// Null while the maturity height is not known yet.
  final int? maturity;
  final String? createTxId;
  final String? spentTxId;

  BeamUtxoStatus get status => BeamUtxoStatus.fromWire(statusString);
  bool get isShielded => type == 'shld';
}
