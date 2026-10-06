/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  mint more of a token this wallet created.
//   CTA:  "Mint <amount> <TICKER>".
//   Taps: My tokens → Mint more → amount → Mint (→ confirm → PIN).
//
// Exit-intent (§1.7): "how much can I mint?" → the remaining amount is
// shown, with a one-tap "Most"; "what does it cost?" → the confirmation
// shows the exact network fee.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/minter/minter_text.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_minter_confirm_view.dart';

/// Mint more of [token]. Pops with the amount minted once sent.
class BeamMintMoreView extends StatefulWidget {
  const BeamMintMoreView({
    super.key,
    required this.service,
    required this.token,
    required this.sync,
    required this.assetNames,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamMinterService service;
  final MinterToken token;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames assetNames;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamMintMoreView> createState() => _BeamMintMoreViewState();
}

class _BeamMintMoreViewState extends State<BeamMintMoreView> {
  final _amount = TextEditingController();
  bool _preparing = false;
  BeamProblem? _problem;

  MinterToken get _t => widget.token;

  /// One mint moves at most 2^64-1 units (the `withdraw` argument).
  static final _maxPerMint = (BigInt.one << 64) - BigInt.one;

  BigInt get _most => _t.mintable < _maxPerMint ? _t.mintable : _maxPerMint;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  String? get _amountProblem {
    final p = BeamUnits.problem(_amount.text);
    if (p != null) return p;
    final v = BeamUnits.parse(_amount.text);
    if (v != null && v > _most) {
      return 'At most ${widget.assetNames.amount(_t.assetId, _most)}';
    }
    return null;
  }

  Future<void> _mint() async {
    if (_preparing) return;
    final v = BeamUnits.parse(_amount.text);
    if (v == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    BeamPreparedMinterCall? p;
    try {
      p = await widget.service.prepareMint(assetId: _t.assetId, value: v);
    } catch (e) {
      if (mounted) setState(() => _problem = minterProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (p == null) return;
    if (!mounted) {
      widget.service.discard(p);
      return;
    }
    final tx = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => BeamMinterConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: widget.assetNames,
          authorize: widget.authorize,
        ),
      ),
    );
    if (tx != null && mounted) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final v = BeamUnits.parse(_amount.text);
      final ok = v != null && _amountProblem == null;
      final names = widget.assetNames;
      return BeamPageScaffold(
        title: 'Mint more',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RoundedWhiteContainer(
              child: BeamAssetTitle(
                display: names.display(_t.assetId),
                subtitle:
                    'You can still mint '
                    '${names.amount(_t.assetId, _t.mintable)}',
              ),
            ),
            const BeamGap(16),
            BeamTextField(
              fieldKey: const ValueKey('mint-more-amount'),
              controller: _amount,
              label: 'How many to mint',
              hint: '1000',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              error: _amountProblem,
              suffix: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    names.symbol(_t.assetId),
                    style: STextStyles.label(context),
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const BeamGap(8),
            Align(
              alignment: Alignment.centerRight,
              child: CustomTextButton(
                text: 'Most',
                onTap: () => setState(
                  () =>
                      _amount.text = BeamUnits.format(_most)
                          .replaceAll(',', ''),
                ),
              ),
            ),
            if (_problem != null) ...[
              const BeamGap(),
              BeamNotice(
                kind: BeamNoticeKind.danger,
                title: _problem!.title,
                message: _problem!.message,
              ),
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BeamSyncNotice(sync: sync, what: 'Minting'),
            BeamCtaBar(
              primaryKey: const ValueKey('mint-more-cta'),
              label: ok
                  ? 'Mint ${names.amount(_t.assetId, v)}'
                  : 'Mint ${names.symbol(_t.assetId)}',
              busy: _preparing,
              busyLabel: 'Preparing…',
              onPressed: ok && sync.canSpend ? _mint : null,
            ),
          ],
        ),
      );
    },
  );
}
