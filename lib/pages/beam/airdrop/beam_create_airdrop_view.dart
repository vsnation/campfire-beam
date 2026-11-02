/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  lock tokens into one-time codes to hand out.
//   CTA:  "Create <n> codes" (then "Create <n> codes" again on the
//         confirmation, which shows the amounts read back from the built
//         transaction).
//   Taps: open wallet → Airdrop → Create codes → amount → Create (→ confirm
//         → PIN): 4 + confirm + PIN, BEAM, 10 codes and paid claim fees
//         pre-filled.
//
// Every new batch is made on Airdrop v3: 1 to 100 codes, whose claims never
// show the code to the network.
//
// Exit-intent: "what will this cost?" → the locked total, the 1% fee, the
// claim fees paid ahead and the network fee update as the user types, with
// what leaves the wallet in total; the confirmation shows the same figures
// read back from the built transaction; "my friends have no BEAM for the
// fee" → "Pay the claim fee for each code" is on by default (0.022 BEAM
// per code), one tap turns it off; "can I share them right away?" → said
// before the button: the codes are checked on the network first, a few
// minutes after the batch is confirmed; "what if I lose the codes?" → saved
// on this device before anything is sent; "I tapped twice — did I pay
// twice?" → one batch per tap, guarded here and in the service.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';
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
    this.initialValue,
    this.initialCount,
    this.initialPrepayClaimFees = true,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamCreateAirdrop';
  static String get title => appL10n.airdropCreateTitle;

  /// This wallet's airdrops; they must have a code store.
  final BeamAirdrops service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Pre-selected asset (BEAM by default).
  final int initialAssetId;

  /// Pre-filled amount per code and number of codes, when new codes replace
  /// a batch whose codes failed their check ("Make new codes").
  final BigInt? initialValue;
  final int? initialCount;

  /// Whether "Pay the claim fee for each code" starts on (it does, unless a
  /// replaced batch had it off).
  final bool initialPrepayClaimFees;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;

  @override
  State<BeamCreateAirdropView> createState() => _BeamCreateAirdropViewState();
}

