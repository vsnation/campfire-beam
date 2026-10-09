/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:web3dart/web3dart.dart' as web3;

import '../wallets/ethereum/eth_http_client.dart';
import 'eth_rpc_url.dart';

/// What "Test connection" found at an Ethereum RPC URL.
enum EthNodeTestStatus {
  /// It answered as Ethereum mainnet (chain id 1) and gave its block height.
  mainnet,

  /// It answered, but for another chain.
  wrongChain,

  /// Nothing usable came back within the time allowed.
  noAnswer,

  /// Tor is on but not connected: nothing was sent.
  torNotConnected,

  /// A .onion address while Tor is off: nothing was sent.
  onionNeedsTor,

  /// Not a URL the wallet would use.
  invalidUrl,
}

class EthNodeTestResult {
  const EthNodeTestResult(this.status, {this.chainId, this.blockNumber});

  final EthNodeTestStatus status;
  final BigInt? chainId;
  final int? blockNumber;

  bool get ok => status == EthNodeTestStatus.mainnet;
}

/// Tests [url] the way the wallet uses it: through Tor when Tor is on (or
/// not at all), `eth_chainId` first — it must be 1, Ethereum mainnet — then
/// `eth_blockNumber`. Everything within [timeout].
Future<EthNodeTestResult> testEthNodeConnection(
  String url, {
  EthRoute? route,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final u = url.trim();
  if (EthRpcUrl.problem(u) != null) {
    return const EthNodeTestResult(EthNodeTestStatus.invalidUrl);
  }
  final http = EthRpcHttpClient(route: route, connectionTimeout: timeout);
  final client = web3.Web3Client(u, http);
  final deadline = DateTime.now().add(timeout);
  Duration left() {
    final d = deadline.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  try {
    final chainId = await client.getChainId().timeout(left());
    if (chainId != BigInt.one) {
      return EthNodeTestResult(EthNodeTestStatus.wrongChain, chainId: chainId);
    }
    final block = await client.getBlockNumber().timeout(left());
    return EthNodeTestResult(
      EthNodeTestStatus.mainnet,
      chainId: chainId,
      blockNumber: block,
    );
  } on EthTorNotConnectedException {
    return const EthNodeTestResult(EthNodeTestStatus.torNotConnected);
  } on EthOnionNeedsTorException {
    return const EthNodeTestResult(EthNodeTestStatus.onionNeedsTor);
  } catch (_) {
    return const EthNodeTestResult(EthNodeTestStatus.noAnswer);
  } finally {
    http.close();
  }
}

/// One line for the result, never blaming the user.
String ethNodeTestMessage(EthNodeTestResult r, String url) =>
    switch (r.status) {
      EthNodeTestStatus.mainnet => switch (r.blockNumber) {
        null => 'Connected to Ethereum mainnet.',
        final block =>
          'Connected to Ethereum mainnet (block '
              '${NumberFormat.decimalPattern('en_US').format(block)}).',
      },
      EthNodeTestStatus.wrongChain =>
        'This RPC is not Ethereum mainnet (chain id ${r.chainId}). '
            'Pick another.',
      EthNodeTestStatus.noAnswer =>
        'No answer from this RPC. Check the URL and your connection, or '
            'pick another.',
      EthNodeTestStatus.torNotConnected =>
        "Tor isn't connected yet, so nothing was sent. Try again in a "
            'moment.',
      EthNodeTestStatus.onionNeedsTor =>
        'This is a Tor address (.onion). Turn Tor on, then try again.',
      EthNodeTestStatus.invalidUrl =>
        EthRpcUrl.problem(url) ?? 'Use a URL like ${EthRpcUrl.example}',
    };

/// [testEthNodeConnection] with Campfire's Tor rule. Widget tests override
/// it.
typedef EthNodeConnectionTester = Future<EthNodeTestResult> Function(
  String url,
);

final testEthNodeConnectionProvider = Provider<EthNodeConnectionTester>(
  (_) =>
      (url) => testEthNodeConnection(url),
);
