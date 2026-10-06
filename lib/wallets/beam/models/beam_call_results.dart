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

/// `calc_change`: what a send of a given amount would cost and return. The
/// confirmation screen shows [explicitFee] from here, never a constant.
@immutable
class BeamCalcChange {
  const BeamCalcChange({
    required this.change,
    required this.assetChange,
    required this.explicitFee,
  });

  factory BeamCalcChange.fromJson(Map<String, Object?> json) => BeamCalcChange(
    change: BeamJson.amount(json, 'change'),
    assetChange: BeamJson.amount(json, 'asset_change'),
    explicitFee: BeamJson.amount(json, 'explicit_fee'),
  );

  /// BEAM change.
  final BigInt change;

  /// Change in the sent asset (equals [change] for BEAM sends).
  final BigInt assetChange;
  final BigInt explicitFee;
}

/// `verify_payment_proof` result.
@immutable
class BeamPaymentProofInfo {
  const BeamPaymentProofInfo({
    required this.isValid,
    required this.sender,
    required this.receiver,
    required this.amount,
    required this.kernel,
    required this.assetId,
  });

  factory BeamPaymentProofInfo.fromJson(Map<String, Object?> json) =>
      BeamPaymentProofInfo(
        isValid: BeamJson.boolean(json, 'is_valid'),
        sender: BeamJson.string(json, 'sender'),
        receiver: BeamJson.string(json, 'receiver'),
        amount: BeamJson.amount(json, 'amount'),
        kernel: BeamJson.string(json, 'kernel'),
        assetId: BeamJson.optInt(json, 'asset_id') ?? 0,
      );

  final bool isValid;
  final String sender;
  final String receiver;
  final BigInt amount;
  final String kernel;
  final int assetId;
}

/// `invoke_contract` result.
///
/// With `create_tx: true` the core built and sent a transaction ([txId]);
/// with `create_tx: false` it returns [rawData] for `process_invoke_data`,
/// which is where a confirmation step belongs.
@immutable
class BeamInvokeResult {
  const BeamInvokeResult({required this.output, this.txId, this.rawData});

  factory BeamInvokeResult.fromJson(Map<String, Object?> json) {
    final raw = json['raw_data'];
    return BeamInvokeResult(
      output: BeamJson.optString(json, 'output') ?? '',
      txId: BeamJson.nonEmpty(json, 'txid'),
      rawData: raw == null
          ? null
          : List<int>.unmodifiable(
              BeamJson.list(raw, 'raw_data').map((b) {
                if (b is int && b >= 0 && b < 256) return b;
                throw const FormatException('raw_data: expected bytes');
              }),
            ),
    );
  }

  /// The app shader's output, usually JSON text.
  final String output;
  final String? txId;
  final List<int>? rawData;
}
