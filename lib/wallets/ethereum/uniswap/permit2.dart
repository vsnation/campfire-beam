/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Permit2, the way Uniswap's router is allowed to take a token:
//
// 1. Once per token and amount, the token is approved to Permit2 — an
//    ordinary on-chain `approve`, for exactly the amount being swapped
//    (never "unlimited").
// 2. For each swap the wallet signs a PermitSingle: this router may take
//    this amount of this token until a time half an hour away. The
//    signature travels inside the swap transaction (the router's
//    PERMIT2_PERMIT command), so it costs no extra transaction, and it is
//    worthless after the swap or after the half hour.
//
// The signature is EIP-712 over Permit2's own domain; the digest is built
// here and checked in tests against Permit2's DOMAIN_SEPARATOR() on chain.

import 'dart:typed_data';

import 'abi.dart';
import 'eth_rpc.dart';
import 'uniswap_constants.dart';

/// keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)").
final Uint8List kPermitDetailsTypeHash = keccak(
  Uint8List.fromList(
    'PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)'
        .codeUnits,
  ),
);

/// keccak256 of PermitSingle's type string (with PermitDetails appended).
final Uint8List kPermitSingleTypeHash = keccak(
  Uint8List.fromList(
    ('PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)'
            'PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)')
        .codeUnits,
  ),
);

/// Permit2's EIP-712 domain separator on [chainId] (it has no version).
Uint8List permit2DomainSeparator({int chainId = kEthChainId}) => keccak(
  abiEncode('bytes32,bytes32,uint256,address', [
    keccak(
      Uint8List.fromList(
        'EIP712Domain(string name,uint256 chainId,address verifyingContract)'
            .codeUnits,
      ),
    ),
    keccak(Uint8List.fromList('Permit2'.codeUnits)),
    chainId,
    UniswapAddresses.permit2,
  ]),
);

/// What the wallet signs to let [spender] take [amount] of [token].
class PermitSingle {
  const PermitSingle({
    required this.token,
    required this.amount,
    required this.expiration,
    required this.nonce,
    required this.spender,
    required this.sigDeadline,
  });

  final String token;
  final BigInt amount;
  final int expiration;
  final int nonce;
  final String spender;
  final BigInt sigDeadline;

  /// The tuple ((token, amount, expiration, nonce), spender, sigDeadline).
  List<Object> get tuple => [
    [token, amount, expiration, nonce],
    spender,
    sigDeadline,
  ];

  /// The EIP-712 digest the wallet signs.
  Uint8List digest({int chainId = kEthChainId}) {
    final details = keccak(
      abiEncode('bytes32,address,uint160,uint48,uint48', [
        kPermitDetailsTypeHash,
        token,
        amount,
        expiration,
        nonce,
      ]),
    );
    final structHash = keccak(
      abiEncode('bytes32,bytes32,address,uint256', [
        kPermitSingleTypeHash,
        details,
        spender,
        sigDeadline,
      ]),
    );
    return keccak(
      Uint8List.fromList([
        0x19,
        0x01,
        ...permit2DomainSeparator(chainId: chainId),
        ...structHash,
      ]),
    );
  }
}

/// A [PermitSingle] with its 65-byte signature (r ‖ s ‖ v).
class SignedPermit {
  const SignedPermit(this.permit, this.signature);

  final PermitSingle permit;
  final Uint8List signature;

  /// The router's PERMIT2_PERMIT input: abi.encode(PermitSingle, bytes).
  Uint8List get routerInput => abiEncode(
    '((address,uint160,uint48,uint48),address,uint256),bytes',
    [permit.tuple, signature],
  );
}

/// What Permit2 currently lets the router take.
class Permit2Allowance {
  const Permit2Allowance(this.amount, this.expiration, this.nonce);

  final BigInt amount;
  final int expiration;
  final int nonce;

  /// Covers [needed] for at least another [margin] seconds after [now].
  bool covers(BigInt needed, int now, {int margin = 120}) =>
      amount >= needed && expiration > now + margin;
}

class Permit2Reader {
  const Permit2Reader(this.rpc);

  final EthRpc rpc;

  /// ERC-20 allowance of [owner] to Permit2.
  Future<BigInt> tokenAllowance(String token, String owner) async {
    final r = await rpc.ethCall(
      token,
      encodeCall('allowance(address,address)', [
        owner,
        UniswapAddresses.permit2,
      ]),
    );
    return abiDecode('uint256', r)[0] as BigInt;
  }

  /// Permit2's allowance of [owner]'s [token] to [spender].
  Future<Permit2Allowance> permitAllowance(
    String token,
    String owner, {
    String spender = UniswapAddresses.universalRouter,
  }) async {
    final r = await rpc.ethCall(
      UniswapAddresses.permit2,
      encodeCall('allowance(address,address,address)', [owner, token, spender]),
    );
    final d = abiDecode('uint160,uint48,uint48', r);
    return Permit2Allowance(
      d[0] as BigInt,
      (d[1] as BigInt).toInt(),
      (d[2] as BigInt).toInt(),
    );
  }
}

/// `approve(Permit2, amount)` calldata for [token].
Uint8List approvePermit2Call(BigInt amount) =>
    encodeCall('approve(address,uint256)', [UniswapAddresses.permit2, amount]);
