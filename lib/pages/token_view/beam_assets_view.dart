/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6) — "My assets", Campfire's token list for BEAM:
//   Job:  see every asset this wallet holds and what it is roughly worth;
//         open one.
//   CTA:  the rows themselves (tap an asset). Empty list: "Receive assets".
//   Taps: open wallet → Assets → asset: 2 (3 to its Send).
//
// Exit-intent (§1.7) and how this screen answers it:
//   * "Is this FOMO real?" → copycats of verified assets carry a red
//     "Not the verified FOMO (#174)" in the row; unverified ones show #id.
//   * "Why is my total smaller than I think?" → the total says it is a DEX
//     estimate and how many assets have no price; they are never shown as 0.
//   * "Spam airdrops clutter my list" → the eye button hides them, and the
//     footer always offers to show them again (no dead end).
//   * "Nothing here" → the empty state says how assets arrive and offers
//     the receive screen in one tap. While a restored wallet's coins are
//     still being found it says they will appear as they are found, not
//     that there are none.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../providers/db/main_db_provider.dart';
import '../../providers/global/locale_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/assets.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/beam/assets/beam_asset_holdings.dart';
import '../../wallets/beam/assets/beam_asset_providers.dart';
import '../../wallets/beam/assets/beam_asset_registry.dart';
import '../../wallets/beam/assets/beam_asset_text.dart';
import '../../wallets/beam/assets/beam_hidden_assets.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../widgets/background.dart';
import '../../widgets/beam/stickers/beam_sticker.dart';
import '../../widgets/beam/wallet_home/beam_wallet_home.dart'
    show BeamCoinScan, pBeamCoinScan;
import '../../widgets/conditional_parent.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_container.dart';
import 'beam_asset_navigation.dart';
import 'beam_asset_receive_view.dart';
import 'sub_widgets/beam_asset_select_item.dart';
import 'sub_widgets/beam_asset_layout.dart';

/// The Confidential Assets a BEAM wallet holds, as Campfire's "My tokens"
/// screen. A full page on a phone; embedded as is on desktop.
class BeamAssetsView extends ConsumerStatefulWidget {
  const BeamAssetsView({super.key, required this.walletId});

  static const String routeName = "/beamAssets";

  final String walletId;

  @override
  ConsumerState<BeamAssetsView> createState() => _BeamAssetsViewState();
}

class _BeamAssetsViewState extends ConsumerState<BeamAssetsView> {
  bool get isDesktop => BeamAssetLayout.isDesktop(context);
  bool _managing = false;

  @override
  void initState() {
    super.initState();
    // Names and LP tokens come from the core and the DEX once the wallet is
    // live; the list shows cached rows until then (R11).
    final wallet = ref.read(pBeamWallet(widget.walletId));
    if (wallet != null) {
      unawaited(
        wallet.whenLive.then((_) async {
          if (!mounted) return;
          ref.refresh(pBeamAssetMarket(widget.walletId));
          await _syncNames();
        }),
      );
    }
  }

  Future<void> _syncNames() async {
    final wallet = ref.read(pBeamWallet(widget.walletId));
    if (wallet == null || !mounted) return;
    try {
      final market = await ref.read(pBeamAssetMarket(widget.walletId).future);
      if (!mounted) return;
      await BeamAssetRegistry.sync(
        isar: ref.read(mainDBProvider).isar,
        heldIds: ref.read(pBeamAssetTotals(widget.walletId)).keys,
        api: wallet.coreApi,
        pools: market?.pools,
      );
    } catch (_) {
      // The cached rows stay; the next visit tries again.
    }
  }

  Future<void> _toggleHidden(BeamAssetHolding h) async {
    await BeamHiddenAssets.setHidden(
      info: ref.read(pWalletInfo(widget.walletId)),
      isar: ref.read(mainDBProvider).isar,
      assetId: h.assetId,
      hidden: !h.hidden,
    );
  }

