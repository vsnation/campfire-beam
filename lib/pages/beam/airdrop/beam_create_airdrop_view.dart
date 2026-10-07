/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  lock tokens into one-time codes to hand out.
//   CTA:  "Create <n> codes" (then "Create <n> codes" again on the
//         confirmation, which shows the amounts read back from the built
//         transaction).
//   Taps: open wallet → Airdrop → Create codes → amount → Create (→ confirm
//         → PIN): 4 + confirm + PIN, BEAM and 10 codes pre-filled.
//
// Exit-intent (§1.7): "what will this cost?" → the locked total and the 1%
// fee update as the user types, and the network fee is shown, exact,
// before confirming; "what if I lose the codes?" → saved on this device
// before anything is sent, and the next screen says how to keep a copy;
// "I tapped twice — did I pay twice?" → one batch per tap, guarded here
// and in the service.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_airdrop_codes_view.dart';
import 'beam_airdrop_confirm_view.dart';

/// Create a batch of airdrop codes.
class BeamCreateAirdropView extends StatefulWidget {
  const BeamCreateAirdropView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.initialAssetId = 0,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamCreateAirdrop';
  static const title = 'Create airdrop codes';

  /// This wallet's airdrop service; it must have a code store.
  final BeamAirdropService service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Pre-selected asset (BEAM by default).
  final int initialAssetId;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;

  @override
  State<BeamCreateAirdropView> createState() => _BeamCreateAirdropViewState();
}

