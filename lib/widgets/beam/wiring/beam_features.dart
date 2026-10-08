/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Every BEAM feature's entry point, in one place: what it is called, its
// icon, and how it opens on a phone and on desktop. Campfire's own menus
// (the phone wallet's bottom bar and its More sheet, the desktop wallet's
// feature row and its More dialog) only list these.
//
// Click budget (USER_PSYCHOLOGY §1.2), from opening the wallet:
//   phone   Send, Receive, Swap, Assets: 1 tap (the bar).
//           Names, dApps, Node & sync, Split coins: 2 (More → it).
//           Airdrops and Tokens: 3 (More → it → which task).
//   desktop Send, Receive: 0 (the wallet's tabs); Assets: 0 (beside them).
//           Swap, Names, dApps, Node & sync, Split coins: 1 (the feature
//           row, or 2 when the window is narrow and it sits under More).
//           Airdrops and Tokens: 2 (it → which task).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../pages/beam/airdrop/beam_airdrop_batches_view.dart';
import '../../../pages/beam/airdrop/beam_claim_voucher_view.dart';
import '../../../pages/beam/airdrop/beam_create_airdrop_view.dart';
import '../../../pages/beam/dapps/dapp_store_view.dart';
import '../../../pages/beam/minter/beam_burn_view.dart';
import '../../../pages/beam/minter/beam_mint_token_view.dart';
import '../../../pages/beam/minter/beam_my_tokens_view.dart';
import '../../../pages/beam/names/beam_names_home_view.dart';
import '../../../pages/beam/split/beam_split_view.dart';
import '../../../pages/token_view/my_tokens_view.dart';
import '../../../pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_wallet_features.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../wallet_navigation_bar/components/icons/exchange_nav_icon.dart';
import '../../wallet_navigation_bar/components/wallet_navigation_bar_item.dart';
import '../airdrop/beam_layout.dart';
import '../dex/dex_deps.dart';
import '../receive/beam_address_list.dart';
import '../split/beam_split_backend.dart';
import 'beam_feature_menu.dart';
import 'beam_wallet_listenables.dart';

/// The BEAM features a BEAM wallet offers beyond Send and Receive.
enum BeamFeature {
  swap('Swap', 'Swap one asset for another'),
  assets('Assets', 'Every asset this wallet holds'),
  names('Names', 'Your BEAM names, and getting one'),
  dapps('dApps', 'Apps that run on BEAM'),
  airdrops('Airdrops', 'Claim a code, or give some away'),
  tokens('Tokens', 'Create your own token on BEAM'),
  node('Node & sync', 'Which node you use, and how up to date'),
  split('Split coins', 'Send several payments at once');

  const BeamFeature(this.label, this.description);

  final String label;
  final String description;

  /// Campfire's own icon for it (`Assets.svg`).
  String get icon => switch (this) {
    BeamFeature.swap => Assets.svg.swap,
    BeamFeature.assets => Assets.svg.tokens,
    BeamFeature.names => Assets.svg.robotHead,
    BeamFeature.dapps => Assets.svg.boxAuto,
    BeamFeature.airdrops => Assets.svg.envelope,
    BeamFeature.tokens => Assets.svg.circlePlus,
    BeamFeature.node => Assets.svg.node,
    BeamFeature.split => Assets.svg.coinControl.gamePad,
  };

  /// On the phone wallet's bottom bar, after Receive and Send.
  static const phoneBar = [swap, assets];

  /// In the phone wallet's More sheet, most used first; Split coins last,
  /// so every older row (and click path) keeps its place.
  static const phoneMore = [names, dapps, airdrops, tokens, node, split];

  /// The desktop wallet's feature row, most used first (what does not fit
  /// moves under Campfire's "More"). Assets sit beside Send / Receive.
  /// Split coins last, so the older buttons keep their places.
  static const desktopRow = [swap, names, dapps, airdrops, tokens, node, split];
}

/// Route names of BEAM pages that have none of their own.
abstract final class BeamFeatureRoutes {
  /// The DEX swap form (phone).
  static const dex = '/beamDexSwap';
}

