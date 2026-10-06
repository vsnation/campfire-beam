/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  show exactly what a prepared airdrop batch (or cancel) will do,
//         from the transaction the core built, and send it after the PIN.
//   CTA:  "Create <n> codes" / "Get back <amount>".
//   Taps: reached from the create form or My batches; 1 tap + PIN here.
//
// Exit-intent (§1.7): "how much does this really cost?" → every amount and
// the network fee are read back from the built transaction; "what if I
// lose the codes?" → said before confirming; "did it work?" → the next
// screen says so, and says plainly when it could not be confirmed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/rounded_white_container.dart';

/// What [BeamAirdropConfirmView] pops with once the transaction left this
/// screen: its id, or, when sending could not be confirmed (a timeout),
/// no id and a [problem] to show next to the codes, which are saved
/// either way.
@immutable
class BeamAirdropSent {
  const BeamAirdropSent({this.txId, this.problem});

  final String? txId;
  final BeamProblem? problem;
}

/// Confirms a prepared `create_batch` or `cancel_batch`.
///
/// Leaving without sending discards [prepared], which releases [service].
class BeamAirdropConfirmView extends StatefulWidget {
  const BeamAirdropConfirmView({
    super.key,
    required this.service,
    required this.prepared,
    required this.sync,
    required this.assetNames,
    this.authorize = campfireAuthorizeSpend,
  });

  final BeamAirdropService service;
  final BeamPreparedAirdropCall prepared;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames assetNames;
  final BeamSpendAuthorizer authorize;

  @override
  State<BeamAirdropConfirmView> createState() => _BeamAirdropConfirmViewState();
}

