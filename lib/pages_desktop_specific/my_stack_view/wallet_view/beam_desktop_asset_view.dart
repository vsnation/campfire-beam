/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — one asset on desktop (Campfire's
// DesktopTokenView for BEAM):
//   Job:  this asset's balance and value, its history, and moving it — all
//         on one screen, as Campfire's desktop token page.
//   CTA:  "Review payment" in the Send tab (Receive is the other tab).
//   Clicks: wallet → asset: 1 from the wallet's asset list.
//
// Exit-intent: see lib/pages/token_view/beam_asset_view.dart; the
// desktop page says the same things in the same places.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../pages/token_view/beam_asset_receive_view.dart';
import '../../../pages/token_view/sub_widgets/beam_asset_icon.dart';
import '../../../pages/token_view/sub_widgets/beam_asset_send_form.dart';
import '../../../pages/token_view/sub_widgets/beam_asset_summary.dart';
import '../../../pages/token_view/sub_widgets/beam_asset_transactions_list.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart';
import '../../../wallets/beam/assets/beam_asset_text.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../widgets/coin_ticker_tag.dart';
import '../../../widgets/custom_tab_view.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_white_container.dart';

class BeamDesktopAssetView extends ConsumerWidget {
  const BeamDesktopAssetView({super.key, required this.walletId});

  static const String routeName = "/beamDesktopAsset";
  static const double sendReceiveColumnWidth = 460;

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final assetWallet = ref.watch(pCurrentBeamAssetWallet);
    if (assetWallet == null) return const SizedBox.shrink();
    final asset = assetWallet.asset;
    final tag = asset.isPoolShare
        ? 'POOL SHARE'
        : asset.verified
        ? null
        : 'UNVERIFIED ${asset.idLabel}';

    return DesktopScaffold(
      appBar: DesktopAppBar(
        background: colors.popupBG,
        leading: Expanded(
          flex: 3,
          child: Row(
            children: [
              const SizedBox(width: 32),
              SecondaryButton(
                padding: const EdgeInsets.only(left: 12, right: 18),
                buttonHeight: ButtonHeight.s,
                label: ref.watch(pWalletName(walletId)),
                icon: SvgPicture.asset(
                  Assets.svg.arrowLeft,
                  width: 18,
                  height: 18,
                  colorFilter: ColorFilter.mode(
                    colors.topNavIconPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 15),
            ],
          ),
        ),
        center: Expanded(
          flex: 4,
          child: Row(
            children: [
              BeamAssetIcon(asset: asset, size: 32),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  asset.name,
                  style: STextStyles.desktopH3(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tag != null) ...[
                const SizedBox(width: 12),
                CoinTickerTag(ticker: tag),
              ],
            ],
          ),
        ),
        useSpacers: false,
        isCompactHeight: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            RoundedWhiteContainer(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  BeamAssetIcon(asset: asset, size: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _DesktopSummary(walletId: walletId, asset: asset),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                SizedBox(
                  width: sendReceiveColumnWidth,
                  child: Text(
                    "My wallet",
                    style: STextStyles.desktopTextExtraSmall(context)
                        .copyWith(color: colors.textFieldActiveSearchIconLeft),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    "Recent transactions",
                    style: STextStyles.desktopTextExtraSmall(context)
                        .copyWith(color: colors.textFieldActiveSearchIconLeft),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: sendReceiveColumnWidth,
                    child: ListView(
                      primary: false,
                      children: [
                        RoundedWhiteContainer(
                          padding: EdgeInsets.zero,
                          child: CustomTabView(
                            titles: const ["Send", "Receive"],
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(20),
                                child: BeamAssetSendForm(
                                  walletId: walletId,
                                  assetWallet: assetWallet,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(20),
                                child: BeamAssetReceivePanel(
                                  walletId: walletId,
                                  asset: asset,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: BeamAssetTransactionsList(
                      walletId: walletId,
                      assetWallet: assetWallet,
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

class _DesktopSummary extends ConsumerWidget {
  const _DesktopSummary({required this.walletId, required this.asset});

  final String walletId;
  final BeamAssetContract asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    final maxDecimals = ref.watch(
      pMaxDecimals(Beam(CryptoCurrencyNetwork.main)),
    );
    final balance = ref.watch(
      pBeamAssetBalance((walletId: walletId, assetId: asset.assetId)),
    );
    final value = BeamAssetValue.of(ref, walletId: walletId, asset: asset);
    final pending = balance.pendingSpendable.raw;
    final pendingText = BeamAssetText.amount(
      balance.pendingSpendable,
      asset,
      locale: locale,
      maxDecimals: maxDecimals,
    );
    final note =
        BeamAssetText.impersonation(asset) ??
        BeamAssetText.poolLine(asset) ??
        (asset.verified
            ? null
            : 'Unverified asset ${asset.idLabel}. Anyone can create an asset '
                  'with any name; check the number with the sender.');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          BeamAssetText.amount(
            balance.total,
            asset,
            locale: locale,
            maxDecimals: maxDecimals,
          ),
          key: const Key('beamAssetBalance'),
          style: STextStyles.desktopH3(context),
        ),
        const SizedBox(height: 4),
        Text(
          [
            value.fiat == null ? value.beam : '${value.beam} · ${value.fiat}',
            if (pending > BigInt.zero) '$pendingText on the way',
          ].join('   '),
          key: const Key('beamAssetValue'),
          style: STextStyles.desktopTextExtraSmall(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        if (note != null) ...[
          const SizedBox(height: 4),
          Text(
            note,
            style: STextStyles.desktopTextExtraExtraSmall(context).copyWith(
              color: asset.impersonates != null
                  ? colors.textError
                  : colors.textSubtitle1,
            ),
          ),
        ],
      ],
    );
  }
}