/// Opens [feature] of [wallet] from [context] (the wallet screen), the way
/// Campfire opens its own features: a page on a phone; on desktop a page in
/// the wallet area, or a dialog for the DEX and the node panel.
Future<void> openBeamFeature(
  BuildContext context,
  BeamWallet wallet,
  BeamFeature feature,
) async {
  final wiring = BeamWalletWiring.of(wallet)..attach(context);
  final desktop = BeamLayoutScope.isDesktop(context);
  final nav = Navigator.of(context);
  switch (feature) {
    case BeamFeature.swap:
      if (desktop) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => BeamDesktopDexDialog(deps: wiring.dex),
        );
      } else {
        await nav.pushNamed(BeamFeatureRoutes.dex, arguments: wallet);
      }
    case BeamFeature.assets:
      await nav.pushNamed(MyTokensView.routeName, arguments: wallet.walletId);
    case BeamFeature.names:
      await nav.pushNamed(BeamNamesHomeView.routeName, arguments: wallet);
    case BeamFeature.dapps:
      await nav.pushNamed(DappStoreView.routeName, arguments: wallet);
    case BeamFeature.airdrops:
      await showBeamFeatureMenu(
        context,
        title: 'Airdrops',
        options: [
          _route(
            'beamAirdropClaim',
            Assets.svg.arrowDownLeft,
            'Claim a code',
            'Someone gave you a code? Get what it holds',
            BeamClaimVoucherView.routeName,
            wallet,
          ),
          _route(
            'beamAirdropMine',
            Assets.svg.list,
            'My airdrops',
            'See which of your codes were claimed',
            BeamAirdropBatchesView.routeName,
            wallet,
          ),
          _route(
            'beamAirdropCreate',
            Assets.svg.circlePlus,
            'Create codes',
            'Put BEAM or a token into codes to give away',
            BeamCreateAirdropView.routeName,
            wallet,
          ),
        ],
      );
    case BeamFeature.tokens:
      await showBeamFeatureMenu(
        context,
        title: 'Tokens',
        options: [
          _route(
            'beamTokensCreate',
            Assets.svg.circlePlus,
            'Create a token',
            'Your own asset on BEAM, named by you',
            BeamMintTokenView.routeName,
            wallet,
          ),
          _route(
            'beamTokensMine',
            Assets.svg.tokens,
            'My tokens',
            'Tokens you created: see them, mint more',
            BeamMyTokensView.routeName,
            wallet,
          ),
          _route(
            'beamTokensBurn',
            Assets.svg.trash,
            'Burn tokens',
            'Destroy tokens you hold, for good',
            BeamBurnView.routeName,
            wallet,
          ),
        ],
      );
    case BeamFeature.node:
      await showBeamNodePanel(context, wallet.walletId);
    case BeamFeature.split:
      await openBeamSplit(context, wallet);
  }
}

/// Split coins for [wallet]'s [assetId] (BEAM unless said), as a page on
/// the navigator of [context]: from inside a dialog (the desktop DEX) it
/// opens above the dialog, never hidden under it.
Future<void> openBeamSplit(
  BuildContext context,
  BeamWallet wallet, {
  int assetId = 0,
}) {
  // "Receive BEAM" on the split screen opens from here.
  BeamWalletWiring.of(wallet).attach(context);
  return Navigator.of(context).pushNamed(
    BeamSplitView.routeName,
    arguments: BeamSplitArgs(wallet, assetId: assetId),
  );
}

BeamFeatureMenuOption _route(
  String key,
  String icon,
  String title,
  String detail,
  String routeName,
  BeamWallet wallet,
) => BeamFeatureMenuOption(
  key: Key(key),
  icon: icon,
  title: title,
  detail: detail,
  onSelected: (context) =>
      unawaited(Navigator.of(context).pushNamed(routeName, arguments: wallet)),
);

// ------------------------------------------------------------------ phone

