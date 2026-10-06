/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Job: see everything of value in this wallet and what it is worth, and
//      send any of it.
// Primary CTA: none of its own (the bottom bar's Send stays the screen's
//      one primary action); each row has a quiet Send icon.
// Taps from app open: wallet (1) → Send on the asset's row (2).
//
// Exit intent: a long tail of spam tokens burying what matters (hidden:
// only valuable or verified assets show, the rest are one tap away in
// Assets); prices that pop in seconds late (saved prices show at once).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../pages/send_view/send_view.dart';
import '../../../pages/token_view/beam_asset_navigation.dart';
import '../../../pages/token_view/my_tokens_view.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/assets/beam_asset_holdings.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart';
import '../../../wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../rounded_white_container.dart';
import '../assets/beam_asset_logo.dart';
import 'beam_wallet_home.dart';

/// One row of the dashboard's asset list.
@immutable
class BeamDashboardRow {
  const BeamDashboardRow({
    required this.assetId,
    required this.title,
    required this.amount,
    required this.value,
    this.valueNote,
    this.warning,
    this.contract,
    this.display,
  });

  final int assetId;

  /// "BEAM", "FOMO", "Pepe Coin #777".
  final String title;

  /// What the wallet holds, short: "568.1297 FOMO".
  final String amount;

  /// What it is worth: "4.91 USD", or "≈ 69.99 BEAM" when prices are off,
  /// or "No price".
  final String value;

  /// "≈ 69.99 BEAM" under a fiat value for non-BEAM assets.
  final String? valueNote;

  /// "Not the verified FOMO (#174)" for a look-alike.
  final String? warning;

  /// Null for BEAM itself.
  final BeamAssetContract? contract;

  final BeamAssetDisplay? display;
}

/// The rows and the line under them, decided without Flutter so they can
/// be tested exactly.
class BeamDashboardModel {
  const BeamDashboardModel({
    required this.rows,
    required this.moreCount,
    this.priceNote,
  });

  final List<BeamDashboardRow> rows;

  /// Held assets not listed (hidden, unpriced spam, beyond [maxRows]).
  final int moreCount;

  /// "Prices from 25 min ago", "Getting prices…", or null.
  final String? priceNote;

  /// At most this many rows, BEAM included: a phone keeps room for the
  /// history below, a desktop shows more.
  static const int maxRowsPhone = 4;
  static const int maxRowsDesktop = 6;

  /// An unverified asset is listed only when it is worth at least this much
  /// in BEAM: a value below it is noise, and spam pools are priced by the
  /// pricer's own sanity rules first.
  static final BigInt minUnverifiedValueGroth = BigInt.from(100000000);

