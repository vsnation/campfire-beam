/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds: one 0.05 BEAM → FOMO swap on the mainnet
// DEX through BeamDexService, the same service the swap screen uses, from
// a test wallet. Checks the confirmation numbers (decoded from the
// built transaction) against the quote, sends exactly once, waits for the
// transaction to complete and for the FOMO to arrive.
//
// Skipped unless BEAM_LIVE_DEX_SWAP=1. Reads the port and ACL key of a
// running TCP-mode wallet-api from the wapi.py state file of
// BEAM_LIVE_LABEL (default funder2):
//
//   python3 -I scripts/beam/live/wapi.py start funder2 --port 10110 --tcp
//   BEAM_LIVE_DEX_SWAP=1 flutter test test/beam/contracts/dex/live_dex_swap_test.dart
//
// Prints tx ids cut to 12 characters, heights and amounts only.
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

/// R9: at most 0.1 BEAM per transaction; this test pays 0.05.
final BigInt _pay = BigInt.from(5000000);
final BigInt _maxFee = BigInt.from(2000000); // 0.02 BEAM

String _b(BigInt g) => (g.toDouble() / 1e8).toStringAsFixed(8);
String _short(String s) => s.length <= 12 ? s : s.substring(0, 12);

void main() {
  final enabled = Platform.environment['BEAM_LIVE_DEX_SWAP'] == '1';

  test(
    'swap 0.05 BEAM for FOMO on mainnet, exactly as the screen would',
    () async {
      final label = Platform.environment['BEAM_LIVE_LABEL'] ?? 'funder2';
      final home = Platform.environment['HOME']!;
      final state =
          jsonDecode(
                File(
                  '$home/beam-campfire-test/run/$label.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final transport = TcpLineTransport(
        port: state['port']! as int,
        aclKey: state['key']! as String,
        log: (_) {},
      );
      await transport.connect();
      final api = BeamApi(transport);
      final dex = BeamDexService(
        api,
        ammAppShader(const FileShaderSource('assets/beam/shaders')),
      );

      final before = await api.walletStatus();
      expect(before.isInSync, isTrue, reason: 'never trade on a stale wallet');
      final beamBefore = before.totalsFor(0)!.available;
      final fomoBefore = before.totalsFor(174)?.available ?? BigInt.zero;
      print(
        '[evidence] height ${before.currentHeight}; before: '
        '${_b(beamBefore)} BEAM, ${_b(fomoBefore)} FOMO',
      );
      expect(beamBefore > _pay + _maxFee, isTrue, reason: 'needs funds');

      final quote = await dex.quote(
        payAsset: 0,
        payAmount: _pay,
        receiveAsset: 174,
      );
      print(
        '[evidence] quote: pay ${_b(quote.pay)} BEAM, receive '
        '${_b(quote.receive)} FOMO, pool fee ${_b(quote.fee)} BEAM, '
        'kind ${quote.kind}',
      );
      expect(quote.pay <= _pay, isTrue);

      // What the confirmation screen shows: decoded from the built tx.
      final prepared = await dex.prepareSwap(quote);
      final pays = prepared.pays;
      final receives = prepared.invoke.receives;
      final fee = prepared.invoke.fee;
      print(
        '[evidence] built: pays ${pays.map((k, v) => MapEntry(k, _b(v)))}, '
        'receives ${receives.map((k, v) => MapEntry(k, _b(v)))}, '
        'network fee ${_b(fee)} BEAM',
      );
      expect(pays.keys, [0]);
      expect(pays[0]! <= _pay, isTrue);
      expect(receives.keys, [174]);
      expect(fee >= BigInt.from(1100000), isTrue, reason: 'contract call');
      expect(fee <= _maxFee, isTrue);

      final txId = await dex.execute(prepared);
      print('[evidence] process_invoke_data → tx ${_short(txId)}');
      // A prepared call is never sent twice.
      expect(
        () => dex.execute(prepared),
        throwsA(isA<BeamDexException>()),
      );

      final sw = Stopwatch()..start();
      late BeamTransaction tx;
      while (true) {
        tx = await api.txStatus(txId);
        if (tx.status == BeamTxStatus.completed ||
            tx.status == BeamTxStatus.failed ||
            tx.status == BeamTxStatus.canceled) {
          break;
        }
        if (sw.elapsed > const Duration(minutes: 20)) {
          fail('swap not completed after 20 min: ${tx.statusString}');
        }
        await Future<void>.delayed(const Duration(seconds: 10));
      }
      print(
        '[evidence] tx ${_short(txId)} ${tx.statusString} at height '
        '${tx.height} after ${sw.elapsed.inSeconds} s',
      );
      expect(tx.status, BeamTxStatus.completed);

      // The FOMO arrives with the transaction (no maturity for CA outputs
      // of a contract call beyond the block itself); allow a few refreshes.
      var after = await api.walletStatus();
      for (var i = 0; i < 12; i++) {
        final f = after.totalsFor(174)?.available ?? BigInt.zero;
        if (f - fomoBefore >= receives[174]!) break;
        await Future<void>.delayed(const Duration(seconds: 10));
        after = await api.walletStatus();
      }
      final beamAfter = after.totalsFor(0)!.available;
      final fomoAfter = after.totalsFor(174)?.available ?? BigInt.zero;
      print(
        '[evidence] after: ${_b(beamAfter)} BEAM '
        '(${_b(beamAfter - beamBefore)}), ${_b(fomoAfter)} FOMO '
        '(+${_b(fomoAfter - fomoBefore)})',
      );
      expect(fomoAfter - fomoBefore, receives[174]);
      await transport.close();
    },
    skip: enabled ? null : 'set BEAM_LIVE_DEX_SWAP=1 to run',
  );
}