/// The BEAM buttons of the phone wallet's bottom bar ([BeamFeature.phoneBar]),
/// placed after Campfire's Receive and Send.
List<WalletNavigationBarItemData> beamWalletNavItems(
  BuildContext context,
  BeamWallet wallet,
) => [
  for (final f in BeamFeature.phoneBar)
    WalletNavigationBarItemData(
      label: f.label,
      icon: f == BeamFeature.swap
          ? const ExchangeNavIcon()
          : BeamNavIcon(asset: f.icon),
      onTap: () => unawaited(openBeamFeature(context, wallet, f)),
    ),
];

/// The BEAM rows of the phone wallet's More sheet ([BeamFeature.phoneMore]).
List<WalletNavigationBarItemData> beamWalletMoreItems(
  BuildContext context,
  BeamWallet wallet,
) => [
  for (final f in BeamFeature.phoneMore)
    WalletNavigationBarItemData(
      label: f.label,
      icon: BeamNavIcon(asset: f.icon),
      onTap: () => unawaited(openBeamFeature(context, wallet, f)),
    ),
];

/// A bottom bar icon in Campfire's size and colour.
class BeamNavIcon extends StatelessWidget {
  const BeamNavIcon({super.key, required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    asset,
    width: 20,
    height: 20,
    colorFilter: ColorFilter.mode(
      Theme.of(context).extension<StackColors>()!.bottomNavIconIcon,
      BlendMode.srcIn,
    ),
  );
}

// ---------------------------------------------------------------- desktop

/// Campfire's desktop `WalletFeature` for each entry of
/// [BeamFeature.desktopRow] (same label and description).
const Map<BeamFeature, WalletFeature> kBeamWalletFeatures = {
  BeamFeature.swap: WalletFeature.beamSwap,
  BeamFeature.names: WalletFeature.beamNames,
  BeamFeature.dapps: WalletFeature.beamDapps,
  BeamFeature.airdrops: WalletFeature.beamAirdrops,
  BeamFeature.tokens: WalletFeature.beamTokens,
  BeamFeature.node: WalletFeature.beamNode,
  BeamFeature.split: WalletFeature.beamSplit,
};

/// The desktop wallet's feature row for a BEAM wallet, in Campfire's
/// option shape: [BeamFeature.desktopRow], most used first, opened from
/// [context] (the wallet screen).
List<(WalletFeature, String, FutureOr<void> Function())>
beamDesktopWalletFeatures(BuildContext context, BeamWallet wallet) => [
  for (final f in BeamFeature.desktopRow)
    (
      kBeamWalletFeatures[f]!,
      f.icon,
      () => openBeamFeature(context, wallet, f),
    ),
];

/// The desktop DEX (swap form beside the pools) in a large Campfire dialog,
/// with Campfire's close button where the view's own bar leaves room.
class BeamDesktopDexDialog extends StatelessWidget {
  const BeamDesktopDexDialog({super.key, required this.deps});

  final BeamDexDeps deps;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return DesktopDialog(
      key: const Key('beamDesktopDexDialog'),
      maxWidth: size.width - 64 < 1200 ? size.width - 64 : 1200,
      maxHeight: size.height - 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            DesktopBeamDexView(deps: deps),
            const Positioned(
              top: 0,
              right: 0,
              child: DesktopDialogCloseButton(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wallet's own BEAM addresses in a desktop dialog, as the BEAM Receive
/// tab shows them (Campfire's generic list knows nothing of BEAM's address
/// types or expiry).
Future<void> showBeamAddressListDialog(BuildContext context, String walletId) =>
    showDialog<void>(
      context: context,
      builder: (context) => DesktopDialog(
        key: const Key('beamAddressListDialog'),
        maxWidth: 640,
        maxHeight: MediaQuery.sizeOf(context).height - 64 < 760
            ? MediaQuery.sizeOf(context).height - 64
            : 760,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    'Your addresses',
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: BeamAddressList(walletId: walletId, desktop: true),
              ),
            ),
          ],
        ),
      ),
    );
