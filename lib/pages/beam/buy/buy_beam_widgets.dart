/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pieces the Buy BEAM screens share: a coin from another chain (icon,
// ticker, chain), BEAM's own icon, a buy's steps with a mark for each, and
// a buy as one row of a list.

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_order.dart';
import '../../../widgets/beam/dex/dex_asset_icon.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import 'buy_beam_words.dart';

/// BEAM's own round icon.
class BuyBeamIcon extends StatelessWidget {
  const BuyBeamIcon({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) =>
      DexAssetIcon(asset: BeamAssetCatalog.display(0, null), size: size);
}

/// A round icon with the coin's letters on a colour made from its id: no
/// picture is downloaded, and a copy never borrows a real coin's look.
class BuyCoinIcon extends StatelessWidget {
  const BuyCoinIcon({
    super.key,
    required this.assetId,
    required this.symbol,
    this.size = 24,
  });

  final String assetId;
  final String symbol;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = assetId.codeUnits.fold(7, (h, c) => (h * 31 + c) % 360);
    final clean = symbol.replaceAll(RegExp('[^A-Za-z0-9]'), '');
    final letters = clean.isEmpty
        ? '?'
        : clean
              .substring(0, clean.length >= 3 ? 3 : clean.length)
              .toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: HSLColor.fromAHSL(1, hue.toDouble(), 0.5, 0.42).toColor(),
      ),
      child: Text(
        letters,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * (letters.length > 2 ? 0.3 : 0.38),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Icon, ticker and chain, for the amount field's coin button.
class BuyCoinChip extends StatelessWidget {
  const BuyCoinChip({super.key, required this.asset});

  final BuyBeamAsset asset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BuyCoinIcon(assetId: asset.assetId, symbol: asset.symbol, size: 20),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                asset.symbol,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textDark),
              ),
              Text(
                asset.chainName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: STextStyles.label(context)
                    .copyWith(color: colors.textSubtitle1, fontSize: 10),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- steps

enum BuyStepMark { done, active, waiting, failed }

class BuyStep {
  const BuyStep(this.label, this.mark, [this.note]);

  final String label;
  final BuyStepMark mark;
  final String? note;
}

/// The four steps of a buy, from where it is. Never more than four.
/// [arrived]: the wallet has the BEAM buybeam.my sent (`delivered` alone
/// means it was sent).
List<BuyStep> buyBeamSteps(BuyBeamState? state, {bool arrived = false}) {
  const done = BuyStepMark.done;
  const active = BuyStepMark.active;
  const waiting = BuyStepMark.waiting;
  const failed = BuyStepMark.failed;
  final s = state ?? BuyBeamState.awaitingDeposit;
  final buying = const {
    BuyBeamState.depositDetected,
    BuyBeamState.swapping,
    BuyBeamState.buying,
    BuyBeamState.processing,
    BuyBeamState.inProgress,
    BuyBeamState.attention,
  }.contains(s);
  final bought = s == BuyBeamState.sending || s == BuyBeamState.delivered;
  return [
    switch (s) {
      BuyBeamState.awaitingDeposit => const BuyStep(
        'Waiting for your payment',
        active,
      ),
      BuyBeamState.expired => const BuyStep(
        'No payment arrived in time',
        failed,
      ),
      BuyBeamState.failed => const BuyStep(
        "The payment couldn't be processed",
        failed,
      ),
      _ => BuyStep(
        'Payment received',
        done,
        s == BuyBeamState.depositDetected ? 'being confirmed' : null,
      ),
    },
    BuyStep(
      s == BuyBeamState.refunded
          ? "Your BEAM couldn't be bought"
          : 'Buying your BEAM',
      s == BuyBeamState.refunded
          ? failed
          : bought
          ? done
          : buying
          ? active
          : waiting,
    ),
    BuyStep(
      'Sending BEAM to your wallet',
      s == BuyBeamState.delivered
          ? done
          : s == BuyBeamState.sending
          ? active
          : waiting,
    ),
    if (s == BuyBeamState.delivered && !arrived)
      const BuyStep('Arriving in your wallet', active)
    else
      BuyStep(
        'Your BEAM has arrived',
        s == BuyBeamState.delivered ? done : waiting,
      ),
  ];
}

/// The steps as a list with a mark for each.
class BuyStepList extends StatelessWidget {
  const BuyStepList({super.key, required this.steps});

  final List<BuyStep> steps;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DexCard(
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                children: [
                  _mark(colors, steps[i].mark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      steps[i].label,
                      key: Key('buy-step-$i'),
                      style: STextStyles.smallMed14(context).copyWith(
                        color: steps[i].mark == BuyStepMark.waiting
                            ? colors.textSubtitle1
                            : colors.textDark,
                      ),
                    ),
                  ),
                  if (steps[i].note != null)
                    Text(
                      steps[i].note!,
                      style: STextStyles.label(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _mark(StackColors colors, BuyStepMark m) => switch (m) {
    BuyStepMark.done => Icon(
      Icons.check_circle_rounded,
      key: const Key('buy-step-done'),
      size: 20,
      color: colors.accentColorGreen,
    ),
    BuyStepMark.active => Icon(
      Icons.hourglass_top_rounded,
      size: 20,
      color: colors.accentColorOrange,
    ),
    BuyStepMark.waiting => Icon(
      Icons.radio_button_unchecked_rounded,
      size: 20,
      color: colors.textSubtitle2,
    ),
    BuyStepMark.failed => Icon(
      Icons.cancel_rounded,
      size: 20,
      color: colors.accentColorRed,
    ),
  };
}

// ----------------------------------------------------------------- a buy

/// One buy in a list: what was paid, what it buys, where it is.
class BuyOrderCard extends StatelessWidget {
  const BuyOrderCard({super.key, required this.order, required this.onTap});

  final BuyBeamOrder order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final o = order;
    final estimate = o.beamEstimate == null
        ? null
        : BuyBeamWords.beamShort(o.beamEstimate!);
    final s = o.lastState;
    final Color tone = switch (s) {
      BuyBeamState.delivered => colors.accentColorGreen,
      BuyBeamState.refunded ||
      BuyBeamState.expired ||
      BuyBeamState.failed => colors.textSubtitle1,
      BuyBeamState.attention => colors.accentColorRed,
      _ => colors.accentColorOrange,
    };
    return DexCard(
      key: Key('buy-order-${o.depositAddress}'),
      onTap: onTap,
      child: Row(
        children: [
          BuyCoinIcon(assetId: o.assetId, symbol: o.symbol, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${o.sendAmount} ${o.symbol}'
                  '${estimate == null ? '' : ' → ≈ $estimate'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.titleBold12(context),
                ),
                const SizedBox(height: 2),
                Text(
                  BuyBeamWords.stateLine(o),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.label(context).copyWith(color: tone),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: colors.textSubtitle1,
          ),
        ],
      ),
    );
  }
}
