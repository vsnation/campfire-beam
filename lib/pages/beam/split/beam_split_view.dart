/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   1. Job: let the wallet send several payments at once, by splitting the
//      coin(s) its BEAM (or one asset) sits in into several equal coins.
//   2. Primary CTA: the outcome, "Split into 5 coins" (the count picked;
//      the advice's count by default). It opens the review, which asks
//      once more ("Split into 5 coins" + PIN) before anything is signed.
//   3. Taps from app open: phone: wallet → More → Split coins → "Split into
//      5 coins" → "Split into 5 coins" + PIN (4 + PIN). Desktop: wallet →
//      Split coins (feature row, or More → Split coins) → "Split into 5
//      coins" → "Split into 5 coins" + password (3–4 + password). From a
//      payment that waits on busy coins: "Split coins for next time" (1).
//
// Exit-intent (§1.7) — what would make an impatient person leave, and the
// answer to each:
//   * "Is this sending my money somewhere?" → the first lines say nothing
//     leaves the wallet, and the review says it again with the fee.
//   * "What's a coin? Why would I want more?" → the headline is the gain
//     ("Send several payments at once"); the line under it says why in
//     one breath. The technical word for coins is never shown.
//   * "How many should I pick?" → the advice's count is already selected.
//   * "What will I end up with?" → "5 coins of 0.17 BEAM", the change and
//     the fee, before the button.
//   * "Why is the button grey?" → the reason is above it: not synced,
//     another payment still open, a restore still scanning, no BEAM for an
//     asset's fee, too little to split.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/utxo/beam_coin_split.dart';
import '../../../wallets/beam/utxo/beam_coins.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/split/beam_split_backend.dart';
import '../../../widgets/beam/split/beam_split_text.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_split_confirm_view.dart';

/// Split one asset's coins into several equal ones. BEAM by default; the
/// wallet's other assets (never a DEX pool share) from the asset card.
class BeamSplitView extends StatefulWidget {
  const BeamSplitView({
    super.key,
    required this.backend,
    this.initialAssetId = 0,
    this.authorize = campfireAuthorizeSpend,
    this.blockedRecheck = const Duration(seconds: 2),
  });

  static const routeName = '/beamSplitCoins';

  final BeamSplitBackend backend;
  final int initialAssetId;
  final BeamSpendAuthorizer authorize;

  /// How often a split held back by another payment or a restore scan looks
  /// again whether it may go (those clear by themselves).
  final Duration blockedRecheck;

  @override
  State<BeamSplitView> createState() => _BeamSplitViewState();
}

class _BeamSplitViewState extends State<BeamSplitView> {
  BeamSplitBackend get _b => widget.backend;
  BeamAssetNames get _names => _b.names;

