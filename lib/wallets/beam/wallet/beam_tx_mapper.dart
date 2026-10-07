/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import '../../../models/isar/models/blockchain_data/transaction.dart';
import '../../../models/isar/models/blockchain_data/v2/input_v2.dart';
import '../../../models/isar/models/blockchain_data/v2/output_v2.dart';
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../utilities/amount/amount.dart';
import '../models/beam_transaction.dart';

/// `TransactionV2.contractAddress` value that tags a Confidential Asset
/// transaction. Campfire filters the main (BEAM) history with
/// `contractAddress == null`, so asset transactions stay out of it until the
/// asset views (B-ASSET-1) show them with the asset's own decimals.
String beamAssetTag(int assetId) => 'beamAsset:$assetId';

/// Maps the core's transactions onto Campfire's [TransactionV2].
///
/// BEAM has no inputs/outputs Campfire could read, so — like Epic Cash
/// (`epiccash_wallet.dart:1411-1456`) — each transaction gets one input
/// (what left the wallet) and one output (what arrived or was paid), with
/// `walletOwns` set so Campfire's own arithmetic gives the right numbers:
///
/// * outgoing: input = value + fee (owned), output = value (not owned, the
///   recipient), so Campfire shows "sent: value";
/// * incoming: input = value (not owned, the sender), output = value
///   (owned): "received: value";
/// * sent to self: input = value + fee (owned), output = value (owned):
///   "received: value".
///
/// The fee this wallet paid goes into `overrideFee` (0 for incoming); the
/// fee the core reported is kept raw in `beamFee`.
///
/// Contract (dApp) transactions are shown in BEAM terms: the BEAM part of
/// the contract's funds movement plus the fee. Other assets' movements are
/// left to the asset views.
abstract final class BeamTxMapper {
  static TransactionV2 map(
    BeamTransaction tx, {
    required String walletId,
    required Set<String> ownAddresses,
    int fractionDigits = 8,
  }) {
    final status = tx.status;
    final fee = tx.fee ?? BigInt.zero;
    final assetId = tx.isContract ? 0 : (tx.assetId ?? 0);

    final TransactionType type;
    final BigInt sent; // left the wallet (excluding fee)
    final BigInt received; // arrived in the wallet
    var paidFee = fee;

    if (tx.isContract) {
      // Positive amounts leave the wallet (locked into the contract),
      // negative ones arrive (unlocked from it).
      var net = BigInt.zero;
      for (final invoke in tx.invokeData) {
        for (final a in invoke.amounts) {
          if (a.assetId == 0) net += a.amount;
        }
      }
      if (net < BigInt.zero) {
        type = TransactionType.incoming;
        sent = BigInt.zero;
        received = -net;
      } else {
        type = TransactionType.outgoing;
        sent = net;
        received = BigInt.zero;
      }
    } else {
      final value = tx.value ?? BigInt.zero;
      final income = tx.income ?? false;
      final toSelf =
          !income &&
          tx.receiver.isNotEmpty &&
          ownAddresses.contains(tx.receiver) &&
          (tx.sender.isEmpty || ownAddresses.contains(tx.sender));
      if (income) {
        type = TransactionType.incoming;
        sent = BigInt.zero;
        received = value;
        paidFee = BigInt.zero;
      } else if (toSelf) {
        type = TransactionType.sentToSelf;
        sent = BigInt.zero;
        received = value;
      } else {
        type = TransactionType.outgoing;
        sent = value;
        received = BigInt.zero;
      }
    }

    final InputV2 input;
    final OutputV2 output;
    switch (type) {
      case TransactionType.incoming:
        // A contract payout cost this wallet the fee: that is the input.
        input = _input(
          tx.isContract ? paidFee : received,
          owned: tx.isContract,
          address: tx.isContract ? null : tx.sender,
        );
        output = _output(received, owned: true, address: tx.receiver);
      case TransactionType.sentToSelf:
        input = _input(received + paidFee, owned: true, address: tx.sender);
        output = _output(received, owned: true, address: tx.receiver);
      default:
        input = _input(sent + paidFee, owned: true, address: tx.sender);
        output = _output(sent, owned: false, address: tx.receiver);
    }

    final completed = status == BeamTxStatus.completed;
    final otherData = <String, Object?>{
      TxV2OdKeys.isBeamTransaction: true,
      TxV2OdKeys.beamTxStatus: status.name,
      TxV2OdKeys.beamTxType: tx.txType.name,
      TxV2OdKeys.beamAssetId: assetId,
      TxV2OdKeys.beamKernelId: ?tx.kernel,
      if (tx.comment.isNotEmpty) TxV2OdKeys.beamComment: tx.comment,
      TxV2OdKeys.beamFailureReason: ?tx.failureReason,
      TxV2OdKeys.beamFee: '$fee',
      // No confirmation count: it grows with every block, and stored here it
      // would make every completed row differ from its copy in Isar on each
      // read, so the whole history was rewritten once a block. Screens work
      // it out from the height and the chain tip (BeamTxView.confirmationsAt).
      if (tx.isContract)
        TxV2OdKeys.beamContractIds: [
          for (final i in tx.invokeData) i.contractId,
        ],
      TxV2OdKeys.beamAppName: ?tx.appName,
      TxV2OdKeys.overrideFee: Amount(
        rawValue: paidFee,
        fractionDigits: fractionDigits,
      ).toJsonString(),
      TxV2OdKeys.isCancelled: status == BeamTxStatus.canceled,
      if (assetId != 0) TxV2OdKeys.contractAddress: beamAssetTag(assetId),
    };

    return TransactionV2(
      walletId: walletId,
      blockHash: null,
      hash: tx.txId,
      txid: tx.txId,
      timestamp: tx.createTime,
      // Only a completed transaction is final. Its proof height comes from
      // the core; a completed one without it (never seen) still counts as
      // confirmed, the way Epic does.
      height: completed ? (tx.height ?? 1) : null,
      inputs: List.unmodifiable([input]),
      outputs: List.unmodifiable([output]),
      version: 0,
      type: type,
      subType: TransactionSubType.none,
      otherData: jsonEncode(otherData),
    );
  }

