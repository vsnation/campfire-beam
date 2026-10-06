/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'voucher_code.dart';

/// Where a created batch's codes live. The app implements it on Campfire's
/// secure storage (encrypted, included in the wallet backup), never in a
/// cache, a log or plain preferences.
///
/// The codes are the only key to the locked funds: redeeming needs a code,
/// and handing the airdrop out needs all of them. LightWallet kept them in
/// browser storage and once wrote them only after broadcasting, so a crash
/// in between stranded funds for good. The rules here:
///
/// * `BeamAirdropService` calls [put] with every code **before** it
///   broadcasts the batch, and does not broadcast if [put] throws.
/// * Nothing in this module ever calls [delete] on its own. The service
///   offers `forgetSavedBatch` only for batches that can no longer hold
///   funds, and only on an explicit user request.
abstract class VoucherCodeStore {
  /// Inserts or replaces [batch] by [AirdropSavedBatch.localId]. Completes
  /// only once the write is durable (flushed to disk): the service
  /// broadcasts right after.
  Future<void> put(AirdropSavedBatch batch);

  /// Every saved batch, any order.
  Future<List<AirdropSavedBatch>> all();

  /// Removes one batch. Only for `BeamAirdropService.forgetSavedBatch`.
  Future<void> delete(String localId);
}

/// Where a saved batch's transaction stands.
enum AirdropBatchTxStatus {
  /// Codes saved; the transaction was not sent, or sending it failed in a
  /// way that does not prove it never reached the network (a timeout, a
  /// lost connection). Never treat this as "nothing happened" without
  /// checking the contract: the codes may lock real funds.
  unconfirmed,

  /// Sent; [AirdropSavedBatch.txId] is known; not yet confirmed.
  broadcast,

  /// The transaction completed: the vouchers exist on chain.
  confirmed,

  /// The core reports the transaction failed or was cancelled: no funds
  /// were locked by it.
  failed,
}

/// What is known about one code, from `check_voucher`.
enum AirdropCodeStatus {
  /// Not checked yet (or the batch is not confirmed).
  unknown,

  /// On chain and unclaimed.
  available,

  /// Redeemed by someone.
  claimed,

  /// The contract has no voucher for it: never created, or cancelled.
  notFound,
}

/// One saved code.
@immutable
class AirdropSavedCode {
  const AirdropSavedCode({
    required this.code,
    required this.hashHex,
    required this.value,
    this.status = AirdropCodeStatus.unknown,
  });

  factory AirdropSavedCode.fromJson(Map<String, Object?> json) {
    final code = json['code'];
    final hash = json['hash'];
    final value = json['value'];
    final status = json['status'];
    if (code is! String || hash is! String || value is! String) {
      throw const FormatException('saved code: missing field');
    }
    final parsed = BigInt.tryParse(value);
    if (parsed == null || parsed <= BigInt.zero) {
      throw const FormatException('saved code: bad value');
    }
    if (AirdropVoucherCode.normalise(code).isEmpty ||
        AirdropVoucherCode.hashHex(code) != hash) {
      throw const FormatException('saved code: hash does not match code');
    }
    return AirdropSavedCode(
      code: AirdropVoucherCode.format(code),
      hashHex: hash,
      value: parsed,
      status: AirdropCodeStatus.values.firstWhere(
        (s) => s.name == status,
        orElse: () => AirdropCodeStatus.unknown,
      ),
    );
  }

  /// Formatted, `XXXX-XXXX-XXXX-XXXX`. Secret.
  final String code;
  final String hashHex;
  final BigInt value;
  final AirdropCodeStatus status;

  AirdropSavedCode withStatus(AirdropCodeStatus s) =>
      AirdropSavedCode(code: code, hashHex: hashHex, value: value, status: s);

  /// Amounts as decimal strings: JSON numbers lose precision above 2^53.
  Map<String, Object?> toJson() => {
    'code': code,
    'hash': hashHex,
    'value': value.toString(),
    'status': status.name,
  };

  @override
  String toString() => 'AirdropSavedCode(<secret>, $hashHex, $value)';
}

