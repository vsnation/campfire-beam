/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The two halves of a crossing, as the bridge controller sees them: what it
// asks of the user's BEAM wallet ([BeamPipeSide], implemented over the BEAM
// core's shader calls) and of the user's Ethereum wallet ([EthPipeSide],
// over the wallet's own RPC). Neither half moves anything on its own: every
// transaction is built, checked against the request, and only sent when
// the controller says so, after the user's PIN.

import 'dart:typed_data';

import '../ethereum/uniswap/uniswap_service.dart' show UniFees, UniTxRequest;
import 'bridge_fees.dart';
import 'bridge_routes.dart';

/// Something the bridge cannot do right now and the user must be told.
class BridgeException implements Exception {
  const BridgeException(this.code, this.message);

  final BridgeErrorCode code;
  final String message;

  @override
  String toString() => 'BridgeException(${code.name}): $message';
}

enum BridgeErrorCode {
  /// A token involved is paused, or the pipe is blacklisted, or USDT
  /// charges a transfer fee: nothing may be sent.
  frozen,

  /// Prices or gas could not be read (fail closed: no quote).
  noPrice,

  /// The node or RPC did not answer.
  network,

  /// A built transaction does not match the request (refused, not sent).
  unexpectedTransaction,

  /// An amount is zero, too large, off its grid, or would overflow.
  badAmount,

  /// The BEAM pipe gave an answer that is not what that pipe gives (the
  /// wrong contract, or a shader error).
  badPipe,

  /// A prepared transaction was already sent once.
  alreadySent,
}

// ------------------------------------------------------------------ BEAM

/// A b2e message the BEAM pipe recorded (`local_msg`).
class BeamPipeLocalMessage {
  const BeamPipeLocalMessage({
    required this.receiver,
    required this.amount,
    required this.relayerFee,
    required this.height,
  });

  /// The Ethereum address paid, `0x` + 40 lowercase hex.
  final String receiver;
  final BigInt amount;
  final BigInt relayerFee;
  final int height;
}

/// An e2b message the relayer pushed and nobody has claimed yet
/// (`remote_msg`).
class BeamPipeRemoteMessage {
  const BeamPipeRemoteMessage({
    required this.amount,
    required this.relayerFee,
    required this.receiver,
  });

  /// In groth (already truncated from Ethereum units by the relayer).
  final BigInt amount;
  final BigInt relayerFee;

  /// The 33-byte key it pays.
  final Uint8List receiver;
}

/// An e2b message waiting for this wallet's key (`view_incoming`; the
/// shader spells the id `MsgId`).
class BeamPipeIncoming {
  const BeamPipeIncoming(this.msgId, this.amount);

  final int msgId;
  final BigInt amount;
}

enum BeamPipeCall { send, receive }

/// A BEAM transaction built and checked, not sent.
class BeamPipePrepared {
  BeamPipePrepared({
    required this.route,
    required this.call,
    required this.rawData,
    required this.networkFee,
    required this.amount,
    required this.relayerFee,
    this.ethReceiver,
    this.msgId,
  });

  final BridgeRoute route;
  final BeamPipeCall call;

  /// What `process_invoke_data` sends.
  final List<int> rawData;

  /// The BEAM network fee, read from the built transaction.
  final BigInt networkFee;

  /// send: the amount paid on Ethereum (groth); receive: what is claimed.
  final BigInt amount;

  /// send: the relayer fee locked with it; receive: zero.
  final BigInt relayerFee;

  /// send only.
  final String? ethReceiver;

  /// receive only.
  final int? msgId;

  bool sent = false;
}

/// Where a BEAM transaction is.
class BeamPipeTxStatus {
  const BeamPipeTxStatus._(this.state, this.height, this.reason);

  const BeamPipeTxStatus.pending()
    : this._(BeamPipeTxState.pending, null, null);

  const BeamPipeTxStatus.completed(int height)
    : this._(BeamPipeTxState.completed, height, null);

  const BeamPipeTxStatus.failed(String reason)
    : this._(BeamPipeTxState.failed, null, reason);

  final BeamPipeTxState state;

  /// The block it was mined in (completed only).
  final int? height;
  final String? reason;
}

enum BeamPipeTxState { pending, completed, failed }

/// The user's BEAM wallet, as the bridge needs it.
abstract class BeamPipeSide {
  /// The 33-byte key [route]'s pipe pays e2b crossings into this wallet
  /// with (`get_pk`): checked to be 33 bytes with a 00/01 parity byte.
  Future<Uint8List> receiveKey(BridgeRoute route);

  /// How many b2e messages [route]'s pipe has recorded (ids start at 1).
  Future<int> localMessageCount(BridgeRoute route);

  /// b2e message [msgId], or null when there is none.
  Future<BeamPipeLocalMessage?> localMessage(BridgeRoute route, int msgId);

  /// e2b message [msgId] if pushed and not yet claimed, else null.
  Future<BeamPipeRemoteMessage?> remoteMessage(BridgeRoute route, int msgId);

