/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, no funds: "Pay with BTC, ZEC, LTC" asks NEAR Intents' 1Click for
// real deposit addresses (not just prices) from Bitcoin, Zcash and
// Litecoin, through Tor, with the app's own client: each answer must carry
// 1Click's signature over the address, name exactly what was asked, and
// show up as waiting for a deposit. Nothing is ever sent to these
// addresses; the ETH would go to an unspendable address and refunds to
// addresses made up here, so nobody's wallet is named.
//
//   ONECLICK_LIVE=1 [CFB_TOR_SOCKS=127.0.0.1:19050] \
//       scripts/beam/host_test.sh --no-analyze \
//       test/beam/eth/near_intents/one_click_live_test.dart
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_bs58/dart_bs58.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';
import 'package:stackwallet/wallets/ethereum/near_intents/one_click_client.dart';

String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

void _evidence(String line) {
  // ignore: avoid_print
  print('[evidence] $line');
}

/// A well-formed base58check address for [version] with random contents:
/// valid to 1Click, owned by nobody.
String _madeUpAddress(List<int> version) {
  final r = Random.secure();
  final payload = Uint8List.fromList([
    ...version,
    ...List<int>.generate(20, (_) => r.nextInt(256)),
  ]);
  final check = crypto.sha256
      .convert(crypto.sha256.convert(payload).bytes)
      .bytes
      .sublist(0, 4);
  return bs58.encode(Uint8List.fromList([...payload, ...check]));
}

void main() {
  final env = Platform.environment;
  final enabled = env['ONECLICK_LIVE'] == '1';

  test(
    'real deposit addresses from BTC, ZEC and LTC, signed by 1Click',
    () async {
      final socks = (env['CFB_TOR_SOCKS'] ?? '127.0.0.1:19050').split(':');
      final tor = (host: InternetAddress(socks[0]), port: int.parse(socks[1]));
      final client = OneClickClient(
        clientFactory: () => EthRpcHttpClient(route: (_) => tor),
      );
      final tokens = await client.tokens();
      _evidence('${tokens.length} coins listed, through Tor');

      // A made-up address nobody holds the key to (1Click refuses the
      // well-known burn addresses): the ETH of a swap nobody pays for.
      final r = Random.secure();
      final recipient =
          '0x${[for (var i = 0; i < 20; i++) _hex(r.nextInt(256))].join()}';
      final cases = [
        ('BTC', 'btc', _madeUpAddress([0x00])),
        ('ZEC', 'zec', _madeUpAddress([0x1C, 0xB8])),
        ('LTC', 'ltc', _madeUpAddress([0x30])),
      ];
      for (final (symbol, chain, refundTo) in cases) {
        final coin = tokens.firstWhere(
          (t) => t.symbol == symbol && t.blockchain == chain,
        );
        // About $30 worth.
        final usd = coin.priceUsd ?? 0;
        expect(usd, greaterThan(0), reason: '$symbol has a price');
        final whole = 30 / usd;
        final amountIn = BigInt.from((whole * pow(10, coin.decimals)).round());
        final q = await client.quote(
          origin: coin,
          amountIn: amountIn,
          recipient: recipient,
          refundTo: refundTo,
          dry: false,
        );
        // quote() refuses an unsigned or mismatched answer; check again here.
        expect(verifyOneClickQuote(q.raw), isTrue);
        expect(q.amountIn, amountIn);
        expect(q.refundTo, refundTo);
        expect(q.recipient.toLowerCase(), recipient.toLowerCase());
        final address = q.depositAddress!;
        expect(address, isNotEmpty);
        final status = await client.status(address, memo: q.depositMemo);
        expect(status.state, OneClickState.pendingDeposit);
        _evidence(
          '$symbol: ${q.request['amount']} units (~\$${q.amountInUsd}) → '
          '${q.amountOut} wei ETH; deposit address '
          '${address.substring(0, 6)}…${address.substring(address.length - 4)}'
          ' signed by 1Click, status ${status.state.wire}, deadline '
          '${q.deadline?.toUtc().toIso8601String()}',
        );
      }
    },
    skip: enabled ? false : 'ONECLICK_LIVE=1 is required (live, no funds)',
  );
}
