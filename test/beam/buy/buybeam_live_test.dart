/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// buybeam.my for real, opt-in (BUYBEAM_LIVE=1), through a SOCKS5 proxy
// when CFB_TOR_SOCKS=host:port is set (Tor's):
//
// * the real coin list, the smallest-buy hint, a real price that is under
//   the smallest buy and one that is not (a price creates nothing);
// * a SANDBOX order (nothing payable, no funds) followed by the real
//   controller until it is delivered (~90 s), every state it passed;
// * every ending forced in the sandbox (":<state>").
//
// No real order is ever created here: every order goes through a client
// built with `sandbox: true`, which the test checks before it asks.
//
//   BUYBEAM_LIVE=1 CFB_TOR_SOCKS=127.0.0.1:9050 \
//     scripts/beam/host_test.sh --no-analyze test/beam/buy/buybeam_live_test.dart

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:stackwallet/networking/socks5_tunnel.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_controller.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_store.dart';

/// Made up: the sandbox only checks its length and characters.
const _beamAddress =
    '1111111111111111111111111111111111111111111111111111111111111111aa';
const _btcRefund = 'bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh';

http.Client Function() _factory() {
  final socks = Platform.environment['CFB_TOR_SOCKS'];
  if (socks == null || socks.isEmpty) return http.Client.new;
  final i = socks.lastIndexOf(':');
  final proxy = (
    host: InternetAddress(socks.substring(0, i)),
    port: int.parse(socks.substring(i + 1)),
  );
  return () {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 60);
    routeHttpClientThroughSocks5(c, proxy);
    return IOClient(c);
  };
}

String _t() => DateTime.now().toUtc().toIso8601String().substring(11, 19);

void _log(String s) => debugPrint('[buybeam live ${_t()}] $s');

/// Tor circuits and the proxy in front of buybeam.my drop requests now and
/// then; a read-only call is simply asked again.
Future<T> _again<T>(Future<T> Function() f) async {
  for (var i = 1; ; i++) {
    try {
      return await f();
    } on BuyBeamError catch (e) {
      if (!e.code.unreachable || i >= 4) rethrow;
      _log('no answer (${e.code.wire}), asking again');
      await Future<void>.delayed(Duration(seconds: 3 * i));
    }
  }
}