  /// e2b messages waiting for this wallet's key, from [startFrom] on.
  Future<List<BeamPipeIncoming>> incoming(
    BridgeRoute route, {
    int startFrom = 0,
  });

  /// Builds the b2e `send` and checks the built transaction: one call, to
  /// [route]'s pipe, method [BridgeRoute.sendMethod], arguments exactly
  /// receiver ‖ amount ‖ fee, no signature, spending [amount] + [fee] of
  /// the route's asset. Nothing is sent.
  Future<BeamPipePrepared> prepareSend(
    BridgeRoute route, {
    required String ethReceiver,
    required BigInt amount,
    required BigInt fee,
  });

  /// Builds the e2b claim of [msgId] and checks it: one call, method
  /// [BridgeRoute.receiveMethod], argument the message id, one signature,
  /// receiving exactly [amount] of the route's asset. Nothing is sent.
  Future<BeamPipePrepared> prepareReceive(
    BridgeRoute route, {
    required int msgId,
    required BigInt amount,
  });

  /// Sends [prepared] (at most once, even if this throws) and returns the
  /// BEAM transaction id.
  Future<String> execute(BeamPipePrepared prepared);

  Future<BeamPipeTxStatus> txStatus(String txId);

  /// The chain tip the wallet knows.
  Future<int> tipHeight();

  /// Spendable groth of BEAM asset [assetId].
  Future<BigInt> available(int assetId);
}

// -------------------------------------------------------------- Ethereum

/// Why a route cannot be used now.
class BridgeFreeze {
  const BridgeFreeze(this.reason);

  /// For people: "WBEAM is paused by its issuer".
  final String reason;
}

/// The Ethereum transactions an e2b lock needs, priced.
class EthPipeLockPlan {
  const EthPipeLockPlan({
    required this.route,
    required this.value,
    required this.fee,
    required this.receiverKey,
    required this.steps,
    required this.fees,
  });

  final BridgeRoute route;

  /// What the user receives on BEAM, in Ethereum units (on the grid).
  final BigInt value;

  /// The relayer fee, in Ethereum units.
  final BigInt fee;

  final Uint8List receiverKey;

  /// In order: a reset of a non-zero allowance (USDT), an exact approval,
  /// then `sendFunds`. Only `sendFunds` for ETH or when the allowance
  /// already covers value + fee.
  final List<UniTxRequest> steps;

  final UniFees fees;

  /// What all steps can cost at most.
  BigInt get maxGasCost => steps.fold(BigInt.zero, (s, t) => s + t.maxGasCost);

  /// What they will most likely cost.
  BigInt get expectedGasCost =>
      steps.fold(BigInt.zero, (s, t) => s + t.expectedGasCost);
}

/// A mined `sendFunds`, read back from its receipt.
class EthPipeLock {
  const EthPipeLock({
    required this.hash,
    required this.success,
    required this.blockNumber,
    this.msgId,
  });

  final String hash;

  /// False when the transaction reverted (nothing was locked).
  final bool success;
  final int blockNumber;

  /// The Ethereum-side message id from the pipe's event (success only).
  final int? msgId;
}

/// The user's Ethereum wallet, as the bridge needs it.
abstract class EthPipeSide {
  /// The wallet's address, `0x` + 40 lowercase hex.
  String get owner;

  /// Why [route] cannot be used now; empty when it can. Throws a
  /// [BridgeException] (frozen or network) when it cannot tell: the
  /// caller refuses rather than risks a payout that cannot be made.
  Future<List<BridgeFreeze>> freezes(BridgeRoute route);

  /// The relayer's gas price, from `eth_feeHistory`.
  Future<BridgeRelayerGas> relayerGas();

  /// USD prices for [coingeckoIds] (through Tor when Tor is on).
  Future<BridgePrices> prices(List<String> coingeckoIds);

  /// The wallet's balance of [route]'s Ethereum asset (wei for ETH).
  Future<BigInt> balance(BridgeRoute route);

  /// The wallet's ETH, for gas.
  Future<BigInt> ethBalance();

  /// Prices the transactions locking [value] + [fee] in [route]'s pipe
  /// for [receiverKey]. Refuses (badAmount) a value that is zero, a value
  /// or fee off the grid, or a sum that would overflow either chain. A
  /// zero fee is allowed (the relayer does not check it going to BEAM).
  Future<EthPipeLockPlan> planLock(
    BridgeRoute route, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  });

  /// Signs and broadcasts [tx] with the wallet's key; returns its hash as
  /// soon as it is broadcast.
  Future<String> send(UniTxRequest tx);

  /// Whether an approval transaction [hash] is mined: null while pending.
  Future<bool?> succeeded(String hash);

  /// The lock [hash] once mined (null while pending). Its event must come
  /// from [route]'s pipe and name exactly [value], [fee] and
  /// [receiverKey], or this throws (unexpectedTransaction).
  Future<EthPipeLock?> lockResult(
    BridgeRoute route,
    String hash, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  });

  /// Whether the relayer has paid BEAM-side message [beamMsgId] on
  /// Ethereum (one storage read of the pipe).
  Future<bool> isPaid(BridgeRoute route, int beamMsgId);
}