  static BeamDashboardModel build({
    required BigInt beamSpendable,
    required List<BeamAssetHolding> holdings,
    required BeamAssetMarket? market,
    required String Function(Amount beam) formatBeam,
    required String? Function(Amount beam) fiat,
    required DateTime now,
    int maxRows = maxRowsPhone,
  }) {
    final beam = Amount(rawValue: beamSpendable, fractionDigits: 8);
    final rows = <BeamDashboardRow>[
      BeamDashboardRow(
        assetId: 0,
        title: 'BEAM',
        amount: formatBeam(beam),
        value: fiat(beam) ?? formatBeam(beam),
        display: BeamAssetCatalog.display(0, null),
      ),
    ];
    var more = 0;
    for (final h in holdings) {
      if (h.assetId == 0) continue;
      if (h.totals.total <= BigInt.zero) continue;
      final c = h.contract;
      final value = h.valueGroth;
      final listed =
          !h.hidden &&
          (c.verified || (value != null && value >= minUnverifiedValueGroth));
      if (!listed || rows.length >= maxRows) {
        more++;
        continue;
      }
      final inBeam = value == null
          ? null
          : Amount(rawValue: value, fractionDigits: 8);
      final fiatValue = inBeam == null ? null : fiat(inBeam);
      // An unverified asset is valued at what its pool would pay for it
      // (BeamAssetPricer.isSaleValue), so say that rather than a price.
      final sold = h.saleValue ? ' if sold now' : '';
      final look = BeamAssetCatalog.display(c.assetId, null);
      final copied = c.impersonates;
      rows.add(
        BeamDashboardRow(
          assetId: c.assetId,
          title: c.verified ? c.symbol : '${c.symbol} #${c.assetId}',
          amount: '${shortAmount(h.totals.total)} ${c.symbol}',
          value:
              fiatValue ??
              (inBeam == null ? 'No price' : '≈ ${formatBeam(inBeam)}$sold'),
          valueNote: fiatValue != null && inBeam != null
              ? '≈ ${formatBeam(inBeam)}$sold'
              : null,
          warning: copied == null
              ? null
              : 'Not the verified '
                    '${BeamAssetCatalog.verified[copied]?.symbol ?? '#$copied'}'
                    ' (#$copied)',
          contract: c,
          display: BeamAssetDisplay(
            assetId: c.assetId,
            name: c.name,
            symbol: c.symbol,
            verified: look.verified,
            icon: look.icon,
            color: look.color,
            impersonates: copied,
          ),
        ),
      );
    }
    final priced = rows.length > 1 || more > 0;
    String? note;
    if (priced && market == null) {
      note = 'Getting prices…';
    } else if (market != null) {
      final age = now.difference(market.readAt);
      if (age > const Duration(minutes: 10)) {
        note = 'Prices from ${_age(age)} ago';
      }
    }
    return BeamDashboardModel(rows: rows, moreCount: more, priceNote: note);
  }

  static String _age(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 48) return '${d.inHours} h';
    return '${d.inDays} days';
  }

  /// "568.1297", "1,234,567.5", "0.00012345": at most 4 decimals from 1 up,
  /// up to 8 below 1 so small balances never read as 0.
  static String shortAmount(BigInt raw) {
    final whole = raw ~/ BigInt.from(100000000);
    final frac = (raw % BigInt.from(100000000)).toString().padLeft(8, '0');
    final keep = whole > BigInt.zero ? frac.substring(0, 4) : frac;
    final trimmed = keep.replaceFirst(RegExp(r'0+$'), '');
    final w = whole.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );
    if (trimmed.isEmpty) {
      return whole == BigInt.zero && raw > BigInt.zero ? '< 0.0001' : w;
    }
    return '$w.$trimmed';
  }
}

/// The dashboard's asset list for one BEAM wallet (phone home).
class BeamDashboardAssets extends ConsumerStatefulWidget {
  const BeamDashboardAssets({
    super.key,
    required this.walletId,
    this.isDesktop = false,
  });

  final String walletId;
  final bool isDesktop;

  @override
  ConsumerState<BeamDashboardAssets> createState() =>
      _BeamDashboardAssetsState();
}

