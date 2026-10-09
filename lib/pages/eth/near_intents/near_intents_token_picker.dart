/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: pick the coin you have, and its chain.
// 2. Primary action: tap it.
// 3. One tap from the coin button.
//
// The coins people bring most come first (BTC, ZEC, LTC, USDT on Tron…),
// then every other coin NEAR Intents takes, by chain.
// Each row names its chain, because USDT on Tron and USDT on BNB Chain are
// different deposits.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/near_intents/one_click_client.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import 'near_intents_view.dart';
import 'near_intents_widgets.dart';

Future<OneClickToken?> showNearIntentsTokenPicker(
  BuildContext context, {
  required NearIntentsDeps deps,
}) => showDexPage<OneClickToken>(
  context,
  deps.uniswap,
  (_) => NearIntentsTokenPicker(deps: deps),
);

class NearIntentsTokenPicker extends StatefulWidget {
  const NearIntentsTokenPicker({super.key, required this.deps});

  final NearIntentsDeps deps;

  @override
  State<NearIntentsTokenPicker> createState() => _NearIntentsTokenPickerState();
}

class _NearIntentsTokenPickerState extends State<NearIntentsTokenPicker> {
  final _search = TextEditingController();
  List<OneClickToken>? _all;
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

  Future<void> _load() async {
    try {
      final t = await widget.deps.tokens();
      if (mounted) setState(() => _all = t);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _matches(OneClickToken t) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.symbol.toLowerCase().contains(q) ||
        t.chainName.toLowerCase().contains(q) ||
        t.blockchain.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final all = _all;
    final shown = all?.where(_matches).toList();
    final popular = shown
        ?.where(
          (t) => kOneClickPopular.any(
            (p) => p.$1 == t.symbol && p.$2 == t.blockchain,
          ),
        )
        .toList();
    final rest = shown?.where((t) => !(popular?.contains(t) ?? false)).toList();
    final heading = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    return DexPage(
      deps: widget.deps.uniswap,
      title: 'The coin you send',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('ni-coin-search'),
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
              key: const Key('ni-coins-failed'),
              sticker: BeamMoments.somethingWentWrong,
              kind: DexNoticeKind.error,
              title: "Couldn't load NEAR Intents' coins",
              detail: 'This is not something you did. Try again in a moment.',
              actionLabel: 'Try again',
              onAction: () {
                setState(() => _failed = false);
                unawaited(_load());
              },
            )
          else if (all == null)
            Text(
              'Loading the coins NEAR Intents takes…',
              style: STextStyles.label(context),
            )
          else ...[
            if (popular!.isNotEmpty) ...[
              Text('Most used', style: heading),
              for (final t in popular) _row(context, t),
              const SizedBox(height: 12),
            ],
            if (rest!.isNotEmpty) ...[
              Text('All coins (${all.length})', style: heading),
              for (final t in rest) _row(context, t),
            ],
            if (shown!.isEmpty)
              Text(
                'NEAR Intents does not take "${_search.text.trim()}".',
                style: STextStyles.label(context),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, OneClickToken t) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return InkWell(
      key: Key('ni-coin-${t.assetId}'),
      onTap: () => Navigator.of(context).pop(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            NearIntentsCoinIcon(token: t, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.symbol, style: STextStyles.titleBold12(context)),
                  Text(
                    t.isNative ? t.chainName : 'on ${t.chainName}',
                    style: STextStyles.label(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
            ),
            if (t.priceUsd != null)
              Text(
                '\$${t.priceUsd! >= 100
                    ? t.priceUsd!.toStringAsFixed(0)
                    : t.priceUsd! >= 1
                    ? t.priceUsd!.toStringAsFixed(2)
                    : t.priceUsd!.toStringAsPrecision(3)}',
                style: STextStyles.itemSubtitle12(context),
              ),
          ],
        ),
      ),
    );
  }
}
