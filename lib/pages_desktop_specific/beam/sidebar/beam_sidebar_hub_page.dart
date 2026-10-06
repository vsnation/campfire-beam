/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Airdrops and Tokens in the desktop side menu: three tasks each, one card
// per task, the most common first.
//
// Spec (USER_PSYCHOLOGY §6):
//   1. Job: pick what to do with airdrops (claim a code / see mine / create
//      codes) or tokens (create one / mine / burn).
//   2. Primary CTA: the first card ("Claim a code", "Create a token"),
//      marked by its filled icon; the other two are quieter.
//   3. Clicks from app open: Airdrops (1) → Claim a code (2).
//
// Exit-intent (§1.7): jargon ("batch", "voucher", "minter") — the cards say
// what the user gets; not knowing which card is theirs — one plain line
// each; a dead end after a task — every task page's back arrow and "Done"
// come back here.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../pages/beam/airdrop/beam_airdrop_batches_view.dart';
import '../../../pages/beam/airdrop/beam_claim_voucher_view.dart';
import '../../../pages/beam/airdrop/beam_create_airdrop_view.dart';
import '../../../pages/beam/minter/beam_burn_view.dart';
import '../../../pages/beam/minter/beam_mint_token_view.dart';
import '../../../pages/beam/minter/beam_my_tokens_view.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../my_stack_view/wallet_view/sub_widgets/beam_desktop_wallet_summary.dart';
import 'beam_sidebar_scaffold.dart';

/// One task card of a hub.
@immutable
class BeamSidebarTask {
  const BeamSidebarTask({
    required this.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.routeName,
  });

  /// The same keys as the wallet screen's menu rows (click paths).
  final Key key;
  final String icon;
  final String title;
  final String detail;

  /// Opened with the wallet as its argument (RouteGenerator).
  final String routeName;

  /// The tasks of [destination] (Airdrops or Tokens), most used first. The
  /// words are the wallet screen's (`openBeamFeature`).
  static List<BeamSidebarTask> of(BeamSidebarDestination destination) =>
      switch (destination) {
        BeamSidebarDestination.airdrops => [
          BeamSidebarTask(
            key: const Key('beamAirdropClaim'),
            icon: Assets.svg.arrowDownLeft,
            title: 'Claim a code',
            detail: 'Someone gave you a code? Get what it holds',
            routeName: BeamClaimVoucherView.routeName,
          ),
          BeamSidebarTask(
            key: const Key('beamAirdropMine'),
            icon: Assets.svg.list,
            title: 'My airdrops',
            detail: 'See which of your codes were claimed',
            routeName: BeamAirdropBatchesView.routeName,
          ),
          BeamSidebarTask(
            key: const Key('beamAirdropCreate'),
            icon: Assets.svg.circlePlus,
            title: 'Create codes',
            detail: 'Put BEAM or a token into codes to give away',
            routeName: BeamCreateAirdropView.routeName,
          ),
        ],
        BeamSidebarDestination.tokens => [
          BeamSidebarTask(
            key: const Key('beamTokensCreate'),
            icon: Assets.svg.circlePlus,
            title: 'Create a token',
            detail: 'Your own asset on BEAM, named by you',
            routeName: BeamMintTokenView.routeName,
          ),
          BeamSidebarTask(
            key: const Key('beamTokensMine'),
            icon: Assets.svg.tokens,
            title: 'My tokens',
            detail: 'Tokens you created: see them, mint more',
            routeName: BeamMyTokensView.routeName,
          ),
          BeamSidebarTask(
            key: const Key('beamTokensBurn'),
            icon: Assets.svg.trash,
            title: 'Burn tokens',
            detail: 'Destroy tokens you hold, for good',
            routeName: BeamBurnView.routeName,
          ),
        ],
        _ => const [],
      };
}

class BeamSidebarHubPage extends StatelessWidget {
  const BeamSidebarHubPage({
    super.key,
    required this.destination,
    required this.wallet,
  });

  final BeamSidebarDestination destination;
  final BeamWallet wallet;

  @override
  Widget build(BuildContext context) {
    final tasks = BeamSidebarTask.of(destination);
    return BeamSidebarScaffold(
      title: destination.label,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          BeamDesktopSyncBanner(walletId: wallet.walletId),
          Text(
            destination.description,
            style: STextStyles.desktopTextExtraExtraSmall(context),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                for (var i = 0; i < tasks.length; i++)
                  _TaskCard(
                    task: tasks[i],
                    primary: i == 0,
                    onPressed: () => unawaited(
                      Navigator.of(context)
                          .pushNamed(tasks[i].routeName, arguments: wallet),
                    ),
                  ),
              ];
              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final c in cards) ...[c, const SizedBox(height: 12)],
                  ],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 16),
                      Expanded(child: cards[i]),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.primary,
    required this.onPressed,
  });

  final BeamSidebarTask task;
  final bool primary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Semantics(
      button: true,
      label: '${task.title}. ${task.detail}',
      excludeSemantics: true,
      child: RoundedWhiteContainer(
        key: task.key,
        padding: const EdgeInsets.all(24),
        hoverColor: colors.textFieldDefaultBG,
        onPressed: onPressed,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RoundedContainer(
              padding: EdgeInsets.zero,
              width: 46,
              height: 46,
              radiusMultiplier: 46,
              color: primary
                  ? colors.buttonBackPrimary
                  : colors.settingsIconBack,
              child: Center(
                child: SvgPicture.asset(
                  task.icon,
                  width: 22,
                  height: 22,
                  colorFilter: ColorFilter.mode(
                    primary
                        ? colors.buttonTextPrimary
                        : colors.settingsIconIcon,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    style: STextStyles.desktopTextMedium(context),
                  ),
                ),
                SvgPicture.asset(
                  Assets.svg.chevronRight,
                  width: 8,
                  height: 14,
                  colorFilter: ColorFilter.mode(
                    colors.textSubtitle1,
                    BlendMode.srcIn,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              task.detail,
              style: STextStyles.desktopTextExtraExtraSmall(context),
            ),
          ],
        ),
      ),
    );
  }
}
