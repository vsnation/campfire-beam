/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Uniswap swap from a real Campfire Ethereum wallet against a copy of
// mainnet (fork_support.dart): the wallet's own key signs the Permit2
// permit (`EthereumWallet.signDigest`) and the transactions
// (`sendContractCall`: nonce, chain id check, broadcast), through
// Campfire's Ethereum HTTP client, and each swap lands in the wallet's
// history as a pending transaction with its note.

@Timeout(Duration(minutes: 15))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/models/isar/models/transaction_note.dart';
import 'package:stackwallet/models/node_model.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_deps.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import '../../eth_ui/eth_ui_harness.dart';
import '../../wiring_ui/wiring_harness.dart' show WiringDb;
import 'fork_support.dart';

NodeModel _forkNode() => NodeModel(
  host: forkUrl,
  port: 8545,
  name: 'local mainnet fork',
  id: 'fork',
  useSSL: false,
  enabled: true,
  coinName: 'ethereum',
  isFailover: false,
  isDown: false,
  torEnabled: true,
  clearnetEnabled: true,
  isPrimary: true,
);

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('ETH → WBEAM → ETH, signed and sent by the wallet itself', (
    tester,
  ) async {
    // The test binding answers every HTTP request with 400; this test
    // talks to the fork for real.
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    final unavailable = await tester.runAsync(forkUnavailable);
    if (unavailable != null) return markTestSkipped(unavailable);

    final wallet = await openEthWallet(tester, node: _forkNode());
    // Leave the fork as it was (see rollBackForkAfterEachTest).
    final snapshot = await tester.runAsync(takeFork);
    addTearDown(() => tester.runAsync(() => releaseFork(snapshot!)));
    await tester.runAsync(() async {
      final address = (await wallet.getCurrentReceivingAddress())!.value
          .toLowerCase();
      await forkRpc().call('anvil_setBalance', [
        address,
        '0x${BigInt.from(10).pow(18).toRadixString(16)}',
      ]);
      final rpc = EthRpc(
        url: forkUrl,
        clientFactory: createEthHttpClient,
        timeout: const Duration(minutes: 8),
      );
      final svc = UniswapService(rpc: rpc);
      final signer = EthWalletSwapSigner(wallet, address);

      Future<UniTxOutcome> run(UniQuote q, String note) async {
        final approval = await svc.approvalFor(q, address);
        if (approval.kind != UniApprovalKind.none) {
          final tx = await svc.approvalTx(
            token: q.tokenIn,
            amount: q.amountIn,
            owner: address,
          );
          final h = await signer.send(tx.withNote('approve'));
          expect((await svc.waitForReceipt(h, every: const Duration(milliseconds: 200)))!.success, isTrue);
        }
        final prepared = await svc.prepareSwap(
          quote: q,
          slippageBips: 100,
          signer: signer,
        );
        final hash = await signer.send(prepared.tx.withNote(note));
        // In the wallet's history at once, with its note.
        final pending = await MainDB.instance.isar.transactionV2s
            .where()
            .txidWalletIdEqualTo(hash, wallet.walletId)
            .findFirst();
        expect(pending, isNotNull, reason: 'no pending tx for $hash');
        final saved = await MainDB.instance.isar.transactionNotes
            .where()
            .txidWalletIdEqualTo(hash, wallet.walletId)
            .findFirst();
        expect(saved?.value, note);
        final out = await svc.waitForReceipt(
          hash,
          owner: address,
          tokenOut: q.tokenOut,
          every: const Duration(milliseconds: 200),
        );
        expect(out!.success, isTrue);
        expect(out.received, prepared.quote.amountOut);
        return out;
      }

      final buy = await svc.quote(
        tokenIn: UniToken.eth,
        tokenOut: kWbeamToken,
        amountIn: BigInt.from(10).pow(16),
        owner: address,
      );
      await run(buy, 'Uniswap: swap 0.01 ETH for WBEAM');
      final have = await svc.balanceOf(kWbeamToken, address);
      expect(have, buy.amountOut);
      final sell = await svc.quote(
        tokenIn: kWbeamToken,
        tokenOut: UniToken.eth,
        amountIn: have,
        owner: address,
      );
      // The Permit2 signature comes from the wallet's own key.
      await run(sell, 'Uniswap: swap WBEAM for ETH');
      expect(await svc.balanceOf(kWbeamToken, address), BigInt.zero);
    });
  });
}
