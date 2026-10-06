/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_address.dart';
import 'beam_json.dart';

/// `TxStatus` (`wallet/core/common.h`). The number is what `tx_list`'s
/// `filter.status` takes.
enum BeamTxStatus {
  pending(0),
  inProgress(1),
  canceled(2),
  completed(3),
  failed(4),
  registering(5),
  confirming(6),
  unknown(-1);

  const BeamTxStatus(this.code);

  final int code;

  static BeamTxStatus fromCode(int code) => values.firstWhere(
    (s) => s.code == code && s != unknown,
    orElse: () => unknown,
  );
}

/// `TxType` (`BEAM_TX_TYPES_MAP`, `wallet/core/common.h`).
enum BeamTxType {
  simple(0),
  atomicSwap(1),
  assetIssue(2),
  assetConsume(3),
  assetReg(4),
  assetUnreg(5),
  assetInfo(6),
  pushTransaction(7),
  pullTransaction(8),
  voucherRequest(9),
  voucherResponse(10),
  unlinkFunds(11),
  contract(12),
  dexSimpleSwap(13),
  instantSbbsMessage(14),
  unknown(-1);

  const BeamTxType(this.code);

  final int code;

  static BeamTxType fromCode(int code) => values.firstWhere(
    (t) => t.code == code && t != unknown,
    orElse: () => unknown,
  );
}

/// A transaction as `tx_status`, `tx_list` and `ev_txs_changed` describe it
/// (`GetStatusResponseJson`, `v6_0/v6_api_parse.cpp`).
///
/// Which fields exist depends on the type: contract calls carry
/// [invokeData] and [feeOnly] but no [assetId] / [value]; atomic swaps carry
/// no [fee] / [income].
@immutable
class BeamTransaction {
  const BeamTransaction({
    required this.txId,
    required this.statusCode,
    required this.statusString,
    required this.txTypeCode,
    required this.txTypeString,
    required this.sender,
    required this.receiver,
    required this.comment,
    required this.createTime,
    this.assetId,
    this.value,
    this.fee,
    this.income,
    this.senderIdentity,
    this.receiverIdentity,
    this.kernel,
    this.failureReason,
    this.height,
    this.confirmations,
    this.addressType,
    this.appName,
    this.appId,
    this.feeOnly,
    this.invokeData = const [],
  });

  factory BeamTransaction.fromJson(Map<String, Object?> json) {
    final addressType = BeamJson.optString(json, 'address_type');
    return BeamTransaction(
      txId: BeamJson.string(json, 'txId'),
      statusCode: BeamJson.integer(json, 'status'),
      statusString: BeamJson.optString(json, 'status_string') ?? '',
      txTypeCode: BeamJson.integer(json, 'tx_type'),
      txTypeString: BeamJson.optString(json, 'tx_type_string') ?? '',
      sender: BeamJson.optString(json, 'sender') ?? '',
      receiver: BeamJson.optString(json, 'receiver') ?? '',
      comment: BeamJson.optString(json, 'comment') ?? '',
      createTime: BeamJson.integer(json, 'create_time'),
      assetId: BeamJson.optInt(json, 'asset_id'),
      value: BeamJson.optAmount(json, 'value'),
      fee: BeamJson.optAmount(json, 'fee'),
      income: BeamJson.optBool(json, 'income'),
      senderIdentity: BeamJson.nonEmpty(json, 'sender_identity'),
      receiverIdentity: BeamJson.nonEmpty(json, 'receiver_identity'),
      kernel: BeamJson.nonEmpty(json, 'kernel'),
      failureReason: BeamJson.nonEmpty(json, 'failure_reason'),
      height: BeamJson.optHeight(json, 'height'),
      confirmations: BeamJson.optHeight(json, 'confirmations'),
      addressType: addressType == null
          ? null
          : BeamAddressType.fromWire(addressType),
      appName: BeamJson.optString(json, 'appname'),
      appId: BeamJson.optString(json, 'appid'),
      feeOnly: BeamJson.optBool(json, 'fee_only'),
      invokeData: json['invoke_data'] == null
          ? const []
          : List.unmodifiable(
              BeamJson.mapList(
                json['invoke_data'],
                'invoke_data',
              ).map(BeamContractInvoke.fromJson),
            ),
    );
  }

  /// 32 hex characters.
  final String txId;
  final int statusCode;

  /// For display only: the wording depends on the tx type ("sent",
  /// "completed", "self sending", …). Branch on [status].
  final String statusString;
  final int txTypeCode;
  final String txTypeString;

  /// Peer addresses. Empty for contract calls.
  final String sender;
  final String receiver;
  final String comment;

  /// Unix seconds.
  final int createTime;

  /// Absent for contract calls; see [invokeData].
  final int? assetId;
  final BigInt? value;

  /// For a contract call this is the full fee the core computed (≥ 0.011
  /// BEAM), not a parameter anyone passed.
  final BigInt? fee;
  final bool? income;
  final String? senderIdentity;
  final String? receiverIdentity;
  final String? kernel;
  final String? failureReason;

  /// Proof height, once the kernel is on chain.
  final int? height;
  final int? confirmations;

  /// For push (shielded) transactions: which kind of address was paid.
  final BeamAddressType? addressType;
  final String? appName;
  final String? appId;

  /// Contract call that only paid the fee and moved no funds.
  final bool? feeOnly;
  final List<BeamContractInvoke> invokeData;

  BeamTxStatus get status => BeamTxStatus.fromCode(statusCode);
  BeamTxType get txType => BeamTxType.fromCode(txTypeCode);
  bool get isContract => txType == BeamTxType.contract;
  DateTime get createdAt => BeamJson.unixSeconds(createTime);
}

/// One contract invocation inside a contract transaction.
@immutable
class BeamContractInvoke {
  const BeamContractInvoke({required this.contractId, required this.amounts});

  factory BeamContractInvoke.fromJson(Map<String, Object?> json) =>
      BeamContractInvoke(
        contractId: BeamJson.string(json, 'contract_id'),
        amounts: List.unmodifiable(
          BeamJson.mapList(
            json['amounts'] ?? const <Object?>[],
            'amounts',
          ).map(BeamAssetAmount.fromJson),
        ),
      );

  final String contractId;
  final List<BeamAssetAmount> amounts;
}

/// A per-asset funds movement of a contract call. Positive leaves the wallet
/// (locked into the contract); negative arrives (unlocked from it).
@immutable
class BeamAssetAmount {
  const BeamAssetAmount({required this.assetId, required this.amount});

  factory BeamAssetAmount.fromJson(Map<String, Object?> json) =>
      BeamAssetAmount(
        assetId: BeamJson.integer(json, 'asset_id'),
        amount: BeamJson.amount(json, 'amount'),
      );

  final int assetId;
  final BigInt amount;
}