class _BeamCreateAirdropViewState extends State<BeamCreateAirdropView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  late final _amount = TextEditingController(
    text: widget.initialValue == null
        ? ''
        // Nothing until the asset's decimals are read: a text written as 8 would be read with others.
        : BeamUnits.plain(
            widget.initialValue!,
            places: _names.decimals(widget.initialAssetId),
          ),
  );
  late final _count = TextEditingController(
    text: '${widget.initialCount ?? 10}',
  );

  late int _assetId = widget.initialAssetId;
  late bool _prepay = widget.initialPrepayClaimFees;
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
            BeamProblem(
              context.l10n.airdropCreateCantReadTitle,
              context.l10n.airdropCreateCantReadMessage,
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
    return n != null && n >= 1 && n <= kAirdropV3MaxVouchersPerBatch ? n : null;
  }

  String? get _countProblem {
    if (_count.text.trim().isEmpty) return null;
    return _n == null
        ? context.l10n.airdropCreateCountProblem(kAirdropV3MaxVouchersPerBatch)
        : null;
  }

  // In the asset's own decimals (its NTH_RATIO); nothing while they are not read.
  BigInt? get _value =>
      BeamUnits.parse(_amount.text, places: _names.decimals(_assetId));

  /// The largest amount a call's funds carry (signed 64-bit).
  static final _maxFunds = (BigInt.one << 63) - BigInt.one;

  /// What the batch costs, for valid input: locked for the codes, the 1%
  /// fee, the claim fees paid ahead and the network fee (the fee the
  /// service requires the built transaction to carry, exactly).
  ({BigInt total, BigInt fee, BigInt gas, BigInt network})? get _plan {
    final v = _value;
    final n = _n;
    if (v == null || n == null) return null;
    final total = v * BigInt.from(n);
    if (total > _maxFunds) return null;
    final fee = AirdropV3Fee.creationFee(total);
    final gas = _prepay
        ? kAirdropV3GasPerVoucher * BigInt.from(n)
        : BigInt.zero;
    if (total + fee + (_assetId == 0 ? gas : BigInt.zero) > _maxFunds) {
      return null;
    }
    return (total: total, fee: fee, gas: gas, network: AirdropV3Fee.create(n));
  }

  BigInt get _beamAvailable => _balances?[0] ?? BigInt.zero;

  String? get _fundsProblem {
    final p = _plan;
    if (p == null || _balances == null) return null;
    final lock = p.total + p.fee;
    final beam = p.gas + p.network;
    String b(BigInt v) => BeamUnits.withSymbol(v, 'BEAM');
    final l10n = context.l10n;
    if (_assetId == 0) {
      if (lock + beam <= _available) return null;
      return l10n.airdropCreateNeedsBeam(b(lock + beam), b(_available));
    }
    if (lock > _available) {
      return l10n.airdropCreateNeedsAsset(
        _names.amount(_assetId, lock),
        _names.amount(_assetId, _available),
      );
    }
    if (beam > _beamAvailable) {
      return p.gas > BigInt.zero
          ? l10n.airdropCreateFeesNeedBeam(b(beam), b(_beamAvailable))
          : l10n.airdropCreateNetworkFeeNeedsBeam(b(beam), b(_beamAvailable));
    }
    return null;
  }

  /// Which asset runs short, for the notice's title.
  String get _shortSymbol {
    final p = _plan;
    if (_assetId == 0 || p == null) return _names.symbol(_assetId);
    return p.total + p.fee > _available ? _names.symbol(_assetId) : 'BEAM';
  }

  Future<void> _pickAsset() async {
    final picked = await showBeamAssetPicker(
      context: context,
      assets: _held,
      names: _names,
      title: context.l10n.airdropCreateWhatToGive,
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
    AirdropPreparedCall? p;
    try {
      p = await widget.service.prepareCreateBatch(
        assetId: _assetId,
        values: List.filled(n, v),
        prepayClaimFees: _prepay,
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
            localId: p!.savedLocalId!,
            assetNames: _names,
            justCreated: true,
            notice: sent.problem,
            sync: widget.sync,
            authorize: widget.authorize,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  static String _beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');

  /// "Pay the claim fee for each code": on by default, so people with an
  /// empty wallet can claim (README "Gasless claims", prepaid gas).
  Widget _prepayToggle(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      key: const ValueKey('create-prepay'),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      onPressed: () => setState(() => _prepay = !_prepay),
      child: Row(
        children: [
          Checkbox(
            key: const ValueKey('create-prepay-box'),
            value: _prepay,
            onChanged: (v) => setState(() => _prepay = v ?? false),
            activeColor: colors.checkboxBGChecked,
            checkColor: colors.checkboxIconChecked,
          ),
          Expanded(
            child: Text(
              context.l10n.airdropCreatePrepayClaimFees(
                BeamUnits.withSymbol(kAirdropV3GasPerVoucher, 'BEAM'),
              ),
              style: STextStyles.itemSubtitle12(context),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final plan = _plan;
      final n = _n;
      final valid =
          plan != null &&
          _fundsProblem == null &&
          _balances != null &&
          _available > BigInt.zero;
      final l10n = context.l10n;
      return BeamPageScaffold(
        title: BeamCreateAirdropView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.airdropCreateIntro,
              style: STextStyles.itemSubtitle(context),
            ),
            const BeamGap(16),
            if (_loadProblem != null) ...[
              BeamNotice(
                kind: BeamNoticeKind.danger,
                title: _loadProblem!.title,
                message: _loadProblem!.message,
                actionLabel: l10n.commonTryAgain,
                onAction: _loadBalances,
              ),
              const BeamGap(),
            ],
            BeamLabel(l10n.airdropCreateWhatToGive),
            RoundedWhiteContainer(
              key: const ValueKey('create-asset'),
              onPressed: _held.length > 1 ? _pickAsset : null,
              child: BeamAssetTitle(
                display: _names.display(_assetId),
                subtitle: _balances == null
                    ? l10n.airdropCreateReadingBalance
                    : l10n.beamAssetYouHave(
                        _names.amount(_assetId, _available),
                      ),
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
                    label: l10n.airdropEachCodeGives,
                    hint: '0.1',
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    error: BeamUnits.problem(
                      _amount.text,
                      places: _names.decimals(_assetId),
                      symbol: _names.display(_assetId).label,
                    ),
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
                    label: l10n.airdropNumberOfCodes,
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
            const BeamGap(12),
            _prepayToggle(context),
            const BeamGap(12),
            if (plan != null) ...[
              BeamDetailCard(
                children: [
                  BeamDetailRow(
                    label: l10n.airdropLockedForCodes,
                    value: _names.amount(_assetId, plan.total),
                    detail: '$n × ${_names.amount(_assetId, _value!)}',
                    valueKey: const ValueKey('create-locked'),
                  ),
                  BeamDetailRow(
                    label: l10n.airdropFeeLabel,
                    value: _names.amount(_assetId, plan.fee),
                    detail: l10n.airdropConfirmFeeKept,
                    valueKey: const ValueKey('create-fee'),
                  ),
                  if (_prepay)
                    BeamDetailRow(
                      label: l10n.airdropConfirmClaimFeesLabel,
                      value: BeamUnits.withSymbol(plan.gas, 'BEAM'),
                      detail:
                          '$n × '
                          '${_beam(kAirdropV3GasPerVoucher)}',
                      valueKey: const ValueKey('create-gas'),
                    ),
                  BeamDetailRow(
                    label: l10n.beamNetworkFee,
                    value: BeamUnits.withSymbol(plan.network, 'BEAM'),
                    valueKey: const ValueKey('create-network-fee'),
                  ),
                ],
              ),
              const BeamGap(8),
              BeamTotalRow(
                confirm: false,
                label: l10n.airdropLeavesWallet,
                value: _assetId == 0
                    ? BeamUnits.withSymbol(
                        plan.total + plan.fee + plan.gas + plan.network,
                        'BEAM',
                      )
                    : '${_names.amount(_assetId, plan.total + plan.fee)} + '
                          '${_beam(plan.gas + plan.network)}',
                valueKey: const ValueKey('create-total'),
              ),
            ],
            if (_fundsProblem != null) ...[
              const BeamGap(),
              BeamNotice(
                key: const ValueKey('create-funds-problem'),
                kind: BeamNoticeKind.danger,
                title: l10n.airdropCreateNotEnoughTitle(_shortSymbol),
                message: joinSentences([
                  _fundsProblem,
                  _prepay
                      ? l10n.airdropCreateLowerAmountOrNoClaimFees
                      : l10n.airdropCreateLowerAmount,
                ], l10n),
              ),
            ],
            const BeamGap(),
            // What a code is, closest to the button (the scariest question
            // sits next to the action).
            BeamNotice(
              key: const ValueKey('create-bearer-warning'),
              kind: BeamNoticeKind.warning,
              title: AirdropBearerText.createTitle,
              message: AirdropBearerText.createMessageV3,
            ),
            const BeamGap(8),
            Text(
              _prepay
                  ? l10n.airdropCreateCheckNoteWithFees
                  : l10n.airdropCreateCheckNote,
              key: const ValueKey('create-check-note'),
              style: STextStyles.label(context),
            ),
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
            BeamSyncNotice(sync: sync, action: BeamPausedAction.creatingCodes),
            BeamCtaBar(
              primaryKey: const ValueKey('create-cta'),
              label: n == null
                  ? l10n.airdropCreateCodesCtaNoCount
                  : l10n.airdropCreateCodesCta(n),
              busy: _preparing,
              busyLabel: l10n.airdropPreparing,
              onPressed: valid && sync.canSpend ? _create : null,
            ),
          ],
        ),
      );
    },
  );
}
