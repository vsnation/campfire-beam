/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: show every Uniswap pool between the two tokens of the swap —
//    which version, its fee, whether it has a hook, its price and how deep
//    it is next to the others — so "is this the best place to swap?" has a
//    visible answer.
// 2. No action: read-only; the swap is always shared between the pools
//    that, together, give the most, and the pools it uses say how much
//    of it each takes.
// 3. One tap from the swap form ("Pools", or the route line).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/uniswap_discovery.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_quoter.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';

class UniswapPoolsView extends StatefulWidget {
  const UniswapPoolsView({
    super.key,
    required this.deps,
    required this.a,
    required this.b,
    this.quote,
    this.embedded = false,
  });

  final UniswapDeps deps;
  final UniToken a;
  final UniToken b;

  /// The swap being priced, if any: its pools show their share of it.
  final UniQuote? quote;

  /// True beside the desktop swap form: no page around it.
  final bool embedded;

  @override
  State<UniswapPoolsView> createState() => _UniswapPoolsViewState();
}

class _PoolRow {
  _PoolRow(this.pool, this.state);

  final UniPool pool;
  final UniPoolState? state;
}

class _UniswapPoolsViewState extends State<UniswapPoolsView> {
  List<_PoolRow>? _rows;
  Object? _error;

  UniswapDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(UniswapPoolsView old) {
    super.didUpdateWidget(old);
    if (old.a != widget.a || old.b != widget.b) {
      setState(() => _rows = null);
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final d = deps.service.discovery;
      final pools = <UniPool>{};
      for (final x in widget.a.poolCurrencies) {
        for (final y in widget.b.poolCurrencies) {
          pools.addAll(await d.poolsBetween(x, y));
        }
      }
      final states = await d.liveState(pools.toList());
      final rows = [for (final p in pools) _PoolRow(p, states[p.id])]
        ..sort((x, y) {
          final lx = x.state?.isLive ?? false;
          final ly = y.state?.isLive ?? false;
          if (lx != ly) return lx ? -1 : 1;
          if (!lx) return 0;
          return UniswapQuoter.depth(y.state!)
              .compareTo(UniswapQuoter.depth(x.state!));
        });
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String _price(_PoolRow r) {
    final p = r.state?.price0to1;
    if (p == null) return '';
    final pool = r.pool;
    // Raw units → whole tokens, quoted as "1 a = x b".
    final aSide = widget.a.poolCurrencies.contains(pool.currency0) ? 0 : 1;
    final dec0 = aSide == 0 ? widget.a.decimals : widget.b.decimals;
    final dec1 = aSide == 0 ? widget.b.decimals : widget.a.decimals;
    var whole = p * _pow10(dec0 - dec1);
    if (aSide == 1) whole = whole == 0 ? 0 : 1 / whole;
    return '1 ${widget.a.symbol} = ${_num(whole)} ${widget.b.symbol}';
  }

  static double _pow10(int e) {
    var r = 1.0;
    for (var i = 0; i < e.abs(); i++) {
      r *= 10;
    }
    return e < 0 ? 1 / r : r;
  }

  static String _num(double v) {
    if (!v.isFinite) return '?';
    if (v >= 1000) {
      final digits = v.toStringAsFixed(0);
      final b = StringBuffer();
      for (var i = 0; i < digits.length; i++) {
        if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
        b.write(digits[i]);
      }
      return b.toString();
    }
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsPrecision(4);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final rows = _rows;
    final live = rows?.where((r) => r.state?.isLive ?? false).toList();
    final deepest = (live == null || live.isEmpty)
        ? null
        : UniswapQuoter.depth(live.first.state!);
    final Widget body;
    if (_error != null) {
      body = DexNotice(
        key: const Key('uni-pools-error'),
        sticker: BeamMoments.somethingWentWrong,
        kind: DexNoticeKind.error,
        title: "Couldn't read the pools",
        detail: 'Your Ethereum node did not answer. Nothing was sent.',
        actionLabel: 'Try again',
        onAction: () {
          setState(() => _error = null);
          unawaited(_load());
        },
      );
    } else if (rows == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Looking at every Uniswap pool between ${widget.a.symbol} and '
          '${widget.b.symbol}…',
          key: const Key('uni-pools-loading'),
          style: STextStyles.label(context),
        ),
      );
    } else if (rows.isEmpty) {
      body = DexNotice(
        key: const Key('uni-pools-none'),
        sticker: BeamMoments.trading,
        title: 'No pool between ${widget.a.symbol} and ${widget.b.symbol}',
        detail:
            'The swap can still go through another token (ETH, USDC, USDT, '
            'DAI, WBTC or WBEAM) when both sides trade with it.',
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${live!.length} of ${rows.length} pools can trade now. Your swap '
            'is shared between the pools that, together, give you the most, '
            'so no one pool moves far.',
            key: const Key('uni-pools-summary'),
            style: STextStyles.label(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          if (_viaOthers() case final via?) ...[
            const SizedBox(height: 6),
            Text(
              via,
              key: const Key('uni-pools-via'),
              style: STextStyles.label(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
          const SizedBox(height: 8),
          for (final r in rows.take(40)) _row(context, r, deepest),
          if (rows.length > 40)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '…and ${rows.length - 40} more without liquidity.',
                style: STextStyles.label(context),
              ),
            ),
        ],
      );
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Every Uniswap pool between ${widget.a.symbol} and '
          '${widget.b.symbol}, from Uniswap\'s own records (v2, v3 and v4).',
          style: STextStyles.smallMed12(context),
        ),
        const SizedBox(height: 12),
        body,
      ],
    );
    if (widget.embedded) return content;
    return DexPage(deps: deps, title: 'Uniswap pools', body: content);
  }

  /// "70%" when the swap sends that much straight through [pool].
  String? _shareOf(UniPool pool) {
    final q = widget.quote;
    if (q == null || !_samePair(q)) return null;
    for (final p in q.parts) {
      if (p.route.isDirect && p.route.hops.first.pool.id == pool.id) {
        return UniFormat.share(q.shareOf(p));
      }
    }
    return null;
  }

  /// The shares that go through another token, which this list (pools
  /// between the two tokens only) does not show.
  String? _viaOthers() {
    final q = widget.quote;
    if (q == null || !_samePair(q)) return null;
    final others = [
      for (final p in q.parts)
        if (!p.route.isDirect) p,
    ];
    if (others.isEmpty) return null;
    final total = others.fold(0.0, (s, p) => s + q.shareOf(p));
    return 'Another ${UniFormat.share(total)} of your swap goes through a '
        'second token, on pools not listed here.';
  }

  bool _samePair(UniQuote q) =>
      q.tokenIn.sameAsset(widget.a) && q.tokenOut.sameAsset(widget.b);

  Widget _row(BuildContext context, _PoolRow r, BigInt? deepest) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final pool = r.pool;
    final isLive = r.state?.isLive ?? false;
    final share = (!isLive || deepest == null || deepest == BigInt.zero)
        ? 0.0
        : (UniswapQuoter.depth(r.state!).toDouble() / deepest.toDouble()).clamp(
            0.0,
            1.0,
          );
    final hooks = pool is UniV4Pool && pool.hasHooks;
    final native = pool.currency0 == UniToken.eth.address;
    return Padding(
      key: Key('uni-pool-${pool.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DexCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Uniswap ${pool.version.label}',
                  style: STextStyles.titleBold12(context),
                ),
                const SizedBox(width: 8),
                Text(
                  '${UniFormat.fee(pool.fee)} fee'
                  '${hooks ? ' · hook' : ''}'
                  '${pool.version != UniVersion.v4 || native ? '' : ' · WETH'}',
                  style: STextStyles.label(context),
                ),
                const Spacer(),
                if (_shareOf(pool) case final used?)
                  Text(
                    '$used of your swap',
                    key: Key('uni-pool-share-${pool.id}'),
                    style: STextStyles.label(context).copyWith(
                      color: colors.accentColorGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else
                  Text(
                    isLive ? '' : 'empty',
                    style: STextStyles.label(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
              ],
            ),
            if (isLive) ...[
              const SizedBox(height: 4),
              Text(_price(r), style: STextStyles.label(context)),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: share,
                  minHeight: 4,
                  backgroundColor: colors.textFieldDefaultBG,
                  color: colors.accentColorGreen,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
