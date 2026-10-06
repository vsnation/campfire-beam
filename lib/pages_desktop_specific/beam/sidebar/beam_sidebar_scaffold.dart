/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The frame of every BEAM page of the desktop side menu, in the look of
// Campfire's own menu pages (Address Book, Notifications): the title in
// Campfire's desktop H3 24 px from the left, and on the right the wallet
// the page acts on (a menu to switch when there are several). Plus the two
// states a page can be in before it has a wallet: none at all, or several
// and none chosen.
//
// Specs (USER_PSYCHOLOGY §6):
//   No wallet — job: get a BEAM wallet; CTA: "Create a BEAM wallet";
//     clicks from app open: the item (1) → the button (2).
//   Several, none chosen — job: say which wallet; CTA: the wallet's card;
//     clicks: the item (1) → the wallet (2), remembered after that.
//
// Exit-intent (USER_PSYCHOLOGY §1.7) answered here:
// * "Which wallet is this swapping from?" — the wallet's name is always in
//   the header, beside the title.
// * "I have no wallet, now what?" — one button: "Create a BEAM wallet".
// * "Why is it asking me which wallet?" — only with several wallets and
//   none used before; the answer is remembered.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/add_wallet_list_entity/sub_classes/coin_entity.dart';
import '../../../pages/add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import '../../../themes/coin_icon_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/beam/wallet_home/beam_dashboard_assets.dart'
    show BeamDashboardModel;
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';

/// A BEAM page of the side menu: Campfire's desktop header (title left,
/// wallet right) over [body].
class BeamSidebarScaffold extends StatelessWidget {
  const BeamSidebarScaffold({
    super.key,
    required this.title,
    required this.body,
    this.showWallet = true,
  });

  final String title;
  final Widget body;

  /// The wallet chip on the right (off while there is no wallet to show).
  final bool showWallet;

  @override
  Widget build(BuildContext context) => DesktopScaffold(
    appBar: DesktopAppBar(
      isCompactHeight: true,
      useSpacers: false,
      leading: Expanded(
        child: Row(
          children: [
            const SizedBox(width: 24),
            Text(
              title,
              key: const Key('beamSidebarTitle'),
              style: STextStyles.desktopH3(context),
            ),
            const Spacer(),
            if (showWallet) const BeamSidebarWalletChip(),
            const SizedBox(width: 24),
          ],
        ),
      ),
    ),
    body: body,
  );
}

/// A page opened from a side-menu page (the full asset list): Campfire's
/// desktop header with the back arrow, as the wallet screen has it.
class BeamSidebarSubPage extends StatelessWidget {
  const BeamSidebarSubPage({
    super.key,
    required this.title,
    required this.body,
  });

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DesktopScaffold(
      appBar: DesktopAppBar(
        background: colors.popupBG,
        isCompactHeight: true,
        useSpacers: false,
        leading: Expanded(
          child: Row(
            children: [
              const SizedBox(width: 32),
              AppBarIconButton(
                key: const Key('beamSidebarBack'),
                size: 32,
                color: colors.textFieldDefaultBG,
                shadows: const [],
                semanticsLabel: 'Back',
                icon: SvgPicture.asset(
                  Assets.svg.arrowLeft,
                  width: 18,
                  height: 18,
                  colorFilter: ColorFilter.mode(
                    colors.topNavIconPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 12),
              Text(title, style: STextStyles.desktopH3(context)),
              const Spacer(),
              const BeamSidebarWalletChip(),
              const SizedBox(width: 24),
            ],
          ),
        ),
      ),
      body: body,
    );
  }
}

/// Shows a BEAM page built for the wallet screen inside a side-menu page,
/// under the side menu's header instead of its own: the page's own header
/// (Campfire's compact desktop app bar, with a back arrow that has nowhere
/// to go here) is laid out above this box and clipped away, so it is
/// neither seen nor clickable, and the page's body gets the whole box.
class BeamWithoutOwnHeader extends StatelessWidget {
  const BeamWithoutOwnHeader({super.key, required this.child});

  /// Its first child must be Campfire's compact `DesktopAppBar`.
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight + kDesktopAppBarHeightCompact;
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.bottomCenter,
          minWidth: constraints.maxWidth,
          maxWidth: constraints.maxWidth,
          minHeight: height,
          maxHeight: height,
          child: child,
        ),
      );
    },
  );
}

// ------------------------------------------------------------- wallet chip

