/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../stack_text_field.dart';
import 'dex_asset_icon.dart';
import 'dex_deps.dart';
import 'dex_format.dart';
import 'dex_widgets.dart';

/// Every asset that trades in a pool with liquidity, LP tokens and assets
/// the user hid left out: BEAM first, then verified assets by pool depth,
/// then the rest by id.
List<int> dexTradableAssets(BeamDexDeps deps) {
  final live = deps.pools.live;
  final lp = deps.pools.lpTokens;
  final hidden = deps.hiddenAssetIds();
  final depth = <int, BigInt>{};
  for (final p in live) {
    for (final a in [p.aid1, p.aid2]) {
      if (lp.contains(a) || (a != 0 && hidden.contains(a))) continue;
      final beamSide = p.aid1 == 0 ? p.tok1 : BigInt.zero;
      final d = depth[a];
      if (d == null || beamSide > d) depth[a] = beamSide;
    }
  }
  depth[0] = depth[0] ?? BigInt.zero;
  int rank(int a) => a == 0
      ? 0
      : BeamAssetCatalog.verified.containsKey(a)
      ? 1
      : 2;
  final ids = depth.keys.toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      if (rank(a) == 1) {
        final c = depth[b]!.compareTo(depth[a]!);
        if (c != 0) return c;
      }
      return a.compareTo(b);
    });
  return ids;
}

/// Lets the user pick an asset: a bottom sheet on mobile, a dialog on
/// desktop. Returns the chosen asset id, or null.
Future<int?> showDexAssetPicker(
  BuildContext context, {
  required BeamDexDeps deps,
  required String title,
  required List<int> assets,
  int? selected,
}) {
  final body = _DexAssetPicker(
    deps: deps,
    title: title,
    assets: assets,
    selected: selected,
  );
  if (deps.desktop) {
    return showDexPage<int>(context, deps, (_) => body);
  }
  final colors = Theme.of(context).extension<StackColors>()!;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colors.popupBG,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => FractionallySizedBox(heightFactor: 0.85, child: body),
  );
}

class _DexAssetPicker extends StatefulWidget {
  const _DexAssetPicker({
    required this.deps,
    required this.title,
    required this.assets,
    this.selected,
  });

  final BeamDexDeps deps;
  final String title;
  final List<int> assets;
  final int? selected;

  @override
  State<_DexAssetPicker> createState() => _DexAssetPickerState();
}

class _DexAssetPickerState extends State<_DexAssetPicker> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Names (the explorer's list of every asset) and prices can arrive
    // while the list is open.
    widget.deps.changes.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.deps.changes.removeListener(_rebuild);
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  bool _matches(BeamAssetDisplay a, String q) {
    if (q.isEmpty) return true;
    final s = q.toLowerCase().replaceFirst('#', '');
    return a.symbol.toLowerCase().contains(s) ||
        a.name.toLowerCase().contains(s) ||
        '${a.assetId}' == s;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final deps = widget.deps;
    final q = _search.text.trim();
    final shown = [
      for (final id in widget.assets)
        if (_matches(deps.display(id), q)) id,
    ];
    final list = shown.isEmpty
        ? Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No asset matches "$q". Search by name, ticker or #id.',
              style: STextStyles.smallMed12(context),
            ),
          )
        : ListView.builder(
            shrinkWrap: deps.desktop,
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final id = shown[i];
              final a = deps.display(id);
              final bal = deps.available(id);
              return InkWell(
                key: Key('dex-asset-option-$id'),
                onTap: () => Navigator.of(context).pop(id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      DexAssetIcon(asset: a, size: 32),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            DexAssetName(asset: a),
                            Text(
                              a.verified ? a.name : 'Not verified · ${a.name}',
                              style: STextStyles.label(context),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (bal > BigInt.zero)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              DexFormat.compact(bal),
                              style: STextStyles.itemSubtitle12(context),
                            ),
                            if (deps.worth(id, bal) case final worth?)
                              Text(
                                worth,
                                key: Key('dex-asset-worth-$id'),
                                style: STextStyles.label(context),
                              ),
                            // An unverified asset is valued at what its pool
                            // would pay, as on the dashboard. Its own line,
                            // so the asset's name is not cut for it.
                            if (deps.pools.pricer?.isSaleValue(id) ?? false)
                              Text(
                                'if sold now',
                                key: Key('dex-asset-sold-$id'),
                                style: STextStyles.label(context),
                              ),
                          ],
                        ),
                      if (id == widget.selected) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: colors.accentColorGreen,
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
    final search = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: TextField(
          key: const Key('dex-asset-search'),
          controller: _search,
          focusNode: _focus,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          style: STextStyles.field(context),
          decoration: standardInputDecoration(
            'Search by name, ticker or #id',
            _focus,
            context,
          ),
        ),
      ),
    );
    if (deps.desktop) {
      return DexPage(
        deps: deps,
        title: widget.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [search, list],
        ),
      );
    }
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.title, style: STextStyles.pageTitleH2(context)),
          ),
          search,
          Expanded(child: list),
        ],
      ),
    );
  }
}

/// Live pools that trade [a] against [b], deepest first.
List<BeamPool> dexPoolsForPair(BeamDexDeps deps, int a, int b) =>
    deps.pools.live.where((p) => p.pairs(a, b)).toList()
      ..sort((x, y) => y.reserveOf(a).compareTo(x.reserveOf(a)));
