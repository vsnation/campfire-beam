/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A copy of Ethereum mainnet on this machine (Foundry's anvil) for the
// Uniswap tests: real pools, real router, real tokens, fake money.
//
//   anvil --fork-url <an archive-capable RPC> --port 8545 --chain-id 1
//
// Tests that need it skip themselves when nothing answers on 8545
// (override with CFB_ETH_FORK_URL).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';
import 'package:wallet/wallet.dart' as eth_wallet;
import 'package:web3dart/web3dart.dart' as web3;

String get forkUrl =>
    Platform.environment['CFB_ETH_FORK_URL'] ?? 'http://127.0.0.1:8545';

/// A fork reads each contract's state from its source node the first time,
/// so one big multicall can take minutes; a real node answers in a second.
EthRpc forkRpc() => EthRpc(
  url: forkUrl,
  clientFactory: http.Client.new,
  timeout: const Duration(minutes: 8),
);

/// Null when the fork answers as mainnet; else why the tests skip.
Future<String?> forkUnavailable() async {
  try {
    final id = await forkRpc().chainId();
    return id == 1 ? null : 'the fork at $forkUrl is chain $id, not 1';
  } catch (e) {
    return 'no mainnet fork at $forkUrl ($e)';
  }
}

/// A fresh key with [eth] ETH on the fork (never an address that exists on
/// mainnet: some well-known test keys carry EIP-7702 code there, and
/// Permit2 then refuses their signatures).
class ForkSigner implements UniSwapSigner {
  ForkSigner._(this._key);

  static Future<ForkSigner> funded({BigInt? eth}) async {
    final s = ForkSigner._(web3.EthPrivateKey.createRandom(_random));
    await forkRpc().call('anvil_setBalance', [
      s.address,
      '0x${(eth ?? BigInt.from(10).pow(19)).toRadixString(16)}',
    ]);
    return s;
  }

  static final _random = Random.secure();

  final web3.EthPrivateKey _key;

  @override
  String get address => _key.address.eip55With0x.toLowerCase();

  @override
  Future<Uint8List> signDigest(Uint8List digest) async {
    final sig = web3.sign(digest, _key.privateKey);
    return Uint8List.fromList([..._pad32(sig.r), ..._pad32(sig.s), sig.v]);
  }

  @override
  Future<String> send(UniTxRequest tx) async {
    final client = web3.Web3Client(forkUrl, http.Client());
    try {
      return await client.sendTransaction(
        _key,
        web3.Transaction(
          to: eth_wallet.EthereumAddress.fromHex(tx.to),
          data: tx.data,
          value: eth_wallet.EtherAmount.inWei(tx.value),
          maxGas: tx.gasLimit.toInt(),
          maxFeePerGas: eth_wallet.EtherAmount.inWei(tx.fees.maxFeePerGas),
          maxPriorityFeePerGas: eth_wallet.EtherAmount.inWei(
            tx.fees.maxPriorityFeePerGas,
          ),
        ),
        chainId: 1,
      );
    } finally {
      await client.dispose();
    }
  }

  static Uint8List _pad32(BigInt v) {
    final hex = v.toRadixString(16).padLeft(64, '0');
    return hexToBytes(hex);
  }
}
