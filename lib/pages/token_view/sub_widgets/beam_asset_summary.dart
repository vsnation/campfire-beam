/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/price_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart';
import '../../../wallets/beam/assets/beam_asset_text.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../widgets/rounded_container.dart';
import 'token_summary.dart';

/// The value lines of one asset: "≈ 70.033 BEAM", fiat when Campfire knows
/// BEAM's price, or why there is no value.
class BeamAssetValue {
  const BeamAssetValue(this.beam, this.fiat);

  final String beam;
  final String? fiat;

  static BeamAssetValue of(
    WidgetRef ref, {
    required String walletId,
    required BeamAssetContract asset,
  }) {
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    final market = ref.watch(pBeamAssetMarket(walletId)).asData?.value;
    if (market == null) {
      return const BeamAssetValue(BeamAssetText.priceLoading, null);
    }
    final balance = ref.watch(
      pBeamAssetBalance((walletId: walletId, assetId: asset.assetId)),
    );
    final value = market.pricer.valueInGroth(asset.assetId, balance.total.raw);
    if (value == null) return const BeamAssetValue(BeamAssetText.noPrice, null);
    Decimal? price;
    if (ref.watch(prefsChangeNotifierProvider.select((s) => s.externalCalls))) {
      price = ref.watch(
        priceAnd24hChangeNotifierProvider.select(
          (s) => s.getPrice(Beam(CryptoCurrencyNetwork.main))?.value,
        ),
      );
    }
    return BeamAssetValue(
      BeamAssetText.valueEstimate(
        value,
        sale: market.pricer.isSaleValue(asset.assetId),
        locale: locale,
      ),
      price == null
          ? null
          : BeamAssetText.fiatEstimate(
              value,
              price,
              locale: locale,
              currency: ref.watch(
                prefsChangeNotifierProvider.select((s) => s.currency),
              ),
            ),
    );
  }
}

/// Campfire's token summary card for a BEAM asset: balance, its estimated
/// value, what is still arriving, what the asset is, and Receive / Send.
class BeamAssetSummary extends ConsumerWidget {
  const BeamAssetSummary({
    super.key,
    required this.walletId,
    required this.asset,
    required this.onReceive,
    required this.onSend,
  });

  final String walletId;
  final BeamAssetContract asset;
  final VoidCallback onReceive;
  final VoidCallback onSend;

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
    final pending = balance.pendingSpendable;
    final pendingText = BeamAssetText.amount(
      pending,
      asset,
      locale: locale,
      maxDecimals: maxDecimals,
    );
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.tokenSummaryTextSecondary);
    final note =
        BeamAssetText.poolLine(asset) ??
        (asset.verified
            ? null
            : 'Unverified asset ${asset.idLabel}. Anyone can create an asset '
                  'with any name; check the number with the sender.');
    final warning = BeamAssetText.impersonation(asset);

    return RoundedContainer(
      color: colors.tokenSummaryBG,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SvgPicture.asset(
                Assets.svg.walletDesktop,
                width: 12,
                height: 12,
                colorFilter: ColorFilter.mode(
                  colors.tokenSummaryTextSecondary,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  ref.watch(pWalletName(walletId)),
                  style: secondary,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              BeamAssetText.amount(
                balance.total,
                asset,
                locale: locale,
                maxDecimals: maxDecimals,
              ),
              key: const Key('beamAssetBalance'),
              style: STextStyles.pageTitleH1(context)
                  .copyWith(color: colors.tokenSummaryTextPrimary),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value.fiat == null ? value.beam : '${value.beam} · ${value.fiat}',
            key: const Key('beamAssetValue'),
            style: STextStyles.subtitle500(context)
                .copyWith(color: colors.tokenSummaryTextPrimary),
          ),
          if (pending.raw > BigInt.zero) ...[
            const SizedBox(height: 4),
            Text('$pendingText on the way', style: secondary),
          ],
          if (note != null) ...[
            const SizedBox(height: 8),
            Text(note, style: secondary, textAlign: TextAlign.center),
          ],
          if (warning != null) ...[
            const SizedBox(height: 8),
            Text(
              warning,
              textAlign: TextAlign.center,
              style: STextStyles.w600_12(context)
                  .copyWith(color: colors.textError),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TokenOptionsButton(
                onPressed: onReceive,
                subLabel: "Receive",
                iconAssetPathSVG: Assets.svg.arrowDownLeft,
              ),
              const SizedBox(width: 16),
              TokenOptionsButton(
                key: const Key('beamAssetSendButton'),
                onPressed: onSend,
                subLabel: "Send",
                iconAssetPathSVG: Assets.svg.arrowUpRight,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
