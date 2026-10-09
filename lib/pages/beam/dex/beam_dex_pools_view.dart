/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: find a pool to put coins into (or take them out of).
// 2. Primary action: tap a pool. The only button is the secondary "Create a
//    pool"; the pool cards are the main targets.
// 3. Taps from app open: wallet → Swap → Pools (3) → a pool (4).
//
// Exit-intent — what could make an impatient person leave:
// * 75 pools of unknown tokens — the user's own pools come first, then
//   pools ordered by how much BEAM they hold; a search box filters by
//   name, ticker or #id.
// * Fake look-alike tokens — unverified assets show their #id and a red
//   "Not the verified …" line.
// * "What is a pool?" — one plain sentence under the title.
// * "Is this pool worth my time?" — each pool says its size in the user's
//   currency (or "no price" when its assets have none).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../../wallets/beam/models/beam_wallet_status.dart';
import '../../../widgets/beam/dex/dex_asset_icon.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/beam/dex/dex_format.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/stack_text_field.dart';
import 'beam_dex_create_pool_view.dart';
import 'beam_dex_pool_detail_view.dart';

/// The DEX pools: the user's positions first, then every pool with
/// liquidity, deepest first.
class BeamDexPoolsView extends StatefulWidget {
  const BeamDexPoolsView({
    super.key,
    required this.deps,
    this.embedded = false,
  });

  final BeamDexDeps deps;

  /// True inside the desktop DEX view: the list without a page around it.
  final bool embedded;

  @override
  State<BeamDexPoolsView> createState() => _BeamDexPoolsViewState();
}