  Map<int, BeamCoinSummary>? _coins;
  BeamProblem? _loadProblem;
  BeamProblem? _problem;
  late int _assetId = widget.initialAssetId;
  int? _count;
  bool _preparing = false;
  String? _blocked;
  Timer? _recheck;
  ({int count, String symbol})? _done;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    _b.coinsChanged?.addListener(_reload);
    _checkBlocked();
    unawaited(_load());
  }

  @override
  void dispose() {
    _recheck?.cancel();
    _names.removeListener(_rebuild);
    _b.coinsChanged?.removeListener(_reload);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _reload() => unawaited(_load(quiet: true));

  /// Another payment or a restore scan holds the split back; both clear by
  /// themselves, so look again now and then while one does.
  void _checkBlocked() {
    final now = _b.blocked;
    if (now != _blocked && mounted) setState(() => _blocked = now);
    _blocked = now;
    if (now == null) {
      _recheck?.cancel();
      _recheck = null;
    } else {
      _recheck ??= Timer.periodic(widget.blockedRecheck, (_) {
        if (mounted) _checkBlocked();
      });
    }
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet) setState(() => _loadProblem = null);
    try {
      final coins = await _b.coins();
      if (!mounted) return;
      setState(() {
        _coins = coins;
        _loadProblem = null;
        if (!_choices.contains(_assetId)) _assetId = 0;
      });
      unawaited(_names.preload(coins.keys));
    } catch (e) {
      if (mounted && !quiet) setState(() => _loadProblem = _explain(e));
    }
  }

  // ----------------------------------------------------------- the numbers

  /// BEAM, then every other asset with a coin worth splitting; never a DEX
  /// pool share (it goes back to its pool whole) or an asset the user hid.
  List<int> get _choices {
    final coins = _coins ?? const <int, BeamCoinSummary>{};
    return [
      0,
      for (final e in coins.entries)
        if (e.key != 0 &&
            e.value.usable.isNotEmpty &&
            !_b.isPoolShare(e.key) &&
            !_names.isHidden(e.key))
          e.key,
    ]..sort();
  }

  BeamCoinSummary get _summary =>
      _coins?[_assetId] ?? BeamCoinSummary.empty(_assetId);

  BigInt get _beamAvailable => _coins?[0]?.availableTotal ?? BigInt.zero;

  BeamSplitPlan? _planFor(int count) => BeamSplitPlan.equal(
    available: _summary.availableTotal,
    count: count,
    assetId: _assetId,
  );

  /// The counts on offer that make a real split.
  List<int> get _counts => [
    for (final n in BeamSplitPlan.choices(_summary.advice.suggestedCount))
      if (_planFor(n) != null) n,
  ];

  /// The picked count; else the advice's; else 3 (or whatever fits).
  int? get _chosen {
    final counts = _counts;
    if (counts.isEmpty) return null;
    final picked = _count;
    if (picked != null && counts.contains(picked)) return picked;
    final advised = _summary.advice.suggestedCount;
    if (counts.contains(advised)) return advised;
    if (counts.contains(3)) return 3;
    return counts.first;
  }

  BeamSplitPlan? get _plan {
    final n = _chosen;
    return n == null ? null : _planFor(n);
  }

  String get _symbol => _names.symbol(_assetId);

  /// What keeps the button off, apart from sync (its own notice).
  String? get _fundsIssue {
    if (_coins == null) return null;
    final plan = _plan;
    if (_summary.availableTotal == BigInt.zero) {
      return BeamSplitText.noCoins(_symbol);
    }
    if (plan == null) return BeamSplitText.tooLittle;
    if (_assetId != 0 && _beamAvailable < plan.fee) {
      return BeamSplitText.needBeam(plan.fee, _beamAvailable);
    }
    return null;
  }

  // ---------------------------------------------------------------- actions

  Future<void> _pickAsset() async {
    final coins = _coins;
    if (coins == null) return;
    final picked = await showBeamAssetPicker(
      context: context,
      assets: [
        for (final id in _choices)
          BeamHeldAsset(id, coins[id]?.availableTotal ?? BigInt.zero),
      ],
      names: _names,
      title: 'Which coins to split',
    );
    if (picked != null && mounted) {
      setState(() {
        _assetId = picked;
        _count = null;
        _problem = null;
      });
    }
  }

  Future<void> _review() async {
    if (_preparing) return;
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    BeamPreparedSplit? prepared;
    try {
      prepared = await _b.prepare(plan);
    } catch (e) {
      if (mounted) setState(() => _problem = _explain(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (prepared == null) return;
    if (!mounted) {
      prepared.discard();
      return;
    }
    final symbol = _symbol;
    final tx = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => BeamSplitConfirmView(
          backend: _b,
          prepared: prepared!,
          authorize: widget.authorize,
        ),
      ),
    );
    prepared.discard();
    if (!mounted) return;
    _checkBlocked();
    if (tx != null) {
      setState(() => _done = (count: plan.count, symbol: symbol));
    } else {
      unawaited(_load(quiet: true));
    }
  }

  static BeamProblem _explain(Object e) {
    final w = beamWalletExceptionFrom(e);
    final title = switch (w.problem) {
      BeamWalletProblem.walletBusy => 'Another payment is still open',
      BeamWalletProblem.scanningForCoins => 'Still looking for your coins',
      BeamWalletProblem.notSynced => 'Not up to date yet',
      BeamWalletProblem.insufficientFunds => 'Your coins changed',
      BeamWalletProblem.sendOutcomeUnknown => 'Not sure the split started',
      BeamWalletProblem.notOpen => 'Still connecting',
      _ => 'The coins were not split',
    };
    return BeamProblem(title, w.message);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final done = _done;
    if (done != null) return _doneScreen(context, done.count);
    return BeamSyncGate(
      sync: _b.sync,
      builder: (context, sync) {
        final plan = _plan;
        final issue = _fundsIssue;
        final blocked = _blocked;
        final ready =
            plan != null &&
            issue == null &&
            blocked == null &&
            sync.canSpend &&
            _coins != null;
        return BeamPageScaffold(
          title: BeamSplitText.title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _intro(context),
              const BeamGap(16),
              if (_loadProblem != null) ...[
                BeamNotice(
                  key: const ValueKey('split-load-problem'),
                  kind: BeamNoticeKind.danger,
                  title: _loadProblem!.title,
                  message: _loadProblem!.message,
                  actionLabel: 'Try again',
                  onAction: _load,
                ),
                const BeamGap(),
              ],
              if (_coins == null && _loadProblem == null)
                const BeamWorking('Reading your coins…'),
              if (_coins != null) ..._form(context, plan),
              if (_problem != null) ...[
                const BeamGap(),
                BeamNotice(
                  key: const ValueKey('split-problem'),
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
              BeamSyncNotice(sync: sync, what: 'Splitting'),
              if (sync.canSpend && blocked != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: BeamNotice(
                    key: const ValueKey('split-blocked'),
                    kind: BeamNoticeKind.info,
                    message: blocked,
                  ),
                ),
              BeamCtaBar(
                primaryKey: const ValueKey('split-cta'),
                label: plan == null
                    ? BeamSplitText.title
                    : BeamSplitText.cta(plan.count),
                busy: _preparing,
                busyLabel: 'Checking your coins…',
                onPressed: ready ? _review : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _intro(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          BeamSplitText.headline,
          key: const ValueKey('split-headline'),
          style: desktop
              ? STextStyles.desktopH3(context)
              : STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 6),
        Text(
          BeamSplitText.intro,
          style: desktop
              ? STextStyles.desktopTextExtraSmall(context).copyWith(
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .textSubtitle1,
                )
              : STextStyles.itemSubtitle(context),
        ),
      ],
    );
  }

  List<Widget> _form(BuildContext context, BeamSplitPlan? plan) {
    final coins = _summary;
    final symbol = _symbol;
    final many = _choices.length > 1;
    final advice = coins.advice;
    final adviceLine = BeamSplitText.advice(advice, symbol);
    final issue = _fundsIssue;
    final colors = Theme.of(context).extension<StackColors>()!;
    return [
      const BeamLabel('Now'),
      RoundedWhiteContainer(
        key: const ValueKey('split-asset'),
        onPressed: many ? _pickAsset : null,
        child: BeamAssetTitle(
          display: _names.display(_assetId),
          subtitle: BeamSplitText.now(coins, symbol),
          trailing: many
              ? Icon(Icons.expand_more_rounded, color: colors.textSubtitle1)
              : null,
        ),
      ),
      if (adviceLine != null) ...[
        const BeamGap(8),
        BeamNotice(
          key: const ValueKey('split-advice'),
          kind: advice.isNeeded ? BeamNoticeKind.warning : BeamNoticeKind.info,
          message: adviceLine,
        ),
      ] else if (coins.usable.length > 1 && plan != null) ...[
        const BeamGap(8),
        BeamNotice(
          key: const ValueKey('split-advice'),
          kind: BeamNoticeKind.info,
          message: BeamSplitText.spreadWell(coins.usable.length),
        ),
      ],
      const BeamGap(16),
      if (issue != null)
        BeamNotice(
          key: const ValueKey('split-funds'),
          kind: BeamNoticeKind.info,
          message: issue,
          // Never a dead end: more BEAM is one tap away.
          actionLabel: _b.addFunds == null ? null : 'Receive BEAM',
          onAction: _b.addFunds,
        ),
      if (plan != null) ...[
        if (issue != null) const BeamGap(16),
        const BeamLabel(BeamSplitText.countLabel),
        DexChoiceChips<int>(
          values: _counts,
          labelOf: (n) => '$n',
          selected: _chosen,
          keyOf: (n) => ValueKey('split-count-$n'),
          onSelected: (n) => setState(() {
            _count = n;
            _problem = null;
          }),
        ),
        const BeamGap(16),
        const BeamLabel('After'),
        BeamDetailCard(
          children: [
            BeamDetailRow(
              label: 'You will have',
              value: BeamSplitText.newCoins(plan, symbol),
              valueKey: const ValueKey('split-new-coins'),
            ),
            BeamDetailRow(
              label: 'Network fee',
              value: BeamSplitText.fee(plan),
              valueKey: const ValueKey('split-fee'),
            ),
            if (plan.change > BigInt.zero)
              BeamDetailRow(
                label: 'Stays as change',
                value: BeamUnits.withSymbol(plan.change, symbol),
                valueKey: const ValueKey('split-change'),
              ),
          ],
        ),
      ],
    ];
  }

  Widget _doneScreen(BuildContext context, int count) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    return BeamPageScaffold(
      title: BeamSplitText.title,
      body: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 64,
              color: colors.accentColorGreen,
            ),
            const BeamGap(16),
            Text(
              BeamSplitText.doneTitle(count),
              key: const ValueKey('split-done'),
              textAlign: TextAlign.center,
              style: desktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            const BeamGap(8),
            Text(
              BeamSplitText.doneMessage,
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
          ],
        ),
      ),
      bottom: BeamCtaBar(
        primaryKey: const ValueKey('split-done-cta'),
        label: 'Done',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
