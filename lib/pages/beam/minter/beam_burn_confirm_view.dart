/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  make sure the user means to destroy these tokens, then do it.
//   CTA:  "Burn <amount> <TICKER> forever", live only once the ticker is
//         typed.
//   Taps: reached from the burn form; type the ticker + 1 tap + PIN.
//
// This is the one screen that is slow on purpose (a step is added only
// when the action is destructive). Exit-intent:
// "what exactly is destroyed?" → the amount and the fee, read back from the
// built transaction, and the warning in full before the button.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../wallets/beam/contracts/burn/burn.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/minter/minter_text.dart';
import '../../../widgets/rounded_white_container.dart';

/// The heavy confirmation for a prepared burn. Pops with the tx id once
/// sent; leaving without sending discards [prepared].
class BeamBurnConfirmView extends StatefulWidget {
  const BeamBurnConfirmView({
    super.key,
    required this.service,
    required this.prepared,
    required this.sync,
    required this.assetNames,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamBurnService service;
  final BeamPreparedBurn prepared;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames assetNames;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamBurnConfirmView> createState() => _BeamBurnConfirmViewState();
}

class _BeamBurnConfirmViewState extends State<BeamBurnConfirmView>
    with BeamSendFlow {
  final _typed = TextEditingController();

  BeamBurnSummary get _s => widget.prepared.summary;

  /// What the user types: the ticker when it is plain letters and digits,
  /// otherwise the asset's number (an unverified ticker may hold symbols
  /// that are hard to type).
  String get _word {
    final sym = widget.assetNames.symbol(_s.assetId);
    return RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(sym)
        ? sym.toUpperCase()
        : '${_s.assetId}';
  }

  bool get _acknowledged => _typed.text.trim().toUpperCase() == _word;

  String get _what => widget.assetNames.amount(_s.assetId, _s.amount);

  @override
  void dispose() {
    final p = widget.prepared;
    if (!p.isExecuted) widget.service.discard(p);
    _typed.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (!_acknowledged) return;
    final tx = await runSend(
      authorize: widget.authorize,
      reason: 'Burn $_what forever',
      send: () => widget.service.execute(
        widget.prepared,
        acknowledgedPermanentLoss: _acknowledged,
      ),
      explain: minterProblem,
    );
    if (tx != null && mounted) Navigator.of(context).pop(tx);
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final spent = widget.prepared.isExecuted;
      return BeamPageScaffold(
        title: 'Confirm burn',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamNotice(
              key: const ValueKey('burn-warning'),
              kind: BeamNoticeKind.danger,
              title: 'This destroys $_what forever',
              message:
                  'Nobody can undo it: not you, not the token creator, not '
                  'us. The tokens are locked in a contract that has no way '
                  'to give anything back.',
            ),
            const BeamGap(),
            RoundedWhiteContainer(
              child: BeamAssetTitle(
                display: widget.assetNames.display(_s.assetId),
              ),
            ),
            const BeamGap(8),
            BeamDetailCard(
              children: [
                BeamDetailRow(
                  label: 'Destroyed for good',
                  value: _what,
                  valueKey: const ValueKey('burn-amount-confirm'),
                ),
                BeamDetailRow(
                  label: 'Network fee',
                  value: BeamUnits.withSymbol(_s.networkFee, 'BEAM'),
                  valueKey: const ValueKey('burn-fee'),
                ),
              ],
            ),
            const BeamGap(16),
            BeamTextField(
              fieldKey: const ValueKey('burn-type-ticker'),
              controller: _typed,
              label: 'Type $_word to confirm',
              textCapitalization: TextCapitalization.characters,
              enabled: !sending && !spent,
              onChanged: (_) => setState(() {}),
            ),
            if (problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('burn-problem'),
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
            BeamSyncNotice(sync: sync, what: 'Burning'),
            if (spent && problem != null)
              BeamCtaBar(
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              BeamCtaBar(
                primaryKey: const ValueKey('burn-confirm-cta'),
                label: 'Burn $_what forever',
                busy: sending,
                busyLabel: 'Burning…',
                onPressed: _acknowledged && sync.canSpend ? _confirm : null,
              ),
          ],
        ),
      );
    },
  );
}