  static InputV2 _input(BigInt value, {required bool owned, String? address}) =>
      InputV2.isarCantDoRequiredInDefaultConstructor(
        scriptSigHex: null,
        scriptSigAsm: null,
        sequence: null,
        outpoint: null,
        addresses: [if (address != null && address.isNotEmpty) address],
        valueStringSats: '$value',
        witness: null,
        innerRedeemScriptAsm: null,
        coinbase: null,
        walletOwns: owned,
      );

  static OutputV2 _output(
    BigInt value, {
    required bool owned,
    String? address,
  }) => OutputV2.isarCantDoRequiredInDefaultConstructor(
    scriptPubKeyHex: '00',
    valueStringSats: '$value',
    addresses: [if (address != null && address.isNotEmpty) address],
    walletOwns: owned,
  );

  /// True when [a] and [b] would show the same thing, so an unchanged
  /// transaction is not rewritten on every refresh.
  static bool same(TransactionV2 a, TransactionV2 b) =>
      a.txid == b.txid &&
      a.height == b.height &&
      a.type == b.type &&
      a.timestamp == b.timestamp &&
      a.otherData == b.otherData &&
      a.inputs.length == b.inputs.length &&
      a.outputs.length == b.outputs.length &&
      _inputsEqual(a.inputs, b.inputs) &&
      _outputsEqual(a.outputs, b.outputs);

  static bool _inputsEqual(List<InputV2> a, List<InputV2> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].valueStringSats != b[i].valueStringSats ||
          a[i].walletOwns != b[i].walletOwns) {
        return false;
      }
    }
    return true;
  }

  static bool _outputsEqual(List<OutputV2> a, List<OutputV2> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i].valueStringSats != b[i].valueStringSats ||
          a[i].walletOwns != b[i].walletOwns) {
        return false;
      }
    }
    return true;
  }
}
