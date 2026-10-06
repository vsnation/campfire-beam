/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  show what creating (or minting) a token costs and does, from the
//         transaction the core built, and send it after the PIN.
//   CTA:  "Create <TICKER> for <total>" / "Mint <amount>".
//   Taps: reached from the token form or My tokens; 1 tap + PIN here.
//
// Exit-intent (§1.7): "60 BEAM for what?" → each part is named, and that it
// never comes back is said before confirming; "what exactly is signed?" →
// the metadata stored on chain can be shown in full.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/minter/minter_text.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';

/// Confirms a prepared `create_token` or mint. Pops with the tx id once
/// sent; leaving without sending discards [prepared].
class BeamMinterConfirmView extends StatefulWidget {
  const BeamMinterConfirmView({
    super.key,
    required this.service,
    required this.prepared,
    required this.sync,
    required this.assetNames,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamMinterService service;
  final BeamPreparedMinterCall prepared;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames assetNames;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamMinterConfirmView> createState() => _BeamMinterConfirmViewState();
}

class _BeamMinterConfirmViewState extends State<BeamMinterConfirmView>
    with BeamSendFlow {
  BigInt? _beamAvailable;
  bool _showMetadata = false;

  MinterSummary get _s => widget.prepared.summary;
  bool get _create => _s.action == MinterAction.createToken;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBalance());
  }

  Future<void> _loadBalance() async {
    try {
      final b = await beamAvailableBalances(widget.service.api);
      if (mounted) setState(() => _beamAvailable = b[0]);
    } catch (_) {
      // Unknown: the core refuses an unaffordable transaction anyway.
    }
  }

  @override
  void dispose() {
    final p = widget.prepared;
    if (!p.isExecuted) widget.service.discard(p);
    super.dispose();
  }

  String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');

  Map<String, String> get _fields =>
      BeamTokenMetadata.parseFields(_s.metadata ?? '') ?? const {};

  String get _ticker =>
      _create ? (_fields['SN'] ?? '') : widget.assetNames.symbol(_s.assetId!);

  Future<void> _confirm() async {
    final tx = await runSend(
      authorize: widget.authorize,
      reason: _create ? 'Create the token $_ticker' : 'Mint $_ticker',
      send: () => widget.service.execute(widget.prepared),
      explain: minterProblem,
    );
    if (tx != null && mounted) Navigator.of(context).pop(tx);
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final short = _beamAvailable != null && _beamAvailable! < _s.beamOut;
      final spent = widget.prepared.isExecuted;
      return BeamPageScaffold(
        title: _create ? 'Confirm new token' : 'Confirm mint',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_create) ..._createRows(context) else ..._mintRows(context),
            if (short) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('minter-confirm-short'),
                kind: BeamNoticeKind.danger,
                title: 'Not enough BEAM',
                message:
                    'This needs ${_beam(_s.beamOut)} and the wallet has '
                    '${_beam(_beamAvailable!)}. Add BEAM to this wallet, '
                    'then try again.',
              ),
            ],
            if (problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('minter-confirm-problem'),
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
            BeamSyncNotice(
              sync: sync,
              what: _create ? 'Creating a token' : 'Minting',
            ),
            if (spent && problem != null)
              BeamCtaBar(
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              BeamCtaBar(
                primaryKey: const ValueKey('minter-confirm-cta'),
                label: _create
                    ? 'Create $_ticker for ${_beam(_s.beamOut)}'
                    : 'Mint ${_minted()}',
                busy: sending,
                busyLabel: 'Sending…',
                onPressed: sync.canSpend && !short ? _confirm : null,
              ),
          ],
        ),
      );
    },
  );

  List<Widget> _createRows(BuildContext context) {
    final f = _fields;
    final colors = Theme.of(context).extension<StackColors>()!;
    final whole = _s.limit! ~/ BeamTokenMetadata.nthRatio;
    final lost = _s.issueFee! + _s.assetDeposit!;
    return [
      RoundedWhiteContainer(
        child: BeamAssetTitle(
          // Not created yet, so it has no id to show or to verify.
          markUnverified: false,
          display: BeamAssetDisplay(
            assetId: 0,
            name: f['N'] ?? '',
            symbol: f['SN'] ?? '',
            verified: false,
            color: _color(f['OPT_COLOR']),
          ),
          subtitle:
              'New token · at most ${BeamUnits.format(whole * BeamUnits.one)}'
              ' ${f['SN'] ?? ''}',
        ),
      ),
      const BeamGap(8),
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: 'To the BEAM DAO',
            value: _beam(_s.issueFee!),
            detail: 'Issuance fee',
            valueKey: const ValueKey('minter-issue-fee'),
          ),
          BeamDetailRow(
            label: 'Asset deposit',
            value: _beam(_s.assetDeposit!),
            detail: 'Never returned',
            valueKey: const ValueKey('minter-deposit'),
          ),
          BeamDetailRow(
            label: 'Network fee',
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('minter-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: 'Leaves your wallet',
        value: _beam(_s.beamOut),
        valueKey: const ValueKey('minter-total'),
      ),
      const BeamGap(),
      BeamNotice(
        kind: BeamNoticeKind.warning,
        title: 'These ${_beam(lost)} do not come back',
        message:
            'Not even if you never mint the token. Nothing is minted yet: '
            'once the token exists, mint it from My tokens.',
      ),
      const BeamGap(8),
      Align(
        alignment: Alignment.centerLeft,
        child: CustomTextButton(
          text: _showMetadata
              ? 'Hide what is stored on the chain'
              : 'Show what is stored on the chain',
          onTap: () => setState(() => _showMetadata = !_showMetadata),
        ),
      ),
      if (_showMetadata) ...[
        const BeamGap(8),
        RoundedContainer(
          color: colors.textFieldDefaultBG,
          child: SelectableText(
            _s.metadata ?? '',
            style: STextStyles.label(context),
          ),
        ),
      ],
    ];
  }

  String _minted() =>
      widget.assetNames.amount(_s.assetId!, _s.receives[_s.assetId]!);

  List<Widget> _mintRows(BuildContext context) {
    final aid = _s.assetId!;
    final gets = _s.receives[aid]!;
    return [
      RoundedWhiteContainer(
        child: BeamAssetTitle(
          display: widget.assetNames.display(aid),
          subtitle: 'Your token',
        ),
      ),
      const BeamGap(8),
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: 'New tokens to your wallet',
            value: widget.assetNames.amount(aid, gets),
            valueKey: const ValueKey('minter-mint-amount'),
          ),
          BeamDetailRow(
            label: 'Network fee',
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('minter-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: 'Your balances change by',
        value:
            '+${widget.assetNames.amount(aid, gets)}, −${_beam(_s.networkFee)}',
        valueKey: const ValueKey('minter-total'),
      ),
    ];
  }

  static int? _color(String? hex) {
    if (hex == null) return null;
    var h = hex.substring(1);
    if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : 0xFF000000 | v;
  }
}