class _BeamDashboardAssetsState extends ConsumerState<BeamDashboardAssets> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Re-read DEX prices while the dashboard is on screen; the provider
    // keeps showing the last ones meanwhile.
    _refresh = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted) ref.refresh(pBeamAssetMarket(widget.walletId));
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _send(BeamDashboardRow row) async {
    final walletId = widget.walletId;
    if (!beamSendAllowed(context, ref, walletId)) return;
    final contract = row.contract;
    if (contract == null) {
      await Navigator.of(context).pushNamed(
        SendView.routeName,
        arguments: (walletId: walletId, coin: ref.read(pWalletCoin(walletId))),
      );
      return;
    }
    if (widget.isDesktop) {
      // The desktop asset page has Send as a tab.
      await openBeamAsset(
        context: context,
        ref: ref,
        walletId: walletId,
        asset: contract,
      );
      return;
    }
    final parent = ref.read(pBeamWallet(walletId));
    if (parent == null) return;
    final old = ref.read(beamAssetWalletStateProvider);
    if (old != null) unawaited(old.exit());
    final asset = BeamAssetWallet.load(parent: parent, asset: contract);
    ref.read(beamAssetWalletStateProvider.state).state = asset;
    unawaited(asset.init().catchError((Object _) {}));
    if (!mounted) return;
    await openBeamAssetSend(context, walletId);
  }

  Future<void> _open(BeamDashboardRow row) async {
    final contract = row.contract;
    if (contract == null) return _send(row);
    await openBeamAsset(
      context: context,
      ref: ref,
      walletId: widget.walletId,
      asset: contract,
    );
  }

  @override
  Widget build(BuildContext context) {
    final walletId = widget.walletId;
    final format = ref.watch(pBeamHomeFormat(walletId));
    final model = BeamDashboardModel.build(
      beamSpendable: ref.watch(pWalletBalance(walletId)).spendable.raw,
      holdings: ref.watch(pBeamAssetHoldings(walletId)),
      market: ref.watch(pBeamAssetMarket(walletId)).asData?.value,
      formatBeam: format.formatBeam,
      fiat: format.fiat,
      now: DateTime.now(),
      maxRows: widget.isDesktop
          ? BeamDashboardModel.maxRowsDesktop
          : BeamDashboardModel.maxRowsPhone,
    );
    // Show the list only when there is more than BEAM to show: the card
    // above already says what the BEAM balance is.
    if (model.rows.length < 2 && model.moreCount == 0) {
      return const SizedBox.shrink();
    }
    final c = Theme.of(context).extension<StackColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Your assets',
                style: STextStyles.itemSubtitle(context),
              ),
            ),
            CustomTextButton(
              key: const Key('beamDashboardSeeAll'),
              text: model.moreCount > 0
                  ? 'See all (${model.rows.length - 1 + model.moreCount})'
                  : 'See all',
              onTap: () =>
                  Navigator.of(context)
                      .pushNamed(MyTokensView.routeName, arguments: walletId),
            ),
          ],
        ),
        RoundedWhiteContainer(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < model.rows.length; i++) ...[
                if (i > 0)
                  Divider(height: 1, thickness: 1, color: c.backgroundAppBar),
                _AssetRow(
                  row: model.rows[i],
                  onTap: () => _open(model.rows[i]),
                  onSend: () => _send(model.rows[i]),
                  showSend: !(widget.isDesktop && model.rows[i].assetId == 0),
                ),
              ],
            ],
          ),
        ),
        if (model.priceNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              model.priceNote!,
              key: const Key('beamDashboardPriceNote'),
              style: STextStyles.w500_12(context)
                  .copyWith(color: c.textSubtitle1),
            ),
          ),
        if (!ref.watch(
          prefsChangeNotifierProvider.select((p) => p.externalCalls),
        ))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Values in BEAM: price lookups are off in Settings.',
              style: STextStyles.w500_12(context)
                  .copyWith(color: c.textSubtitle1),
            ),
          ),
      ],
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.row,
    required this.onTap,
    required this.onSend,
    required this.showSend,
  });

  final BeamDashboardRow row;
  final VoidCallback onTap;
  final VoidCallback onSend;
  final bool showSend;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final display = row.display;
    return InkWell(
      key: Key('beamDashboardRow${row.assetId}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            if (display != null)
              BeamAssetLogo(display, size: 34)
            else
              const SizedBox(width: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.w600_14(context)
                        .copyWith(color: c.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    row.amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: c.textSubtitle1),
                  ),
                  if (row.warning != null)
                    Text(
                      row.warning!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: c.textError),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  row.value,
                  style: STextStyles.w600_14(context)
                      .copyWith(color: c.textDark),
                ),
                if (row.valueNote != null)
                  Text(
                    row.valueNote!,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: c.textSubtitle1),
                  ),
              ],
            ),
            if (showSend)
              Semantics(
                button: true,
                label: 'Send ${row.title}',
                excludeSemantics: true,
                child: IconButton(
                  key: Key('beamDashboardSend${row.assetId}'),
                  tooltip: 'Send ${row.title}',
                  onPressed: onSend,
                  icon: SvgPicture.asset(
                    Assets.svg.send,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      c.accentColorDark,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              )
            else
              const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}
