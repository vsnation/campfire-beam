/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// "Assets" in the desktop side menu: what the wallet holds and what it is
// worth, laid out like the wallet screen (a card on the left, the list on
// the right).
//
// Spec:
//   1. Job: see every asset of value and what it is worth; open one.
//   2. Primary CTA: the rows themselves (open the asset: Send / Receive).
//      "Receive assets" is the one secondary button.
//   3. Clicks from app open: Assets (1) → an asset (2) → its Send tab.
//
// Exit-intent and how this page answers it:
// * "Is that total real?" — it says what it is: today's DEX prices, how old
//   they are, and which assets have no price (never counted as zero).
// * "Spam tokens bury what I hold" — like the wallet's dashboard, only BEAM,
//   verified assets and assets worth something are listed; the rest are one
//   click away ("See all"), never lost.
// * "Is this FOMO real?" — a look-alike says "Not the verified FOMO (#174)"
//   in its own row.
// * Waiting for the core — rows and saved prices show at once (R11).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../pages/token_view/beam_asset_navigation.dart';
import '../../../pages/token_view/beam_asset_receive_view.dart';
import '../../../pages/token_view/beam_assets_view.dart';
import '../../../pages/token_view/my_tokens_view.dart';
import '../../../providers/db/main_db_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_holdings.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart';
import '../../../wallets/beam/assets/beam_asset_registry.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../widgets/beam/assets/beam_asset_logo.dart';
import '../../../widgets/beam/wallet_home/beam_dashboard_assets.dart';
import '../../../widgets/beam/wallet_home/beam_wallet_home.dart'
    show BeamHomeFormat, pBeamHomeFormat;
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../my_stack_view/wallet_view/sub_widgets/beam_desktop_wallet_summary.dart';
import 'beam_sidebar_scaffold.dart';

/// The totals card, without Flutter: [beamSpendable] plus every priced,
/// visible asset, in BEAM and (when Campfire may look prices up) in fiat.
@immutable
class BeamSidebarAssetsTotal {
  const BeamSidebarAssetsTotal({
    required this.primary,
    this.secondary,
    required this.note,
  });

  /// "1,240.12 USD", or "≈ 12.5 BEAM" without a price.
  final String primary;

  /// "≈ 12.5 BEAM" under a fiat total.
  final String? secondary;

  /// What the number is, and what it leaves out.
  final String note;

  static BeamSidebarAssetsTotal build({
    required BigInt beamSpendable,
    required BeamAssetPortfolio portfolio,
    required bool holdsAssets,
    required BeamHomeFormat format,
  }) {
    final groth = beamSpendable + portfolio.valueGroth;
    final beam = format.formatBeam(Amount(rawValue: groth, fractionDigits: 8));
    final fiat = format.fiatOfGroth(groth);
    final String note;
    if (!holdsAssets) {
      note = 'Your BEAM, ready to spend.';
    } else if (!portfolio.marketKnown) {
      note =
          'Your BEAM only for now: asset prices load once the wallet is '
          'connected.';
    } else if (portfolio.unpriced > 0) {
      final n = portfolio.unpriced;
      note =
          'BEAM plus assets at today\'s DEX prices. $n '
          '${n == 1 ? 'asset has' : 'assets have'} no price and '
          '${n == 1 ? 'is' : 'are'} not counted.';
    } else {
      note = 'BEAM plus assets at today\'s DEX prices.';
    }
    final pricesOff = format.pricesOn
        ? ''
        : ' Price lookups are off in Settings, so values are in BEAM.';
    return BeamSidebarAssetsTotal(
      primary: fiat ?? '≈ $beam',
      secondary: fiat == null ? null : '≈ $beam',
      note: '$note$pricesOff',
    );
  }
}

class BeamSidebarAssetsPage extends ConsumerStatefulWidget {
  const BeamSidebarAssetsPage({super.key, required this.wallet});