void main() {
  final enabled = Platform.environment['BUYBEAM_LIVE'] == '1';
  // The test binding answers HTTP with 400; this talks to buybeam.my.
  HttpOverrides.global = null;
  final factory = _factory();
  final real = BuyBeamClient(clientFactory: factory);
  final sandbox = BuyBeamClient(clientFactory: factory, sandbox: true);

  group('buybeam.my, live', () {
    late List<BuyBeamAsset> assets;

    test('the coins, the smallest-buy hint', () async {
      assets = await _again(real.assets);
      final btc = assets.firstWhere(_isBtc);
      _log('assets: ${assets.length}, BTC decimals ${btc.decimals}');
      expect(assets.length, greaterThan(50));
      expect(btc.decimals, 8);
      final sorted = sortBuyBeamAssets(assets);
      expect(sorted.first.symbol, 'BTC');
      final limits = await _again(real.limits);
      _log('limits: hint \$${limits.hintUsd}');
      expect(limits.hintUsd, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a real price: under the smallest buy, and one above it', () async {
      final btc = assets.firstWhere(_isBtc);
      try {
        await _again(
          () => real.quote(
            assetId: btc.assetId,
            amount: BuyBeamAmount.parse('0.0001', decimals: 8).amount!,
            refundAddress: _btcRefund,
          ),
        );
        fail('0.0001 BTC priced');
      } on BuyBeamError catch (e) {
        _log('0.0001 BTC: ${e.code.wire}, minimum \$${e.minimumUsd}');
        expect(e.code.belowMinimum, isTrue);
        expect(e.minimumUsd, greaterThan(0));
      }
      // About $1,500 of BTC, at its listed price.
      final btcAmount = (1500 / btc.priceUsd!).toStringAsFixed(4);
      final amount = BuyBeamAmount.parse(btcAmount, decimals: 8).amount!;
      final q = await _again(
        () => real.quote(
          assetId: btc.assetId,
          amount: amount,
          refundAddress: _btcRefund,
        ),
      );
      _log(
        '$btcAmount BTC: ≈ ${q.beamEstimate} BEAM, '
        '\$${q.orderValueUsd}, eta ${q.etaSeconds} s',
      );
      expect(q.beamEstimate, greaterThan(0));
      expect(q.sendAmountRaw, amount.raw);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: !enabled);

  group('buybeam.my sandbox, live', () {
    test('a sandbox order, followed until its BEAM is delivered', () async {
      expect(sandbox.sandbox, isTrue, reason: 'never a real order');
      final c = BuyBeamController(client: sandbox, store: MemoryBuyBeamStore());
      addTearDown(c.dispose);
      final list = await _again(() => c.assets());
      _log('sandbox assets: ${list.map((a) => a.symbol).join(', ')}');
      final btc = list.firstWhere(_isBtc);
      final amount = BuyBeamAmount.parse('0.0123', decimals: 8).amount!;
      final q = await _again(
        () => sandbox.quote(
          assetId: btc.assetId,
          amount: amount,
          refundAddress: _btcRefund,
        ),
      );
      _log('sandbox quote: ≈ ${q.beamEstimate} BEAM, eta ${q.etaSeconds} s');
      final start = DateTime.now();
      final o = await c.placeOrder(
        asset: btc,
        amount: amount,
        refundAddress: _btcRefund,
        beamWalletId: 'live-test',
        newBeamAddress: () async => _beamAddress,
        quote: q,
      );
      _log('order ${o.depositAddress} sandbox=${o.sandbox}');
      expect(o.depositAddress, startsWith('sbx_'));
      expect(o.sandbox, isTrue);
      final seen = <String>[];
      final done = Completer<void>();
      void watch() {
        final now = c.order(o.depositAddress);
        final s = now?.lastState?.wire;
        if (s != null && (seen.isEmpty || seen.last != s)) {
          seen.add(s);
          final age = DateTime.now().difference(start).inSeconds;
          _log('state $s at +${age}s');
        }
        if (now != null && now.terminal && !done.isCompleted) {
          done.complete();
        }
      }

      c.addListener(watch);
      watch();
      await done.future.timeout(const Duration(minutes: 4));
      c.removeListener(watch);
      final end = c.order(o.depositAddress)!;
      _log('delivered, BEAM transaction ${end.beamTxId}');
      expect(seen.first, 'awaiting_deposit');
      expect(seen.last, 'delivered');
      expect(seen.length, greaterThanOrEqualTo(4));
      expect(end.beamTxId, isNotNull);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('every ending, forced', () async {
      expect(sandbox.sandbox, isTrue, reason: 'never a real order');
      final btc = (await _again(sandbox.assets)).firstWhere(_isBtc);
      final a = await _again(
        () => sandbox.order(
          assetId: btc.assetId,
          amount: BuyBeamAmount.parse('0.0123', decimals: 8).amount!,
          beamAddress: _beamAddress,
          refundAddress: _btcRefund,
        ),
      );
      expect(a.payable, isFalse);
      for (final state in [
        'awaiting_deposit',
        'deposit_detected',
        'swapping',
        'buying',
        'sending',
        'delivered',
        'refunded',
        'expired',
        'failed',
      ]) {
        final s = await _again(
          () => sandbox.status(a.depositAddress, forceState: state),
        );
        _log('forced $state → ${s.state.wire} terminal=${s.terminal}');
        expect(s.state.wire, state);
        expect(s.terminal, s.state.isFinal);
      }
    }, timeout: const Timeout(Duration(minutes: 4)));
  }, skip: !enabled);
}

/// BTC on Bitcoin, whatever buybeam.my calls its chain.
bool _isBtc(BuyBeamAsset a) =>
    a.symbol == 'BTC' &&
    a.isNative &&
    (a.blockchain == 'btc' || a.blockchain == 'bitcoin');