class _BeamAirdropConfirmViewState extends State<BeamAirdropConfirmView>
    with BeamSendFlow {
  BigInt? _beamAvailable;

  AirdropSummary get _s => widget.prepared.summary;
  bool get _create => widget.prepared.action == AirdropAction.createBatch;
  BeamAssetNames get _names => widget.assetNames;

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

  BigInt get _beamNeeded {
    final n = _s.beamOut - (_s.receives[0] ?? BigInt.zero);
    return n.isNegative ? BigInt.zero : n;
  }

  String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');
  String _amount(BigInt units) => _names.amount(_s.assetId, units);

  Future<void> _confirm() async {
    final p = widget.prepared;
    Object? failure;
    final tx = await runSend(
      authorize: widget.authorize,
      reason: _create ? 'Create airdrop codes' : 'Cancel airdrop codes',
      send: () => widget.service.execute(p),
      explain: (e) {
        failure = e;
        return airdropProblem(e);
      },
    );
    if (!mounted) return;
    if (tx != null) {
      Navigator.of(context).pop(BeamAirdropSent(txId: tx));
      return;
    }
    // The core refused it, or the service stopped it before sending
    // (codes not saved): nothing left the wallet, so stay and say why.
    final f = failure;
    final refused = f is BeamRpcException || f is BeamAirdropException;
    if (_create && p.isExecuted && f != null && !refused) {
      // Sent, but no answer: the batch may still go through, and its
      // codes are saved. Show them, with the warning.
      Navigator.of(context).pop(
        const BeamAirdropSent(
          problem: BeamProblem(
            'Not confirmed yet',
            "The wallet didn't confirm that the batch was sent. Your codes "
                'are saved. Check My batches in a few minutes before you '
                'hand any out.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final spent = widget.prepared.isExecuted;
      final short = _beamAvailable != null && _beamAvailable! < _beamNeeded;
      return BeamPageScaffold(
        title: _create ? 'Confirm airdrop codes' : 'Confirm cancel',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RoundedWhiteContainer(
              child: BeamAssetTitle(
                display: _names.display(_s.assetId),
                subtitle: _create
                    ? 'New airdrop codes'
                    : 'Batch ${_s.batchId} · unclaimed codes',
              ),
            ),
            const BeamGap(8),
            if (_create) ..._createRows() else ..._cancelRows(),
            if (short) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('confirm-short-of-beam'),
                kind: BeamNoticeKind.danger,
                title: 'Not enough BEAM',
                message:
                    'This needs ${_beam(_beamNeeded)} and the wallet has '
                    '${_beam(_beamAvailable!)}. Add BEAM to this wallet, '
                    'then try again.',
              ),
            ],
            if (problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('confirm-problem'),
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
              what: _create ? 'Creating codes' : 'Cancelling',
            ),
            if (spent && problem != null)
              BeamCtaBar(
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            else
              BeamCtaBar(
                primaryKey: const ValueKey('airdrop-confirm-cta'),
                label: _create
                    ? 'Create ${_s.voucherCount} codes'
                    : 'Get back ${_amount(_s.receives[_s.assetId]!)}',
                busy: sending,
                busyLabel: 'Sending…',
                onPressed: sync.canSpend && !short ? _confirm : null,
              ),
          ],
        ),
      );
    },
  );

  List<Widget> _createRows() {
    final values = _s.voucherValues!;
    final same = values.every((v) => v == values.first);
    final locked = values.fold(BigInt.zero, (a, v) => a + v);
    final isBeam = _s.assetId == 0;
    return [
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: 'Each code gives',
            value: same ? _amount(values.first) : 'Different amounts',
          ),
          BeamDetailRow(label: 'Number of codes', value: '${_s.voucherCount}'),
          BeamDetailRow(
            label: 'Locked for the codes',
            value: _amount(locked),
            valueKey: const ValueKey('confirm-locked'),
          ),
          BeamDetailRow(
            label: 'Airdrop fee (1%)',
            value: _amount(_s.creationFee!),
            detail: 'Kept by the airdrop contract',
            valueKey: const ValueKey('confirm-creation-fee'),
          ),
          BeamDetailRow(
            label: 'Network fee',
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('confirm-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: 'Leaves your wallet',
        value: isBeam
            ? _beam(_s.beamOut)
            : '${_amount(_s.pays[_s.assetId]!)} + ${_beam(_s.networkFee)}',
        valueKey: const ValueKey('confirm-total'),
      ),
      const BeamGap(),
      const BeamNotice(
        kind: BeamNoticeKind.warning,
        title: 'The codes are the only key to these funds',
        message:
            'Anyone who has a code can claim it. The codes are saved on this '
            'device before anything is sent, but they are not in your '
            'wallet backup: export a copy on the next screen.',
      ),
      const BeamGap(8),
      const BeamNotice(
        kind: BeamNoticeKind.info,
        message:
            'Codes nobody claims can be cancelled later from My batches; '
            'their value then comes back to you.',
      ),
    ];
  }

  List<Widget> _cancelRows() {
    final back = _s.receives[_s.assetId]!;
    final isBeam = _s.assetId == 0;
    final net = back - _s.networkFee;
    return [
      BeamDetailCard(
        children: [
          BeamDetailRow(
            label: 'Codes that stop working',
            value: '${_s.voucherCount}',
          ),
          BeamDetailRow(
            label: 'Comes back to you',
            value: _amount(back),
            valueKey: const ValueKey('confirm-returned'),
          ),
          BeamDetailRow(
            label: 'Network fee',
            value: _beam(_s.networkFee),
            valueKey: const ValueKey('confirm-network-fee'),
          ),
        ],
      ),
      const BeamGap(8),
      BeamTotalRow(
        label: 'Your balance changes by',
        value: isBeam
            ? '${net.isNegative ? '−' : '+'}${_beam(net.abs())}'
            : '+${_amount(back)}, −${_beam(_s.networkFee)}',
        valueKey: const ValueKey('confirm-total'),
      ),
      const BeamGap(),
      BeamNotice(
        kind: BeamNoticeKind.warning,
        message:
            'These ${_s.voucherCount} codes stop working right away, even if '
            'you already gave them to someone. Codes already claimed are not '
            'affected.',
      ),
    ];
  }
}