  final BeamWallet wallet;

  @override
  ConsumerState<BeamSidebarAssetsPage> createState() =>
      _BeamSidebarAssetsPageState();
}

class _BeamSidebarAssetsPageState extends ConsumerState<BeamSidebarAssetsPage> {
  Timer? _refresh;

  String get _walletId => widget.wallet.walletId;

  @override
  void initState() {
    super.initState();
    // Names of new assets and DEX prices come once the core is up; the
    // cached rows and saved prices show until then (R11).
    unawaited(
      widget.wallet.whenLive.then((_) async {
        if (!mounted) return;
        ref.refresh(pBeamAssetMarket(_walletId));
        await _syncNames();
      }),
    );
    // Re-read prices while the page is open, as the dashboard does.
    _refresh = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted) ref.refresh(pBeamAssetMarket(_walletId));
    });
  }

  Future<void> _syncNames() async {
    try {
      final market = await ref.read(pBeamAssetMarket(_walletId).future);
      if (!mounted) return;
      await BeamAssetRegistry.sync(
        isar: ref.read(mainDBProvider).isar,
        heldIds: ref.read(pBeamAssetTotals(_walletId)).keys,
        api: widget.wallet.coreApi,
        pools: market?.pools,
      );
    } catch (_) {
      // The cached rows stay; the next visit tries again.
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _openAll() => unawaited(
    Navigator.of(context)
        .pushNamed(MyTokensView.routeName, arguments: _walletId),
  );

  Future<void> _open(BeamDashboardRow row) async {
    final contract = row.contract;
    if (contract == null) return;
    await openBeamAsset(
      context: context,
      ref: ref,
      walletId: _walletId,
      asset: contract,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final campfire = ref.watch(pBeamHomeFormat(_walletId));
    // Rounded to what a person reads; each asset's page shows every
    // digit.
    final format = BeamHomeFormat(
      formatBeam: (a) => '${BeamDashboardModel.shortAmount(a.raw)} BEAM',
      pricesOn: campfire.pricesOn,
      price: campfire.price,
      currency: campfire.currency,
      locale: campfire.locale,
      fractionDigits: campfire.fractionDigits,
    );
    final holdings = ref.watch(pBeamAssetHoldings(_walletId));
    final market = ref.watch(pBeamAssetMarket(_walletId)).asData?.value;
    final spendable = ref.watch(pWalletBalance(_walletId)).spendable.raw;
    final model = BeamDashboardModel.build(
      beamSpendable: spendable,
      holdings: holdings,
      market: market,
      formatBeam: format.formatBeam,
      fiat: format.fiat,
      now: DateTime.now(),
      // Every asset worth listing (the dashboard shows the first few).
      maxRows: 1 << 20,
    );
    final total = BeamSidebarAssetsTotal.build(
      beamSpendable: spendable,
      portfolio: BeamAssetHoldings.portfolio(
        holdings,
        marketKnown: market != null,
      ),
      holdsAssets: holdings.any((h) => h.totals.total > BigInt.zero),
      format: format,
    );
    final label = STextStyles.desktopTextExtraSmall(context)
        .copyWith(color: colors.textFieldActiveSearchIconLeft);
    final others = model.rows.length - 1 + model.moreCount;

    return BeamSidebarScaffold(
      title: 'Assets',
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamDesktopSyncBanner(walletId: _walletId),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 340,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 40,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Total value', style: label),
                          ),
                        ),
                        _TotalCard(total: total),
                        const SizedBox(height: 16),
                        SecondaryButton(
                          key: const Key('beamSidebarAssetsReceive'),
                          label: 'Receive assets',
                          buttonHeight: ButtonHeight.l,
                          onPressed: () => unawaited(
                            showBeamAssetReceive(
                              context: context,
                              walletId: _walletId,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 40,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text('Your assets', style: label),
                              ),
                              CustomTextButton(
                                key: const Key('beamSidebarAssetsSeeAll'),
                                text: model.moreCount > 0
                                    ? 'See all ($others)'
                                    : 'Show or hide assets',
                                onTap: _openAll,
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: RoundedWhiteContainer(
                            padding: EdgeInsets.zero,
                            child: ListView.separated(
                              key: const Key('beamSidebarAssetsList'),
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: model.rows.length,
                              separatorBuilder: (_, _) => Divider(
                                height: 1,
                                thickness: 1,
                                indent: 16,
                                endIndent: 16,
                                color: colors.backgroundAppBar,
                              ),
                              itemBuilder: (context, i) {
                                final row = model.rows[i];
                                return _AssetRow(
                                  row: row,
                                  onTap: row.contract == null
                                      ? null
                                      : () => unawaited(_open(row)),
                                );
                              },
                            ),
                          ),
                        ),
                        if (model.moreCount > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              model.moreCount == 1
                                  ? '1 more asset is hidden or has no '
                                        'price. See all to show it.'
                                  : '${model.moreCount} more assets are '
                                        'hidden or have no price. See all '
                                        'to show them.',
                              style: STextStyles.desktopTextExtraExtraSmall(
                                context,
                              ),
                            ),
                          ),
                        if (model.priceNote != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              model.priceNote!,
                              key: const Key('beamSidebarAssetsPriceNote'),
                              style: STextStyles.desktopTextExtraExtraSmall(
                                context,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.total});

  final BeamSidebarAssetsTotal total;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            total.primary,
            key: const Key('beamSidebarAssetsTotal'),
            style: STextStyles.desktopH3(context),
          ),
          if (total.secondary != null) ...[
            const SizedBox(height: 4),
            Text(
              total.secondary!,
              style: STextStyles.desktopTextExtraSmall(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            total.note,
            style: STextStyles.desktopTextExtraExtraSmall(context),
          ),
        ],
      ),
    );
  }
}

