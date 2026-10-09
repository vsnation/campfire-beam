/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: pick the coin you pay with, and its chain.
// 2. Primary action: tap it.
// 3. One tap from the coin button of Buy BEAM.
//
// Exit-intent: "Is my coin here?" — the coins people bring most
// come first (BTC, ETH, USDT on Tron…), then every other coin by chain,
// with a search box for a ticker or a chain name. "Which USDT?" — every
// row names its chain, because USDT on Tron and USDT on Ethereum are
// different payments.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_widgets.dart';

Future<BuyBeamAsset?> showBuyBeamCoinPicker(
  BuildContext context, {
  required BuyBeamDeps deps,
}) => showDexPage<BuyBeamAsset>(
  context,
  deps,
  (_) => BuyBeamCoinPicker(deps: deps),
);

class BuyBeamCoinPicker extends StatefulWidget {
  const BuyBeamCoinPicker({super.key, required this.deps});

  final BuyBeamDeps deps;

  @override
  State<BuyBeamCoinPicker> createState() => _BuyBeamCoinPickerState();
}

class _BuyBeamCoinPickerState extends State<BuyBeamCoinPicker> {
  final _search = TextEditingController();
  List<BuyBeamAsset>? _all;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      final list = await widget.deps.controller.assets(refresh: refresh);
      if (mounted) setState(() => _all = list);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _matches(BuyBeamAsset a) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return a.symbol.toLowerCase().contains(q) ||
        a.chainName.toLowerCase().contains(q) ||
        a.blockchain.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final all = _all;
    final shown = all?.where(_matches).toList();
    final popular = shown?.where(isPopularBuyBeamAsset).toList();
    final rest = shown?.where((a) => !isPopularBuyBeamAsset(a)).toList();
    final heading = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    return DexPage(
      deps: widget.deps,
      title: 'Pay with',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('buy-coin-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'Coin or chain (BTC, Tron, Solana…)',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 12),
          if (_failed)
            DexNotice(
              key: const Key('buy-coins-failed'),
              sticker: BeamMoments.somethingWentWrong,
              kind: DexNoticeKind.error,
              title: "Couldn't reach buybeam.my",
              detail: [
                'This is not something you did. Nothing was sent.',
                if (widget.deps.tor)
                  'If Tor is on, a new connection usually helps.',
              ].join(' '),
              actionLabel: 'Try again',
              onAction: () {
                setState(() => _failed = false);
                unawaited(_load(refresh: true));
              },
            )
          else if (all == null)
            Text(
              'Loading the coins buybeam.my takes…',
              style: STextStyles.label(context),
            )
          else ...[
            if (popular!.isNotEmpty) ...[
              Text('Most used', style: heading),
              for (final a in popular) _row(context, a),
              const SizedBox(height: 12),
            ],
            if (rest!.isNotEmpty) ...[
              Text('All coins (${all.length})', style: heading),
              for (final a in rest) _row(context, a),
            ],
            if (shown!.isEmpty)
              Text(
                'buybeam.my does not take "${_search.text.trim()}". Try '
                'its ticker or its chain.',
                style: STextStyles.label(context),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, BuyBeamAsset a) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final p = a.priceUsd;
    return InkWell(
      key: Key('buy-coin-${a.assetId}'),
      onTap: () => Navigator.of(context).pop(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            BuyCoinIcon(assetId: a.assetId, symbol: a.symbol, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.symbol, style: STextStyles.titleBold12(context)),
                  Text(
                    a.isNative ? a.chainName : 'on ${a.chainName}',
                    style: STextStyles.label(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
            ),
            if (p != null)
              Text(
                p >= 100
                    ? '\$${p.toStringAsFixed(0)}'
                    : p >= 1
                    ? '\$${p.toStringAsFixed(2)}'
                    : '\$${p.toStringAsPrecision(3)}',
                style: STextStyles.itemSubtitle12(context),
              ),
          ],
        ),
      ),
    );
  }
}