  void _openReceive() => unawaited(
    showBeamAssetReceive(context: context, walletId: widget.walletId),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final holdings = ref.watch(pBeamAssetHoldings(widget.walletId));
    final market = ref.watch(pBeamAssetMarket(widget.walletId)).asData?.value;
    final visible = _managing
        ? holdings
        : holdings.where((h) => !h.hidden).toList();
    final hiddenCount = holdings.where((h) => h.hidden).length;

    final manageButton = AppBarIconButton(
      key: const Key('beamAssetsManageButton'),
      size: 36,
      shadows: const [],
      color: colors.background,
      icon: _managing
          ? SvgPicture.asset(
              Assets.svg.check,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                colors.topNavIconPrimary,
                BlendMode.srcIn,
              ),
            )
          : SvgPicture.asset(
              Assets.svg.eyeSlash,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                colors.topNavIconPrimary,
                BlendMode.srcIn,
              ),
            ),
      onPressed: () => setState(() => _managing = !_managing),
    );

    Widget body;
    if (holdings.isEmpty) {
      body = _Empty(
        scan: ref.watch(pBeamCoinScan(widget.walletId)),
        onReceive: _openReceive,
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_managing)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
              child: Text(
                'Tap an asset to hide it from this list or show it again. '
                'Hidden assets stay in your wallet.',
                style: STextStyles.itemSubtitle(context),
              ),
            )
          else
            _Total(
              portfolio: BeamAssetHoldings.portfolio(
                holdings,
                marketKnown: market != null,
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length + 1,
              itemBuilder: (context, i) {
                if (i == visible.length) {
                  if (_managing || hiddenCount == 0) {
                    return const SizedBox(height: 16);
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: CustomTextButton(
                        key: const Key('beamAssetsShowHidden'),
                        text: hiddenCount == 1
                            ? 'Show 1 hidden asset'
                            : 'Show $hiddenCount hidden assets',
                        onTap: () => setState(() => _managing = true),
                      ),
                    ),
                  );
                }
                final h = visible[i];
                return Padding(
                  key: Key(h.contract.address),
                  padding: isDesktop
                      ? const EdgeInsets.symmetric(vertical: 5)
                      : const EdgeInsets.all(4),
                  child: BeamAssetSelectItem(
                    holding: h,
                    marketKnown: market != null,
                    managing: _managing,
                    onPressed: () => _managing
                        ? unawaited(_toggleHidden(h))
                        : unawaited(
                            openBeamAsset(
                              context: context,
                              ref: ref,
                              walletId: widget.walletId,
                              asset: h.contract,
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    return ConditionalParent(
      condition: !isDesktop,
      builder: (child) => Background(
        child: Scaffold(
          backgroundColor: colors.background,
          appBar: AppBar(
            backgroundColor: colors.background,
            leading: const AppBarBackButton(),
            title: Text(
              _managing ? 'Show or hide assets' : 'My assets',
              style: STextStyles.navBarTitle(context),
            ),
            actions: [
              if (holdings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    top: 10,
                    bottom: 10,
                    right: 20,
                  ),
                  child: AspectRatio(aspectRatio: 1, child: manageButton),
                ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(left: 12, top: 12, right: 12),
              child: child,
            ),
          ),
        ),
      ),
      child: ConditionalParent(
        condition: isDesktop,
        builder: (child) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (holdings.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: CustomTextButton(
                  key: const Key('beamAssetsManageButton'),
                  text: _managing ? 'Done' : 'Show or hide assets',
                  onTap: () => setState(() => _managing = !_managing),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
        child: body,
      ),
    );
  }
}

class _Total extends ConsumerWidget {
  const _Total({required this.portfolio});

  final BeamAssetPortfolio portfolio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    final String value;
    final String note;
    if (!portfolio.marketKnown) {
      value = '—';
      note = 'Prices load once the wallet is connected.';
    } else {
      value = BeamAssetText.beamEstimate(portfolio.valueGroth, locale: locale);
      note = portfolio.unpriced == 0
          ? 'Estimated from DEX prices.'
          : 'Estimated from DEX prices. ${portfolio.unpriced} '
                '${portfolio.unpriced == 1 ? 'asset has' : 'assets have'} no '
                'price and ${portfolio.unpriced == 1 ? 'is' : 'are'} not '
                'counted.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: RoundedContainer(
        color: colors.tokenSummaryBG,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your assets are worth',
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.tokenSummaryTextSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              key: const Key('beamAssetsTotal'),
              style: STextStyles.pageTitleH2(context)
                  .copyWith(color: colors.tokenSummaryTextPrimary),
            ),
            const SizedBox(height: 4),
            Text(
              note,
              style: STextStyles.w500_12(context)
                  .copyWith(color: colors.tokenSummaryTextSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.scan, required this.onReceive});

  /// A restore scan still looking for coins, or null.
  final BeamCoinScan? scan;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BeamStickerImage(
                BeamMoments.emptyAssets,
                key: Key('beamAssetsEmptySticker'),
                size: 96,
              ),
              const SizedBox(height: 16),
              Text(
                scan == null
                    ? 'No assets yet'
                    : 'Still looking for your assets',
                style: STextStyles.pageTitleH2(context),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                scan == null
                    ? 'Assets like FOMO or BeamX arrive at your BEAM address. '
                          'Share it to receive them; they appear here.'
                    : 'Your assets appear here as your coins are found. You '
                          'can receive meanwhile.',
                key: const Key('beamAssetsEmptyDetail'),
                style: STextStyles.itemSubtitle(context),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                key: const Key('beamAssetsReceive'),
                label: 'Receive assets',
                width: BeamAssetLayout.isDesktop(context) ? 240 : null,
                onPressed: onReceive,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