/// One asset: logo, name and amount; value (fiat, else BEAM) on the right.
class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.row, this.onTap});

  final BeamDashboardRow row;

  /// Null for BEAM itself (its page is the wallet).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final display = row.display;
    return InkWell(
      key: Key('beamSidebarAssetRow${row.assetId}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            if (display != null)
              BeamAssetLogo(display, size: 36)
            else
              const SizedBox(width: 36),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.desktopTextExtraSmall(context)
                        .copyWith(color: c.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    row.amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.desktopTextExtraExtraSmall(context),
                  ),
                  if (row.warning != null)
                    Text(
                      row.warning!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: STextStyles.desktopTextExtraExtraSmall(context)
                          .copyWith(color: c.textError),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  row.value,
                  style: STextStyles.desktopTextExtraSmall(context)
                      .copyWith(color: c.textDark),
                ),
                if (row.valueNote != null)
                  Text(
                    row.valueNote!,
                    style: STextStyles.desktopTextExtraExtraSmall(context),
                  ),
              ],
            ),
            SizedBox(
              width: 28,
              child: onTap == null
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: SvgPicture.asset(
                        Assets.svg.chevronRight,
                        width: 7,
                        height: 12,
                        colorFilter: ColorFilter.mode(
                          c.textSubtitle1,
                          BlendMode.srcIn,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Every asset the wallet holds, hidden and unpriced ones too, with the
/// switch to hide or show them: Campfire's BEAM asset list, beside the menu.
class BeamSidebarAllAssetsPage extends ConsumerWidget {
  const BeamSidebarAllAssetsPage({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final externalCalls = ref.watch(
      prefsChangeNotifierProvider.select((p) => p.externalCalls),
    );
    return BeamSidebarSubPage(
      title: 'All assets',
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: BeamAssetsView(walletId: walletId)),
                if (!externalCalls)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Values in BEAM: price lookups are off in Settings.',
                      style: STextStyles.desktopTextExtraExtraSmall(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
