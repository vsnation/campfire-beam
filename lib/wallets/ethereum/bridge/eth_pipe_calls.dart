/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bytes of the bridge's Ethereum side, with no network: the calls the
// wallet sends to a pipe and its token, the storage key that says whether
// the relayer has paid a BEAM-side message, and the reading of a lock's
// receipt. Every function here is pinned by tests against Foundry's `cast`
// and against the real lock of 2026-08-30 (msgId 222, 105 WBEAM).
//
// The pipes (BeamMW beam-bridge-ethpipe, `EthPipe.sol` / `ERC20Pipe.sol`):
//
//   sendFunds(uint256 value, uint256 relayerFee, bytes receiverBeamPubkey)
//     requires a 33-byte receiver and nothing else about it; takes
//     value + relayerFee (msg.value for ETH, transferFrom for a token, a
//     burn for WBEAM) and emits
//   NewLocalMessage(uint64 msgId, uint amount, uint relayerFee, bytes
//     receiver), every field in `data`.
//
// Neither the pipe nor the relayer checks that the receiver is a key
// anyone can sign for: five real crossings went to keys that are not on
// the curve and can never be claimed. So the wallet checks it here.

import 'dart:typed_data';

import '../../bridge/bridge_routes.dart';
import '../../bridge/bridge_sides.dart';
import '../uniswap/abi.dart';
import '../uniswap/uniswap_models.dart' show topicOfAddress;

const kSendFundsSelector = '0x4d5dd2bc';
const kApproveSelector = '0x095ea7b3';

/// keccak256("Transfer(address,address,uint256)").
const kErc20TransferTopic =
    '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

const kZeroAddress = '0x0000000000000000000000000000000000000000';

/// 2^256: an Ethereum amount must stay below it, or the pipe's unchecked
/// `value + relayerFee` (solc 0.7.2) wraps and nothing is deposited.
final BigInt kUint256Limit = BigInt.one << 256;

/// 2^63: the BEAM side keeps amounts in 64 bits; staying below 2^63 also
/// keeps them positive wherever they are a signed integer.
final BigInt kBeamAmountLimit = BigInt.one << 63;

/// secp256k1's field prime.
final BigInt _p = BigInt.parse(
  'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
  radix: 16,
);

/// Whether [key] is a BEAM public key the pipe can pay and its owner can
/// claim with: 33 bytes, an x on secp256k1, then a 00/01 parity byte (the
/// BEAM core's `X ‖ Y` form, as `get_pk` returns it).
bool isBeamReceiverKey(Uint8List key) {
  if (key.length != 33 || key[32] > 1) return false;
  final x = bytesToBigInt(key.sublist(0, 32));
  if (x >= _p) return false;
  // On the curve when x³ + 7 is a square mod p (Euler's criterion; it is
  // never zero on secp256k1).
  final rhs = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
  return rhs.modPow((_p - BigInt.one) >> 1, _p) == BigInt.one;
}

/// `sendFunds(value, fee, receiverKey)`.
Uint8List sendFundsCall(BigInt value, BigInt fee, Uint8List receiverKey) =>
    encodeCall(kBridgeSendFundsSignature, [value, fee, receiverKey]);

/// ERC-20 `approve(spender, amount)`.
Uint8List erc20ApproveCall(String spender, BigInt amount) =>
    encodeCall('approve(address,uint256)', [spender, amount]);

/// The storage key of `processed[msgId]` in a pipe whose
/// `mapping(uint64 => bool)` sits at [slot]:
/// keccak256(abi.encode(uint64 msgId, uint256 slot)), what
/// `cast index uint64 <msgId> <slot>` prints.
String processedKey(int msgId, int slot) {
  if (msgId < 0) throw ArgumentError('msgId $msgId');
  return bytesToHex(
    keccak(abiEncode('uint64,uint256', [BigInt.from(msgId), slot])),
  );
}

/// What a `NewLocalMessage` says.
class PipeMessage {
  const PipeMessage({
    required this.msgId,
    required this.amount,
    required this.relayerFee,
    required this.receiver,
  });

  final int msgId;
  final BigInt amount;
  final BigInt relayerFee;
  final Uint8List receiver;
}

