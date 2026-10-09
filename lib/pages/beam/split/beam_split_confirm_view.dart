/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   1. Job: show exactly what the split does before it is signed (like a
//      send's confirmation): the coins now, the coins after, the fee, and
//      that nothing leaves the wallet.
//   2. Primary CTA: "Split into 5 coins", then Campfire's PIN / password.
//   3. Taps: reached from the split screen's button; 1 tap + PIN.
//
// Exit-intent: "is money leaving?" → the first notice and the last
// line both say only the fee does; "can I back out?" → the back arrow, and
// nothing is signed until the PIN; "did it go?" → the split screen turns
// into "Splitting into 5 coins" with when they are ready.

import 'package:flutter/material.dart';

import '../../../wallets/beam/utxo/beam_coin_split.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/split/beam_split_backend.dart';
import '../../../widgets/beam/split/beam_split_text.dart';
import '../../../widgets/rounded_white_container.dart';

/// The review of a prepared split. Pops with the tx id once the split is
/// handed to the core; leaving without it discards [prepared].
class BeamSplitConfirmView extends StatefulWidget {
  const BeamSplitConfirmView({
    super.key,
    required this.backend,
    required this.prepared,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamSplitBackend backend;
  final BeamPreparedSplit prepared;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamSplitConfirmView> createState() => _BeamSplitConfirmViewState();
}

class _BeamSplitConfirmViewState extends State<BeamSplitConfirmView>
    with BeamSendFlow {
  BeamAssetNames get _names => widget.backend.names;

  @override
  void dispose() {
    if (widget.prepared.handedOff == null) widget.prepared.discard();
    super.dispose();
  }

  Future<void> _confirm() async {
    final plan = widget.prepared.plan;
    final symbol = _names.symbol(plan.assetId);
    final tx = await runSend(
      authorize: widget.authorize,
      reason: BeamSplitText.authReason(plan, symbol),
      send: () => widget.backend.confirm(widget.prepared),
      explain: (e) {
        final w = beamWalletExceptionFrom(e);
        return BeamProblem(
          w.problem == BeamWalletProblem.sendOutcomeUnknown
              ? 'Not sure the split started'
              : 'The coins were not split',
          w.message,
        );
      },
    );
    if (tx != null && mounted) Navigator.of(context).pop(tx);
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.backend.sync,
    builder: (context, sync) {
      final p = widget.prepared;
      final plan = p.plan;
      final aid = plan.assetId;
      final symbol = _names.symbol(aid);
      final before = p.before;
      final coinsNow = before.available.length;
      // The wallet let the prepared split go (it was tried, and failed or
      // may have started): never offered again here; review it again.
      final spent = problem != null && p.isDiscarded;
      return BeamPageScaffold(
        title: BeamSplitText.reviewTitle,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamNotice(
              key: const ValueKey('split-review-note'),
              kind: BeamNoticeKind.info,
              title: 'Nothing leaves your wallet',
              message: BeamSplitText.reviewNote(symbol, asset: aid != 0),
            ),
            const BeamGap(),
            RoundedWhiteContainer(
              child: BeamAssetTitle(display: _names.display(aid)),
            ),
            const BeamGap(8),
            BeamDetailCard(
              children: [
                BeamDetailRow(
                  label: 'Now',
                  value:
                      '${BeamUnits.withSymbol(before.availableTotal, symbol)} '
                      'in $coinsNow ${coinsNow == 1 ? 'coin' : 'coins'}',
                  valueKey: const ValueKey('split-review-now'),
                ),
                BeamDetailRow(
                  label: 'New coins',
                  value: BeamSplitText.newCoins(plan, symbol),
                  valueKey: const ValueKey('split-review-new'),
                ),
                if (plan.change > BigInt.zero)
                  BeamDetailRow(
                    label: 'Stays as change',
                    value: BeamUnits.withSymbol(plan.change, symbol),
                  ),
                BeamDetailRow(
                  label: 'Network fee',
                  value: BeamSplitText.fee(plan),
                  valueKey: const ValueKey('split-review-fee'),
                ),
              ],
            ),
            const BeamGap(8),
            BeamTotalRow(
              label: 'Leaves your wallet',
              value: BeamSplitText.leaves(plan),
              valueKey: const ValueKey('split-review-leaves'),
              confirm: false,
            ),
            if (problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('split-review-problem'),
                kind: BeamNoticeKind.danger,
                title: problem!.title,
                message: problem!.message,
              ),
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamSyncNotice(sync: sync, what: 'Splitting'),
            if (spent)
              BeamCtaBar(
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              BeamCtaBar(
                primaryKey: const ValueKey('split-confirm-cta'),
                label: BeamSplitText.cta(plan.count),
                busy: sending,
                busyLabel: 'Splitting…',
                onPressed: sync.canSpend ? _confirm : null,
              ),
          ],
        ),
      );
    },
  );
}