class _BeamCreateAirdropViewState extends State<BeamCreateAirdropView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  final _amount = TextEditingController();
  final _count = TextEditingController(text: '10');

  late int _assetId = widget.initialAssetId;
  Map<int, BigInt>? _balances;
  BeamProblem? _loadProblem;
  BeamProblem? _problem;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    unawaited(_loadBalances());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _names.removeListener(_rebuild);
    _amount.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _loadBalances() async {
    setState(() => _loadProblem = null);
    try {
      final b = await beamAvailableBalances(widget.service.api);
      if (!mounted) return;
      setState(() => _balances = b);
      unawaited(_names.preload(b.keys));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _loadProblem =
            beamTransportProblem(e) ??
            const BeamProblem(
              "Couldn't read your balances",
              'The wallet did not answer. Try again in a moment.',
            ),
      );
    }
  }

  List<BeamHeldAsset> get _held => [
    for (final e in (_balances ?? const <int, BigInt>{}).entries)
      if (e.value > BigInt.zero) BeamHeldAsset(e.key, e.value),
  ]..sort((a, b) => a.assetId.compareTo(b.assetId));

  BigInt get _available => _balances?[_assetId] ?? BigInt.zero;

  int? get _n {
    final n = int.tryParse(_count.text.trim());
    return n != null && n >= 1 && n <= kAirdropMaxVouchersPerBatch ? n : null;
  }

  String? get _countProblem {
    if (_count.text.trim().isEmpty) return null;
    return _n == null ? 'Choose 1 to $kAirdropMaxVouchersPerBatch codes' : null;
  }

  BigInt? get _value => BeamUnits.parse(_amount.text);

  /// (total locked, 1% fee) for valid input.
  (BigInt, BigInt)? get _totals {
    final v = _value;
    final n = _n;
    if (v == null || n == null) return null;
    final total = v * BigInt.from(n);
    if (total > AirdropFee.maxTotal) return null;
    return (total, AirdropFee.creationFee(total));
  }

  String? get _fundsProblem {
    final t = _totals;
    if (t == null || _balances == null) return null;
    final (total, fee) = t;
    if (total + fee <= _available) return null;
    return 'You have ${_names.amount(_assetId, _available)}: not enough for '
        '${_n!} codes plus the 1% fee.';
  }

  Future<void> _pickAsset() async {
    final picked = await showBeamAssetPicker(
      context: context,
      assets: _held,
      names: _names,
      title: 'What to give away',
    );
    if (picked != null && mounted) setState(() => _assetId = picked);
  }

  Future<void> _create() async {
    // Claimed before the first await: a second tap finds it set.
    if (_preparing) return;
    final v = _value;
    final n = _n;
    if (v == null || n == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    BeamPreparedAirdropCall? p;
    try {
      p = await widget.service.prepareCreateBatch(
        assetId: _assetId,
        values: List.filled(n, v),
      );
    } catch (e) {
      if (mounted) setState(() => _problem = airdropProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (p == null) return;
    if (!mounted) {
      widget.service.discard(p);
      return;
    }
    final sent = await Navigator.of(context).push<BeamAirdropSent>(
      MaterialPageRoute(
        builder: (_) => BeamAirdropConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (sent == null || !mounted) return;
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BeamAirdropCodesView(
            service: widget.service,
            localId: p!.saved!.localId,
            assetNames: _names,
            justCreated: true,
            notice: sent.problem,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final totals = _totals;
      final n = _n;
      final valid =
          totals != null &&
          _fundsProblem == null &&
          _balances != null &&
          _available > BigInt.zero;
      return BeamPageScaffold(
        title: BeamCreateAirdropView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Lock tokens into one-time codes. Whoever gets a code can claim '
              'its tokens once.',
              style: STextStyles.itemSubtitle(context),
            ),
            const BeamGap(16),
            const BeamNotice(
              key: ValueKey('create-bearer-warning'),
              kind: BeamNoticeKind.warning,
              title: AirdropBearerText.createTitle,
              message: AirdropBearerText.createMessage,
            ),
            const BeamGap(16),
            if (_loadProblem != null) ...[
              BeamNotice(
                kind: BeamNoticeKind.danger,
                title: _loadProblem!.title,
                message: _loadProblem!.message,
                actionLabel: 'Try again',
                onAction: _loadBalances,
              ),
              const BeamGap(),
            ],
            const BeamLabel('What to give away'),
            RoundedWhiteContainer(
              key: const ValueKey('create-asset'),
              onPressed: _held.length > 1 ? _pickAsset : null,
              child: BeamAssetTitle(
                display: _names.display(_assetId),
                subtitle: _balances == null
                    ? 'Reading your balance…'
                    : 'You have ${_names.amount(_assetId, _available)}',
                trailing: _held.length > 1
                    ? Icon(
                        Icons.expand_more_rounded,
                        color: Theme.of(context)
                            .extension<StackColors>()!
                            .textSubtitle1,
                      )
                    : null,
              ),
            ),
            const BeamGap(16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: BeamTextField(
                    fieldKey: const ValueKey('create-amount'),
                    controller: _amount,
                    label: 'Each code gives',
                    hint: '0.1',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    error: BeamUnits.problem(_amount.text),
                    suffix: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Center(
                        widthFactor: 1,
                        child: Text(
                          _names.symbol(_assetId),
                          style: STextStyles.label(context),
                        ),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: BeamTextField(
                    fieldKey: const ValueKey('create-count'),
                    controller: _count,
                    label: 'Number of codes',
                    hint: '10',
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    error: _countProblem,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const BeamGap(16),
            if (totals != null)
              BeamDetailCard(
                children: [
                  BeamDetailRow(
                    label: 'Locked for the codes',
                    value: _names.amount(_assetId, totals.$1),
                    detail: '$n × ${_names.amount(_assetId, _value!)}',
                    valueKey: const ValueKey('create-locked'),
                  ),
                  BeamDetailRow(
                    label: 'Airdrop fee (1%)',
                    value: _names.amount(_assetId, totals.$2),
                    valueKey: const ValueKey('create-fee'),
                  ),
                  const BeamDetailRow(
                    label: 'Network fee',
                    value: 'Shown before you confirm',
                  ),
                ],
              ),
            if (_fundsProblem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('create-funds-problem'),
                kind: BeamNoticeKind.danger,
                title: 'Not enough ${_names.symbol(_assetId)}',
                message:
                    '${_fundsProblem!} Lower the amount or the number '
                    'of codes.',
              ),
            ],
            if (_problem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('create-problem'),
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
            BeamSyncNotice(sync: sync, what: 'Creating codes'),
            BeamCtaBar(
              primaryKey: const ValueKey('create-cta'),
              label: n == null ? 'Create codes' : 'Create $n codes',
              busy: _preparing,
              busyLabel: 'Preparing…',
              onPressed: valid && sync.canSpend ? _create : null,
            ),
          ],
        ),
      );
    },
  );
}