/// The wallet the page acts on, top right: its coin icon and name; with
/// several BEAM wallets, a menu to switch (remembered for next time).
class BeamSidebarWalletChip extends ConsumerWidget {
  const BeamSidebarWalletChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctx = ref.watch(pBeamSidebarWallet);
    final wallet = ctx.wallet;
    if (wallet == null) return const SizedBox.shrink();
    final colors = Theme.of(context).extension<StackColors>()!;
    final chip = Container(
      key: const Key('beamSidebarWalletChip'),
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: colors.popupBG,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: colors.textFieldDefaultBG),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CoinIcon(wallet: wallet, size: 20),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              wallet.info.name,
              key: const Key('beamSidebarWalletName'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: STextStyles.desktopTextExtraSmall(context)
                  .copyWith(color: colors.textDark),
            ),
          ),
          if (ctx.canSwitch) ...[
            const SizedBox(width: 8),
            SvgPicture.asset(
              Assets.svg.chevronDown,
              width: 10,
              height: 6,
              colorFilter: ColorFilter.mode(
                colors.textSubtitle1,
                BlendMode.srcIn,
              ),
            ),
          ],
        ],
      ),
    );
    if (!ctx.canSwitch) {
      return Semantics(label: 'Wallet: ${wallet.info.name}', child: chip);
    }
    return PopupMenuButton<String>(
      key: const Key('beamSidebarWalletSwitch'),
      tooltip: 'Switch wallet',
      offset: const Offset(0, 46),
      color: colors.popupBG,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: (id) =>
          ref.read(pBeamSidebarWalletChoice.notifier).choose(id),
      itemBuilder: (_) => [
        for (final w in ctx.wallets)
          PopupMenuItem<String>(
            key: Key('beamSidebarWalletOption_${w.walletId}'),
            value: w.walletId,
            child: Row(
              children: [
                _CoinIcon(wallet: w, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    w.info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.desktopTextExtraSmall(context)
                        .copyWith(color: colors.textDark),
                  ),
                ),
                if (identical(w, wallet))
                  SvgPicture.asset(
                    Assets.svg.check,
                    width: 14,
                    height: 14,
                    colorFilter: ColorFilter.mode(
                      colors.accentColorGreen,
                      BlendMode.srcIn,
                    ),
                  ),
              ],
            ),
          ),
      ],
      child: chip,
    );
  }
}

class _CoinIcon extends ConsumerWidget {
  const _CoinIcon({required this.wallet, required this.size});

  final BeamWallet wallet;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SvgPicture.file(
    File(ref.watch(coinIconProvider(wallet.info.coin))),
    width: size,
    height: size,
  );
}

// ------------------------------------------------------------ picker state

/// Several BEAM wallets and none chosen yet: which one? Compact, at the top
/// of the page; one click picks it and the page opens on it.
class BeamSidebarWalletPicker extends ConsumerWidget {
  const BeamSidebarWalletPicker({super.key, required this.destination});

  final BeamSidebarDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallets = ref.watch(pBeamSidebarWallet).wallets;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: RoundedWhiteContainer(
            key: const Key('beamSidebarWalletPicker'),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Which wallet?',
                  style: STextStyles.desktopTextMedium(context),
                ),
                const SizedBox(height: 6),
                Text(
                  '${destination.label} works with one BEAM wallet at a '
                  'time. Pick one; you can switch any time at the top right.',
                  style: STextStyles.desktopTextExtraExtraSmall(context),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (final w in wallets) _WalletOption(wallet: w)],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WalletOption extends ConsumerWidget {
  const _WalletOption({required this.wallet});

  final BeamWallet wallet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final balance = ref.watch(pWalletBalance(wallet.walletId)).spendable;
    // Rounded to what a person reads; the wallet shows every digit.
    final amount = '${BeamDashboardModel.shortAmount(balance.raw)} BEAM';
    return SizedBox(
      width: 220,
      child: RoundedContainer(
        key: Key('beamSidebarPick_${wallet.walletId}'),
        color: colors.popupBG,
        borderColor: colors.textFieldDefaultBG,
        padding: const EdgeInsets.all(14),
        onPressed: () =>
            ref.read(pBeamSidebarWalletChoice.notifier).choose(wallet.walletId),
        child: Row(
          children: [
            _CoinIcon(wallet: wallet, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    wallet.info.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.w600_14(context)
                        .copyWith(color: colors.textDark),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    amount,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
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

// ---------------------------------------------------------- no-wallet state

/// No BEAM wallet at all. One way forward: create one.
class BeamSidebarNoWallet extends StatelessWidget {
  const BeamSidebarNoWallet({super.key, required this.destination});

  final BeamSidebarDestination destination;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          key: const Key('beamSidebarNoWallet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const BeamStickerImage(BeamMoments.emptyWallets, size: 140),
            const SizedBox(height: 24),
            Text(
              'No BEAM wallet yet',
              style: STextStyles.desktopH3(context),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              '${destination.label} works from a BEAM wallet. Creating one '
              'takes about a minute; it lives on this computer and only you '
              'can open it.',
              style: STextStyles.desktopTextExtraSmall(context).copyWith(
                color: Theme.of(context)
                    .extension<StackColors>()!
                    .textSubtitle1,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            PrimaryButton(
              key: const Key('beamSidebarCreateWallet'),
              label: 'Create a BEAM wallet',
              width: 260,
              onPressed: () =>
                  Navigator.of(context, rootNavigator: true).pushNamed(
                    CreateOrRestoreWalletView.routeName,
                    arguments: CoinEntity(BeamSidebar.coin),
                  ),
            ),
          ],
        ),
      ),
    ),
  );
}
