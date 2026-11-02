/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  destroy some of a token for good (lower its supply in public).
//   CTA:  "Burn <amount> <TICKER>" (the confirmation then asks to type the
//         ticker and says "Burn <amount> <TICKER> forever").
//   Taps: open wallet → Tokens → Burn → amount → Burn (→ type ticker →
//         confirm → PIN). Deliberately not fast: it cannot be undone.
//
// Exit-intent: "can I undo this?" → no, and the screen says so
// before anything else; "is BEAM at risk?" → BEAM is never offered and the
// service refuses it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/burn/burn.dart';
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
import 'beam_burn_confirm_view.dart';

/// Burn (destroy for good) some of a token. BEAM itself is never offered.
class BeamBurnView extends StatefulWidget {
  const BeamBurnView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.initialAssetId,
  });

  static const routeName = '/beamBurn';
  static String get title => appL10n.minterBurnTitle;

  final BeamBurnService service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Pre-selected token; ignored for BEAM (asset 0).
  final int? initialAssetId;

  @override
  State<BeamBurnView> createState() => _BeamBurnViewState();
}

class _BeamBurnViewState extends State<BeamBurnView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  final _amount = TextEditingController();

  Map<int, BigInt>? _balances;
  int? _assetId;
  bool _preparing = false;
  BeamProblem? _loadProblem;
  BeamProblem? _problem;
  String? _burnedText;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    unawaited(_load());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _names.removeListener(_rebuild);
    _amount.dispose();
    super.dispose();
  }

  /// Tokens with a balance; BEAM (asset 0) is never one of them.
  List<BeamHeldAsset> get _tokens => [
    for (final e in (_balances ?? const <int, BigInt>{}).entries)
      if (e.key != 0 && e.value > BigInt.zero) BeamHeldAsset(e.key, e.value),
  ]..sort((a, b) => a.assetId.compareTo(b.assetId));

  Future<void> _load() async {
    setState(() => _loadProblem = null);
    try {
      final b = await beamAvailableBalances(widget.service.api);
      if (!mounted) return;
      setState(() {
        _balances = b;
        final ids = _tokens.map((t) => t.assetId);
        final want = widget.initialAssetId;
        _assetId = want != null && want != 0 && ids.contains(want)
            ? want
            : (ids.isEmpty ? null : ids.first);
      });
      unawaited(_names.preload(b.keys));
    } catch (e) {
      if (mounted) setState(() => _loadProblem = minterProblem(e));
    }
  }

  BigInt get _available => _balances?[_assetId] ?? BigInt.zero;

  /// The token's decimal places (its NTH_RATIO); null while its metadata
  /// is not read.
  int? get _places => _assetId == null ? null : _names.decimals(_assetId!);

  String? get _amountProblem {
    final p = BeamUnits.problem(
      _amount.text,
      places: _places,
      symbol: _assetId == null ? null : _names.display(_assetId!).label,
    );
    if (p != null) return p;
    final v = BeamUnits.parse(_amount.text, places: _places);
    if (v != null && _assetId != null && v > _available) {
      return context.l10n.minterBurnAmountTooMuch(
        _names.amount(_assetId!, _available),
      );
    }
    return null;
  }

  Future<void> _pick() async {
    final picked = await showBeamAssetPicker(
      context: context,
      assets: _tokens,
      names: _names,
      title: context.l10n.minterBurnPickTitle,
    );
    if (picked != null && picked != 0 && mounted) {
      setState(() => _assetId = picked);
    }
  }

  Future<void> _burn() async {
    if (_preparing) return;
    final aid = _assetId;
    final v = BeamUnits.parse(_amount.text, places: _places);
    if (aid == null || aid == 0 || v == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    BeamPreparedBurn? p;
    try {
      p = await widget.service.prepareBurn(assetId: aid, amount: v);
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
        builder: (_) => BeamBurnConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (tx != null && mounted) {
      setState(() => _burnedText = _names.amount(aid, v));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_burnedText != null) return _done(context);
    return BeamSyncGate(
      sync: widget.sync,
      builder: (context, sync) {
        final aid = _assetId;
        final v = BeamUnits.parse(_amount.text, places: _places);
        final ok = aid != null && v != null && _amountProblem == null;
        final nothing = _balances != null && _tokens.isEmpty;
        final l10n = context.l10n;
        return BeamPageScaffold(
          title: BeamBurnView.title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BeamNotice(
                key: const ValueKey('burn-intro'),
                kind: BeamNoticeKind.warning,
                title: l10n.minterBurnIntroTitle,
                message: l10n.minterBurnIntroMessage,
              ),
              const BeamGap(16),
              if (_loadProblem != null) ...[
                BeamNotice(
                  kind: BeamNoticeKind.danger,
                  title: _loadProblem!.title,
                  message: _loadProblem!.message,
                  actionLabel: l10n.commonTryAgain,
                  onAction: _load,
                ),
                const BeamGap(),
              ],
              if (_balances == null && _loadProblem == null)
                BeamWorking(l10n.minterBurnReading),
              if (nothing)
                BeamEmptyState(
                  key: const ValueKey('burn-empty'),
                  icon: Icons.local_fire_department_outlined,
                  title: l10n.minterBurnEmptyTitle,
                  message: l10n.minterBurnEmptyMessage,
                ),
              if (aid != null) ..._form(context, aid),
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
              BeamSyncNotice(sync: sync, action: BeamPausedAction.burning),
              if (nothing)
                BeamCtaBar(
                  label: l10n.commonBack,
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              else
                BeamCtaBar(
                  primaryKey: const ValueKey('burn-cta'),
                  label: ok
                      ? l10n.minterBurnCta(_names.amount(aid, v))
                      : l10n.minterBurnCtaDefault,
                  busy: _preparing,
                  busyLabel: l10n.minterPreparing,
                  onPressed: ok && sync.canSpend ? _burn : null,
                ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _form(BuildContext context, int aid) => [
    BeamLabel(context.l10n.minterBurnTokenLabel),
    RoundedWhiteContainer(
      key: const ValueKey('burn-asset'),
      onPressed: _tokens.length > 1 ? _pick : null,
      child: BeamAssetTitle(
        display: _names.display(aid),
        subtitle: context.l10n.beamAssetYouHave(_names.amount(aid, _available)),
        trailing: _tokens.length > 1
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
    BeamTextField(
      fieldKey: const ValueKey('burn-amount'),
      controller: _amount,
      label: context.l10n.minterBurnHowMany,
      hint: '0',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      error: _amountProblem,
      suffix: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Center(
          widthFactor: 1,
          child: Text(_names.symbol(aid), style: STextStyles.label(context)),
        ),
      ),
      onChanged: (_) => setState(() {}),
    ),
    const BeamGap(8),
    Align(
      alignment: Alignment.centerRight,
      child: CustomTextButton(
        text: context.l10n.minterBurnAllOfIt,
        onTap: () => setState(
          () => _amount.text = BeamUnits.plain(_available, places: _places),
        ),
      ),
    ),
  ];

  Widget _done(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    final l10n = context.l10n;
    return BeamPageScaffold(
      title: BeamBurnView.title,
      body: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          children: [
            Icon(
              Icons.local_fire_department_rounded,
              size: 64,
              color: colors.accentColorOrange,
            ),
            const BeamGap(16),
            Text(
              l10n.minterBurnDoneTitle(_burnedText!),
              key: const ValueKey('burn-done'),
              textAlign: TextAlign.center,
              style: desktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            const BeamGap(8),
            Text(
              l10n.minterBurnDoneMessage,
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
          ],
        ),
      ),
      bottom: BeamCtaBar(
        label: l10n.commonDone,
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
