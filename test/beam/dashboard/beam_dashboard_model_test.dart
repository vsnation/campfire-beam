/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_market_source.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_providers.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/assets/beam_market_cache.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_dashboard_assets.dart';

final _beam = BigInt.from(100000000);
BigInt _b(num v) => BigInt.from((v * 100000000).round());

BeamCachedAssetTotals _totals(int id, BigInt available) =>
    BeamCachedAssetTotals(
      assetId: id,
      available: available,
      receiving: BigInt.zero,
      sending: BigInt.zero,
      maturing: BigInt.zero,
      change: BigInt.zero,
    );

BeamAssetHolding _holding(
  int id,
  num amount, {
  num? valueBeam,
  bool hidden = false,
  String? meta,
}) => BeamAssetHolding(
  contract: BeamAssetRegistry.build(
    id,
    metadata: meta == null ? null : BeamAssetMetadata.parse(meta),
  ),
  totals: _totals(id, _b(amount)),
  hidden: hidden,
  priced: valueBeam != null,
  valueGroth: valueBeam == null ? null : _b(valueBeam),
);

String _beamFmt(Amount a) => '${a.decimal} BEAM';
String? _usd(Amount a) =>
    '${(a.decimal.toDouble() * 0.0087).toStringAsFixed(2)} USD';

BeamDashboardModel _build(
  List<BeamAssetHolding> holdings, {
  BeamAssetMarket? market,
  String? Function(Amount)? fiat,
  DateTime? now,
  int maxRows = BeamDashboardModel.maxRowsPhone,
}) => BeamDashboardModel.build(
  beamSpendable: _b(1200),
  holdings: holdings,
  market: market,
  formatBeam: _beamFmt,
  fiat: fiat ?? _usd,
  now: now ?? DateTime(2026, 10, 6, 12),
  maxRows: maxRows,
);