/// A batch this wallet created or tried to create, with its codes.
@immutable
class AirdropSavedBatch {
  AirdropSavedBatch({
    required this.localId,
    required this.contractId,
    required this.assetId,
    required List<AirdropSavedCode> codes,
    required this.createdAt,
    this.txId,
    this.txStatus = AirdropBatchTxStatus.unconfirmed,
  }) : codes = List.unmodifiable(codes) {
    if (codes.isEmpty) throw ArgumentError.value(codes, 'codes', 'empty');
  }

  factory AirdropSavedBatch.fromJson(Map<String, Object?> json) {
    final id = json['localId'];
    final cid = json['contractId'];
    final aid = json['assetId'];
    final created = json['createdAt'];
    final tx = json['txId'];
    final status = json['txStatus'];
    final codes = json['codes'];
    if (id is! String ||
        cid is! String ||
        aid is! int ||
        created is! String ||
        codes is! List) {
      throw const FormatException('saved batch: missing field');
    }
    return AirdropSavedBatch(
      localId: id,
      contractId: cid,
      assetId: aid,
      createdAt: DateTime.parse(created).toUtc(),
      txId: tx is String ? tx : null,
      txStatus: AirdropBatchTxStatus.values.firstWhere(
        (s) => s.name == status,
        // An unreadable status must not look settled.
        orElse: () => AirdropBatchTxStatus.unconfirmed,
      ),
      codes: [
        for (final c in codes)
          AirdropSavedCode.fromJson(
            c is Map ? c.cast<String, Object?>() : const {},
          ),
      ],
    );
  }

  /// This wallet's id for the record (not the on-chain batch id, which is
  /// only known after confirmation).
  final String localId;
  final String contractId;
  final int assetId;
  final List<AirdropSavedCode> codes;
  final DateTime createdAt;
  final String? txId;
  final AirdropBatchTxStatus txStatus;

  int get count => codes.length;

  BigInt get total => codes.fold(BigInt.zero, (s, c) => s + c.value);

  AirdropSavedBatch copyWith({
    String? txId,
    AirdropBatchTxStatus? txStatus,
    List<AirdropSavedCode>? codes,
  }) => AirdropSavedBatch(
    localId: localId,
    contractId: contractId,
    assetId: assetId,
    codes: codes ?? this.codes,
    createdAt: createdAt,
    txId: txId ?? this.txId,
    txStatus: txStatus ?? this.txStatus,
  );

  Map<String, Object?> toJson() => {
    'localId': localId,
    'contractId': contractId,
    'assetId': assetId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'txId': txId,
    'txStatus': txStatus.name,
    'codes': [for (final c in codes) c.toJson()],
  };

  @override
  String toString() =>
      'AirdropSavedBatch($localId, asset $assetId, $count codes, '
      '${txStatus.name})';
}

/// CSV export of a batch's codes, columns `Number,Code,Value,Asset,Status`
/// as in LightWallet.
abstract final class AirdropCsv {
  static const header = 'Number,Code,Value,Asset,Status';

  /// [formatValue] renders an amount with the asset's own decimals;
  /// [assetLabel] is its ticker. Both can come from untrusted asset
  /// metadata, so every cell is quoted when needed and a cell that a
  /// spreadsheet would run as a formula (`=`, `+`, `-`, `@`, tab, CR) is
  /// prefixed with `'`.
  static String export(
    AirdropSavedBatch batch, {
    required String Function(BigInt amount) formatValue,
    required String assetLabel,
  }) {
    final out = StringBuffer('$header\r\n');
    for (var i = 0; i < batch.codes.length; i++) {
      final c = batch.codes[i];
      out
        ..write(
          [
            '${i + 1}',
            c.code,
            formatValue(c.value),
            assetLabel,
            c.status.name,
          ].map(cell).join(','),
        )
        ..write('\r\n');
    }
    return out.toString();
  }

  /// One RFC 4180 cell, defused against spreadsheet formula injection.
  static String cell(String value) {
    var v = value;
    if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
    if (v.contains(RegExp('[",\r\n]'))) {
      v = '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
}