class _BeamDexPoolsViewState extends State<BeamDexPoolsView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  BeamDexDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_rebuild);
    unawaited(deps.pools.ensureLoaded());
  }

  @override
  void dispose() {
    deps.changes.removeListener(_rebuild);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool _matches(BeamPool p, String q) {
    if (q.isEmpty) return true;
    final s = q.toLowerCase().replaceFirst('#', '');
    for (final id in [p.aid1, p.aid2]) {
      final a = deps.display(id);
      if (a.symbol.toLowerCase().contains(s) ||
          a.name.toLowerCase().contains(s) ||
          '$id' == s) {
        return true;
      }
    }
    return false;
  }

  /// What the pool holds, both sides valued in BEAM (a BEAM pool counts
  /// its BEAM twice: the other side is worth the same at the pool price).
  /// A side without a price counts as nothing, for ordering only.
  BigInt _depth(BeamPool p) {
    final v1 = deps.valueInBeam(p.aid1, p.tok1);
    final v2 = deps.valueInBeam(p.aid2, p.tok2);
    return (v1 ?? BigInt.zero) + (v2 ?? BigInt.zero);
  }

  /// "Pool size ≈ 21.10 USD" ("≈ 2,469.1 BEAM" without a fiat price), or
  /// "Pool size: no price" when a side has none.
  String _size(BeamPool p) {
    final size = deps.poolSize(p);
    if (size == null) return 'Pool size: no price';
    return 'Pool size ${deps.worthOfBeam(size, inBeam: true)}';
  }

  Future<void> _open(BeamPool pool) => showDexPage<void>(
    context,
    deps,
    (_) => BeamDexPoolDetailView(deps: deps, pool: pool),
  );

  Future<void> _create() => showDexPage<void>(
    context,
    deps,
    (_) => BeamDexCreatePoolView(deps: deps),
  );

  @override
  Widget build(BuildContext context) {
    final body = _list(context);
    // Shown once pools are known and some exist: before that, "create"
    // could not tell whether the pool is already there, and an empty list
    // already offers it as its main button.
    final store = deps.pools;
    final Widget? bottom = store.all == null || store.live.isEmpty
        ? null
        : SecondaryButton(
            key: const Key('dex-create-pool'),
            label: 'Create a pool',
            buttonHeight: deps.desktop ? ButtonHeight.l : ButtonHeight.xl,
            onPressed: _create,
          );
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: SingleChildScrollView(child: body)),
          if (bottom != null) ...[const SizedBox(height: 12), bottom],
        ],
      );
    }
    return DexPage(deps: deps, title: 'Pools', body: body, bottom: bottom);
  }

  Widget _list(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final store = deps.pools;
    final all = store.all;
    final intro = Text(
      'Add your coins to a pool and earn a share of the fee on every swap '
      'it makes.',
      style: STextStyles.smallMed12(context),
    );
    if (all == null) {
      if (store.error != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            intro,
            const SizedBox(height: 12),
            DexNotice(
              key: const Key('dex-pools-error'),
              sticker: BeamMoments.somethingWentWrong,
              kind: DexNoticeKind.error,
              title: "Couldn't load the pools",
              detail:
                  "The wallet didn't answer. This is not something you "
                  'did.',
              actionLabel: 'Try again',
              onAction: () => unawaited(store.refresh()),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          intro,
          const SizedBox(height: 24),
          Text(
            'Loading pools from the BEAM network…',
            key: const Key('dex-pools-loading'),
            textAlign: TextAlign.center,
            style: STextStyles.smallMed12(context),
          ),
        ],
      );
    }
    final q = _search.text.trim();
    final balances = deps.balances.value;
    final mine = <BeamPool>[];
    final rest = <BeamPool>[];
    for (final p in all) {
      final held = balances[p.lpToken]?.available ?? BigInt.zero;
      if (held > BigInt.zero) {
        if (_matches(p, q)) mine.add(p);
      } else if (!p.isEmpty && _matches(p, q)) {
        rest.add(p);
      }
    }
    final depth = {
      for (final p in [...mine, ...rest]) p: _depth(p),
    };
    int byDepth(BeamPool a, BeamPool b) => depth[b]!.compareTo(depth[a]!);
    mine.sort(byDepth);
    rest.sort(byDepth);

    final children = <Widget>[
      intro,
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: TextField(
          key: const Key('dex-pools-search'),
          controller: _search,
          focusNode: _searchFocus,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          style: STextStyles.field(context),
          decoration: standardInputDecoration(
            'Search by name, ticker or #id',
            _searchFocus,
            context,
          ),
        ),
      ),
      const SizedBox(height: 12),
    ];

    if (store.live.isEmpty && mine.isEmpty) {
      // Nothing to search: drop the search box.
      children
        ..clear()
        ..addAll([intro, const SizedBox(height: 12)]);
      children.add(
        const DexNotice(
          key: Key('dex-pools-empty'),
          sticker: BeamMoments.trading,
          title: 'No pools have coins yet',
          detail:
              'Create the first pool and earn the fee on every swap it '
              'makes.',
        ),
      );
      children.add(const SizedBox(height: 12));
      children.add(
        PrimaryButton(
          key: const Key('dex-pools-empty-create'),
          label: 'Create a pool',
          onPressed: _create,
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    if (mine.isEmpty && rest.isEmpty) {
      children.add(
        DexNotice(
          key: const Key('dex-pools-no-match'),
          title: 'No pool matches "$q"',
          detail: 'Search by name, ticker or #id, or create the pool.',
          actionLabel: 'Create a pool',
          onAction: _create,
        ),
      );
    }
    if (mine.isNotEmpty) {
      children.add(_section(context, 'Your pools'));
      for (final p in mine) {
        children
          ..add(_card(context, p, balances))
          ..add(const SizedBox(height: 8));
      }
      children.add(const SizedBox(height: 8));
    }
    if (rest.isNotEmpty) {
      children.add(_section(context, 'All pools · ${rest.length}'));
      for (final p in rest) {
        children
          ..add(_card(context, p, balances))
          ..add(const SizedBox(height: 8));
      }
    }
    if (store.error != null) {
      children.insert(
        0,
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'Showing the last pools we loaded; the latest could not be '
            'fetched.',
            style: STextStyles.label(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      title,
      style: STextStyles.itemSubtitle(
        context,
      ).copyWith(color: Theme.of(context).extension<StackColors>()!.textDark3),
    ),
  );

  /// One side of a pool's name: "FOMO", "PEPE #777" (the number in a
  /// quieter colour), or an LP token's pair in brackets, "(BEAM/NPH LP)".
  List<InlineSpan> _side(BeamAssetDisplay a, StackColors colors) => [
    if (a.isPoolShare)
      TextSpan(text: '(${a.label})')
    else ...[
      TextSpan(text: a.symbol),
      if (!a.verified && a.symbol != a.idLabel)
        TextSpan(
          text: ' ${a.idLabel}',
          style: TextStyle(color: colors.textSubtitle1),
        ),
    ],
  ];

  Widget _card(
    BuildContext context,
    BeamPool p,
    Map<int, BeamAssetTotals> balances,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final a1 = deps.display(p.aid1);
    final a2 = deps.display(p.aid2);
    final held = balances[p.lpToken]?.available ?? BigInt.zero;
    return DexCard(
      key: Key('dex-pool-${p.aid1}-${p.aid2}-${p.kind.wire}'),
      onTap: () => unawaited(_open(p)),
      child: Row(
        children: [
          DexPairIcon(first: a1, second: a2, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            ..._side(a1, colors),
                            const TextSpan(text: ' / '),
                            ..._side(a2, colors),
                          ],
                        ),
                        style: STextStyles.smallMed14(context)
                            .copyWith(color: colors.textDark),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _FeeChip(label: DexFormat.feeTier(p.kind)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  p.isEmpty
                      ? 'Empty'
                      : '${DexFormat.compact(p.tok1)} ${a1.symbol} · '
                            '${DexFormat.compact(p.tok2)} ${a2.symbol}',
                  style: STextStyles.label(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!p.isEmpty)
                  Text(
                    _size(p),
                    key: Key('dex-pool-size-${p.lpToken}'),
                    style: STextStyles.label(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (a1.impersonates != null) DexImpersonationWarning(asset: a1),
                if (a2.impersonates != null) DexImpersonationWarning(asset: a2),
                if (held > BigInt.zero)
                  Text(
                    'Your share of the pool: '
                    '${DexFormat.percent(p.position(held).share)}',
                    key: Key('dex-pool-share-${p.lpToken}'),
                    style: STextStyles.label(context)
                        .copyWith(color: colors.accentColorGreen),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: colors.textSubtitle1,
          ),
        ],
      ),
    );
  }
}

class _FeeChip extends StatelessWidget {
  const _FeeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.buttonBackSecondary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: STextStyles.label(context)
            .copyWith(color: colors.buttonTextSecondary, fontSize: 10),
      ),
    );
  }
}