void main() {
  final market = BeamAssetMarket(const [], readAt: DateTime(2026, 10, 6, 12));

  test('BEAM comes first with its fiat value, then assets by value', () {
    final m = _build([
      _holding(174, 568.1297, valueBeam: 70),
      _holding(190, 6329.95, valueBeam: 300),
    ], market: market);
    expect(m.rows.map((r) => r.assetId), [0, 174, 190]);
    expect(m.rows.first.title, 'BEAM');
    expect(m.rows.first.value, '10.44 USD');
    final fomo = m.rows[1];
    expect(fomo.title, 'FOMO');
    expect(fomo.amount, '568.1297 FOMO');
    expect(fomo.value, '0.61 USD');
    expect(fomo.valueNote, '≈ 70 BEAM');
    expect(m.priceNote, isNull);
  });

  test('hidden assets and unpriced unverified spam are not listed', () {
    final m = _build([
      _holding(174, 10, valueBeam: 5, hidden: true),
      _holding(
        777,
        1000000,
        meta: 'STD:SCH_VER=1;N=Spam;SN=SPAM;UN=SPAM;NTHUN=s',
      ),
      _holding(
        778,
        5,
        valueBeam: 0.5,
        meta: 'STD:SCH_VER=1;N=Tiny;SN=TINY;UN=TINY;NTHUN=t',
      ),
    ], market: market);
    expect(m.rows.map((r) => r.assetId), [0]);
    expect(m.moreCount, 3);
  });

  test('an unverified asset worth at least 1 BEAM is listed with its #id', () {
    final m = _build([
      _holding(
        779,
        12,
        valueBeam: 3,
        meta: 'STD:SCH_VER=1;N=Pepe Coin;SN=PEPE;UN=PEPE;NTHUN=p',
      ),
    ], market: market);
    expect(m.rows[1].title, 'PEPE #779');
  });

  test('a look-alike of a verified asset carries the warning', () {
    final m = _build([
      _holding(
        999,
        100,
        valueBeam: 50,
        meta: 'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO;NTHUN=f',
      ),
    ], market: market);
    expect(m.rows[1].title, 'FOMO #999');
    expect(m.rows[1].warning, 'Not the verified FOMO (#174)');
  });

  test('a verified asset without a price is still listed, as No price', () {
    final m = _build([_holding(4, 3)], market: market);
    expect(m.rows[1].title, 'CROWN');
    expect(m.rows[1].value, 'No price');
  });

  test('prices off: values in BEAM, no fiat', () {
    final m = _build(
      [_holding(174, 10, valueBeam: 2)],
      market: market,
      fiat: (_) => null,
    );
    expect(m.rows.first.value, '1200 BEAM');
    expect(m.rows[1].value, '≈ 2 BEAM');
    expect(m.rows[1].valueNote, isNull);
  });

  test('a phone shows at most 4 rows; the rest are counted for See all', () {
    final m = _build([
      for (final id in [174, 190, 191, 7, 9]) _holding(id, 1, valueBeam: 10),
    ], market: market);
    expect(m.rows.length, 4);
    expect(m.moreCount, 2);
    final d = _build(
      [
        for (final id in [174, 190, 191, 7, 9]) _holding(id, 1, valueBeam: 10),
      ],
      market: market,
      maxRows: BeamDashboardModel.maxRowsDesktop,
    );
    expect(d.rows.length, 6);
  });

  test('old or missing prices say so', () {
    final noMarket = _build([_holding(174, 1, valueBeam: 1)]);
    expect(noMarket.priceNote, 'Getting prices…');
    final old = _build(
      [_holding(174, 1, valueBeam: 1)],
      market: market,
      now: DateTime(2026, 10, 6, 12, 25),
    );
    expect(old.priceNote, 'Prices from 25 min ago');
  });

  test('short amounts never read as zero', () {
    expect(BeamDashboardModel.shortAmount(_b(568.12972897)), '568.1297');
    expect(BeamDashboardModel.shortAmount(_b(1234567.5)), '1,234,567.5');
    expect(BeamDashboardModel.shortAmount(BigInt.from(12345)), '0.00012345');
    expect(BeamDashboardModel.shortAmount(_beam * BigInt.from(3)), '3');
    expect(BeamDashboardModel.shortAmount(_b(2.00001)), '2');
  });

  group('market cache', () {
    final pools = [
      BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.fromWire(2),
        tok1: BigInt.parse('8120504552105'),
        tok2: BigInt.parse('66136536898747'),
        ctl: BigInt.parse('27125190867423'),
        lpToken: 175,
      ),
    ];
    final at = DateTime.utc(2026, 10, 6, 12);

    test('a snapshot round-trips to the same prices', () {
      final raw = WalletInfoMarketCache.encode(
        BeamAssetMarket(pools, readAt: at),
      );
      final back = WalletInfoMarketCache.decode(raw, now: at)!;
      expect(back.readAt.toUtc(), at);
      expect(back.pools.single.tok1, pools.single.tok1);
      expect(back.pools.single.tok2, pools.single.tok2);
      expect(back.pools.single.lpToken, 175);
      expect(
        back.pricer.valueInGroth(174, _beam),
        BeamAssetMarket(pools, readAt: at).pricer.valueInGroth(174, _beam),
      );
    });

    test('a week-old or malformed snapshot is ignored, never thrown', () {
      final raw = WalletInfoMarketCache.encode(
        BeamAssetMarket(pools, readAt: at),
      );
      expect(
        WalletInfoMarketCache.decode(raw, now: at.add(const Duration(days: 8))),
        isNull,
      );
      expect(
        WalletInfoMarketCache.decode('{"readAt":1,"pools":[[1]]}', now: at),
        isNull,
      );
      expect(
        WalletInfoMarketCache.decode(
          '{"readAt":${at.millisecondsSinceEpoch},"pools":[[0,174,2,"-5","1","1",175]]}',
          now: at,
        ),
        isNull,
      );
    });
  });

  test('an unverified asset valued at its pool sale price says so', () {
    final h = BeamAssetHolding(
      contract: BeamAssetRegistry.build(
        779,
        metadata: BeamAssetMetadata.parse(
          'STD:SCH_VER=1;N=Pepe Coin;SN=PEPE;UN=PEPE;NTHUN=p',
        ),
      ),
      totals: _totals(779, _b(12)),
      hidden: false,
      priced: true,
      valueGroth: _b(3),
      saleValue: true,
    );
    final m = _build([h], market: market);
    expect(m.rows[1].valueNote, '≈ 3 BEAM if sold now');
  });

  // Seen in the DMG test: the first read failed while the restore scan ran,
  // and the assets card said "Prices load once the wallet is connected"
  // long after it was.
  group('a failed first read is tried again', () {
    final pools = [
      BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.fromWire(2),
        tok1: BigInt.parse('8120504552105'),
        tok2: BigInt.parse('66136536898747'),
        ctl: BigInt.parse('27125190867423'),
        lpToken: 175,
      ),
    ];

    test('nothing saved: retry is scheduled, and the retry gets prices',
        () async {
      var fail = true;
      final source = BeamAssetMarketSource(() async {
        if (fail) throw StateError('core not ready');
        return pools;
      });
      var retries = 0;
      expect(await readBeamMarket(source, () => retries++), isNull);
      expect(retries, 1);
      fail = false;
      final market = await readBeamMarket(source, () => retries++);
      expect(market!.pools.single.aid2, 174);
      expect(retries, 1);
    });

    test('saved prices and a failed refresh: the saved ones, no retry',
        () async {
      var now = DateTime(2026, 10, 7, 1);
      var calls = 0;
      final source = BeamAssetMarketSource(() async {
        if (calls++ > 0) throw StateError('node gone');
        return pools;
      }, now: () => now);
      await source.read();
      now = now.add(const Duration(minutes: 5));
      var retries = 0;
      final market = await readBeamMarket(source, () => retries++);
      expect(calls, 2, reason: 'stale, so it tried to read');
      expect(market!.pools.single.aid2, 174);
      expect(retries, 0);
    });
  });
}