/// Decodes a `NewLocalMessage` log's [data], refusing anything that is not
/// exactly what `abi.encode` would write for it (no trailing bytes, no
/// odd offsets), and an id beyond 2^53 (none exists; Dart's int on the
/// web stops being exact there).
PipeMessage decodePipeMessage(Uint8List data) {
  const types = 'uint64,uint256,uint256,bytes';
  final List<Object> v;
  try {
    v = abiDecode(types, data);
  } catch (_) {
    throw const FormatException('not a NewLocalMessage');
  }
  if (!_sameBytes(abiEncode(types, v), data)) {
    throw const FormatException('NewLocalMessage is not canonical');
  }
  final id = v[0] as BigInt;
  if (id > BigInt.two.pow(53)) {
    throw const FormatException('NewLocalMessage id out of range');
  }
  return PipeMessage(
    msgId: id.toInt(),
    amount: v[1] as BigInt,
    relayerFee: v[2] as BigInt,
    receiver: v[3] as Uint8List,
  );
}

/// Reads a mined lock from its receipt (`eth_getTransactionReceipt`, no
/// log search): reverted → `success: false`; otherwise it must be [owner]
/// calling [route]'s pipe, emitting exactly one `NewLocalMessage`, from
/// that pipe, naming exactly [value], [fee] and [receiverKey], and for a
/// token exactly one `Transfer` of value + fee from [owner] into the pipe
/// (WBEAM: burnt, to the zero address). Anything else throws
/// [BridgeException] (unexpectedTransaction): the controller must not
/// treat it as this crossing's lock.
EthPipeLock decodeLockReceipt(
  BridgeRoute route,
  Map<String, dynamic> receipt, {
  required String owner,
  required BigInt value,
  required BigInt fee,
  required Uint8List receiverKey,
}) {
  Never refuse(String why) => throw BridgeException(
    BridgeErrorCode.unexpectedTransaction,
    'This is not the bridge transaction that was sent: $why.',
  );

  final hash = receipt['transactionHash'];
  final block = receipt['blockNumber'];
  if (hash is! String || block is! String) refuse('no hash or block');
  final blockNumber = int.parse(block);
  if ((receipt['from'] as String?)?.toLowerCase() != owner.toLowerCase()) {
    refuse('it was sent from another address');
  }
  if ((receipt['to'] as String?)?.toLowerCase() != route.ethPipe) {
    refuse('it went to another contract, not the ${route.ethSymbol} pipe');
  }
  final status = receipt['status'];
  if (status == '0x0') {
    return EthPipeLock(hash: hash, success: false, blockNumber: blockNumber);
  }
  if (status != '0x1') refuse('its receipt has no status');

  final logs = [
    for (final l in (receipt['logs'] as List? ?? const []))
      (l as Map).cast<String, dynamic>(),
  ];
  String addressOf(Map<String, dynamic> l) =>
      (l['address'] as String).toLowerCase();
  List<String> topicsOf(Map<String, dynamic> l) => [
    for (final t in l['topics'] as List) (t as String).toLowerCase(),
  ];

  final messages = [
    for (final l in logs)
      if (topicsOf(l).firstOrNull == kBridgeNewLocalMessageTopic) l,
  ];
  if (messages.length != 1) {
    refuse('it records ${messages.length} bridge messages, not one');
  }
  final log = messages.single;
  if (addressOf(log) != route.ethPipe || topicsOf(log).length != 1) {
    refuse('its message comes from another contract');
  }
  final PipeMessage m;
  try {
    m = decodePipeMessage(hexToBytes(log['data'] as String));
  } on FormatException {
    refuse('its message cannot be read');
  }
  if (m.amount != value) refuse('it moves another amount');
  if (m.relayerFee != fee) refuse('it pays another bridge fee');
  if (!_sameBytes(m.receiver, receiverKey)) {
    refuse('it pays another BEAM wallet');
  }

  if (!route.isNativeEth) {
    // The pipe took exactly value + fee of the token: a token that keeps
    // a transfer fee (USDT can switch one on) would leave the pipe short
    // while the message still names the full amount.
    final transfers = [
      for (final l in logs)
        if (addressOf(l) == route.ethToken &&
            topicsOf(l).firstOrNull == kErc20TransferTopic)
          l,
    ];
    if (transfers.length != 1) {
      refuse('it moves ${route.ethSymbol} ${transfers.length} times');
    }
    final t = transfers.single;
    final topics = topicsOf(t);
    final into = route.isBeam ? kZeroAddress : route.ethPipe;
    final data = hexToBytes(t['data'] as String);
    if (topics.length != 3 ||
        topics[1] != topicOfAddress(owner) ||
        topics[2] != topicOfAddress(into) ||
        data.length != 32 ||
        bytesToBigInt(data) != value + fee) {
      refuse('the pipe did not take exactly the amount and the fee');
    }
  }
  return EthPipeLock(
    hash: hash,
    success: true,
    blockNumber: blockNumber,
    msgId: m.msgId,
  );
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
