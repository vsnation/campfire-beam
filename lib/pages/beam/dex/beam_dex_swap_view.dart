/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: swap one asset for another.
// 2. Primary CTA: the outcome, "Swap 0.02 BEAM" ("Swap" until an amount is
//    typed).
// 3. Taps from app open: wallet → Swap (2), type an amount, "Swap 0.02
//    BEAM" (3); then the confirmation screen and Campfire's PIN.
//
// Exit-intent (§1.7) — what could make an impatient person leave:
// * A greyed-out button with no reason — every disabled state says why
//   right above the button (not synced, not enough funds incl. the fee,
//   no pool, amount too small).
// * Waiting for a price — the quote starts 500 ms after typing stops and
//   says "Getting the best price…" meanwhile.
// * Fear of a bad price — the rate is in plain words ("1 BEAM ≈ 8.04
//   FOMO"), both amounts say what they are worth in the user's currency,
//   the price change from the swap turns amber at 3%, and price
//   protection is on by default.
// * A fee that eats a small swap — when the 0.011 BEAM network fee is a
//   quarter or more of what is swapped, a warning says so with the numbers.
// * Unknown assets that copy a real one — unverified assets carry their
//   #id and a "Not the verified …" warning.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_quotes.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_service.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../widgets/beam/dex/dex_amount_field.dart';
import '../../../widgets/beam/dex/dex_asset_icon.dart';
import '../../../widgets/beam/dex/dex_asset_picker.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/beam/dex/dex_format.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import 'beam_dex_confirm_view.dart';
import 'beam_dex_create_pool_view.dart';
import 'beam_dex_pool_detail_view.dart';
import 'beam_dex_pools_view.dart';

/// The asset a new swap receives when the caller names none: bETH (asset
/// 36, the Beam Bridge's wrapped ETH), so the DEX opens on BEAM → bETH
/// (owner, 2026-10-07). BEAM's DEX has a funded BEAM/bETH pool.
const kDexDefaultReceiveAsset = 36;

/// Above this price change the swap is shown in warning colours.
final kDexPriceImpactWarning = BeamRatio(BigInt.from(3), BigInt.from(100));

/// From this share of the swapped value, the network fee gets a warning:
/// 0.011 BEAM on a 0.02 BEAM swap is 55%.
final kDexFeeShareWarning = BeamRatio(BigInt.one, BigInt.from(4));

/// The protections offered. 1% is BEAM's own limit: the wallet core
/// rebuilds a swap whose pool changed before it was mined and refuses the
/// rebuild if it receives more than 1% less
/// (`wallet/core/contract_transaction.cpp` `IsSpendWithinLimitsUns`), so
/// only stricter limits make sense here.
final kDexProtections = [
  BeamRatio(BigInt.one, BigInt.from(100)),
  BeamRatio(BigInt.one, BigInt.from(200)),
  BeamRatio(BigInt.one, BigInt.from(1000)),
];

enum _Problem {
  noPool,
  poolEmpty,
  tooSmall,
  refused,
  failed,
  priceMoved,
  buildFailed,
}

/// Swap one asset for another through the BEAM AMM.
class BeamDexSwapView extends StatefulWidget {
  const BeamDexSwapView({
    super.key,
    required this.deps,
    this.initialPayAsset = 0,
    this.initialReceiveAsset,
    this.embedded = false,
    this.onOpenPools,
  });

  final BeamDexDeps deps;
  final int initialPayAsset;
  final int? initialReceiveAsset;

  /// True inside the desktop DEX view: the form without a page around it.
  final bool embedded;

  /// Opens the pools list; null pushes [BeamDexPoolsView].
  final VoidCallback? onOpenPools;

  @override
  State<BeamDexSwapView> createState() => _BeamDexSwapViewState();
}

class _BeamDexSwapViewState extends State<BeamDexSwapView> {
  late int _pay;
  late int _receive;
  final _amount = TextEditingController();
  final _receiveText = TextEditingController();
  DexAmountInput _input = DexAmountInput.empty;

  BeamSwapQuote? _quote;
  bool _quoting = false;
  _Problem? _problem;
  String? _problemDetail;
  BeamRatio? _moved;
  int _seq = 0;
  Timer? _debounce;

  BeamRatio _protection = kDexProtections.first;
  bool _preparing = false;

  BeamDexDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    _pay = widget.initialPayAsset;
    _receive =
        widget.initialReceiveAsset ??
        (_pay == kDexDefaultReceiveAsset ? 0 : kDexDefaultReceiveAsset);
    if (_receive == _pay) _receive = _pay == 0 ? kDexDefaultReceiveAsset : 0;
    deps.changes.addListener(_rebuild);
    unawaited(deps.pools.ensureLoaded());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    deps.changes.removeListener(_rebuild);
    _amount.dispose();
    _receiveText.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  String _sym(int asset) => deps.display(asset).symbol;

  // ------------------------------------------------------------------ input

  void _onAmountChanged(String text) {
    _debounce?.cancel();
    _seq++;
    setState(() {
      _input = DexFormat.parse(text);
      _quote = null;
      _problem = null;
      _moved = null;
      _receiveText.text = '';
      _quoting = _input.isPositive;
    });
    if (_input.isPositive) {
      _debounce = Timer(const Duration(milliseconds: 500), _requote);
    }
  }

  void _setAmount(BigInt v) {
    _amount.text = DexFormat.plain(v);
    _onAmountChanged(_amount.text);
  }

  void _useMax() {
    final have = deps.available(_pay);
    // BEAM pays its own network fee; leave it in the wallet.
    final fee = _pay == 0 ? kDexCallFee : BigInt.zero;
    final max = have - fee;
    _setAmount(max > BigInt.zero ? max : BigInt.zero);
  }

  void _flip() {
    setState(() {
      final t = _pay;
      _pay = _receive;
      _receive = t;
    });
    _onAmountChanged(_amount.text);
  }

  Future<void> _pickAsset({required bool paySide}) async {
    final chosen = await showDexAssetPicker(
      context,
      deps: deps,
      title: paySide ? 'You pay with' : 'You receive',
      assets: dexTradableAssets(deps),
      selected: paySide ? _pay : _receive,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (paySide) {
        if (chosen == _receive) _receive = _pay;
        _pay = chosen;
      } else {
        if (chosen == _pay) _pay = _receive;
        _receive = chosen;
      }
    });
    _onAmountChanged(_amount.text);
  }

  // ------------------------------------------------------------------ quote

  Future<void> _requote() async {
    final amount = _input.value;
    if (amount == null || amount <= BigInt.zero) return;
    final seq = ++_seq;
    setState(() {
      _quoting = true;
      _problem = null;
      _moved = null;
    });
    try {
      await deps.pools.ensureLoaded();
      final pools = deps.pools.all;
      if (pools == null) {
        throw deps.pools.error ?? StateError('pools not loaded');
      }
      final q = await deps.dex.quote(
        payAsset: _pay,
        payAmount: amount,
        receiveAsset: _receive,
        pools: pools,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _quote = q;
        _quoting = false;
        _receiveText.text = DexFormat.plain(q.receive);
      });
    } on BeamDexException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = switch (e.code) {
          BeamDexErrorCode.noPool => _Problem.noPool,
          BeamDexErrorCode.poolEmpty => _Problem.poolEmpty,
          BeamDexErrorCode.amountTooSmall => _Problem.tooSmall,
          _ => _Problem.refused,
        };
        _problemDetail = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = _Problem.failed;
      });
    }
  }

  // ------------------------------------------------------------------- swap

  Future<void> _swapNow() async {
    final q = _quote;
    if (q == null || _preparing) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    final BeamPreparedDexCall prepared;
    try {
      prepared = await deps.dex.prepareSwap(q);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _problem = _Problem.buildFailed;
      });
      return;
    }
    if (!mounted) return;
    final got = prepared.receives[q.receiveAsset] ?? BigInt.zero;
    final moved = got < q.receive
        ? BeamRatio(q.receive - got, q.receive)
        : BeamRatio.zero;
    if (moved > _protection) {
      setState(() {
        _preparing = false;
        _problem = _Problem.priceMoved;
        _moved = moved;
      });
      return;
    }
    setState(() => _preparing = false);
    final txId = await BeamDexConfirmView.show(
      context,
      deps: deps,
      prepared: prepared,
      priceMoved: moved,
    );
    if (!mounted) return;
    if (txId != null) {
      _amount.clear();
      _onAmountChanged('');
    }
  }

  // ------------------------------------------------------------------ state

  ({VoidCallback? onPressed, String? reason}) _cta() {
    final paySym = _sym(_pay);
    if (_preparing) return (onPressed: null, reason: 'Building your swap…');
    if (!deps.canSpend) {
      return (
        onPressed: null,
        reason: 'Swaps are paused until the wallet is up to date.',
      );
    }
    if (_input.error != null) return (onPressed: null, reason: _input.error);
    final amount = _input.value;
    if (amount == null || amount == BigInt.zero) {
      return (onPressed: null, reason: 'Enter how much $paySym to swap.');
    }
    final have = deps.available(_pay);
    if (amount > have) {
      return (
        onPressed: null,
        reason:
            'Not enough $paySym. You have ${DexFormat.exact(have)} '
            '$paySym.',
      );
    }
    if (_problem != null) return (onPressed: null, reason: null);
    final q = _quote;
    if (_quoting || q == null) {
      return (onPressed: null, reason: 'Getting the best price…');
    }
    final fee = q.networkFee;
    final beamOut =
        (_pay == 0 ? q.pay : BigInt.zero) +
        fee -
        (_receive == 0 ? q.receive : BigInt.zero);
    final beam = deps.available(0);
    if (beamOut > beam) {
      return (
        onPressed: null,
        reason: _pay == 0
            ? 'Not enough BEAM. You need ${DexFormat.exact(q.pay + fee)} '
                  'BEAM, including the ${DexFormat.exact(fee)} BEAM network '
                  'fee.'
            : 'You need ${DexFormat.exact(fee)} BEAM for the network fee. '
                  'You have ${DexFormat.exact(beam)} BEAM.',
      );
    }
    return (onPressed: _swapNow, reason: null);
  }

  // ------------------------------------------------------------------ build

  /// The outcome ("Swap 0.02 BEAM") once an amount is typed, as the send
  /// form does; the confirmation still comes before anything leaves.
  String get _ctaLabel {
    final amount = _input.value;
    if (amount == null || amount <= BigInt.zero) return 'Swap';
    return 'Swap ${DexFormat.exact(amount)} ${deps.assetLabel(_pay)}';
  }

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    final bottom = DexPrimaryAction(
      deps: deps,
      buttonKey: const Key('dex-swap-cta'),
      label: _ctaLabel,
      reason: cta.reason,
      onPressed: cta.onPressed,
    );
    final body = _form(context);
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [body, const SizedBox(height: 16), bottom],
      );
    }
    return DexPage(
      deps: deps,
      title: 'Swap',
      body: body,
      bottom: bottom,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: CustomTextButton(
              key: const Key('dex-open-pools'),
              text: 'Pools',
              onTap: _openPools,
            ),
          ),
        ),
      ],
    );
  }

  void _openPools() {
    final open = widget.onOpenPools;
    if (open != null) return open();
    unawaited(
      showDexPage<void>(context, deps, (_) => BeamDexPoolsView(deps: deps)),
    );
  }

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final labelStyle = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final have = deps.available(_pay);
    final q = _quote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        DexSyncBanner(deps: deps),
        Row(
          children: [
            Expanded(child: Text('You pay', style: labelStyle)),
            Text(
              'Balance ${DexFormat.compact(have)} ${_sym(_pay)}',
              key: const Key('dex-pay-balance'),
              style: STextStyles.label(context),
            ),
            const SizedBox(width: 8),
            CustomTextButton(
              key: const Key('dex-max'),
              text: 'Max',
              onTap: _useMax,
            ),
          ],
        ),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('dex-pay-amount'),
          assetButtonKey: const Key('dex-pay-asset'),
          controller: _amount,
          asset: deps.display(_pay),
          error: _input.error != null,
          onChanged: _onAmountChanged,
          onAssetTap: () => _pickAsset(paySide: true),
        ),
        DexWorth(
          deps.worth(_pay, _input.value ?? BigInt.zero),
          textKey: const Key('dex-pay-worth'),
        ),
        if (deps.display(_pay).impersonates != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: DexImpersonationWarning(asset: deps.display(_pay)),
          ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Text('You receive', style: labelStyle)),
            DexFlipButton(onTap: _flip),
          ],
        ),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('dex-receive-amount'),
          assetButtonKey: const Key('dex-receive-asset'),
          controller: _receiveText,
          asset: deps.display(_receive),
          readOnly: true,
          hint: _quoting ? '…' : '0',
          onAssetTap: () => _pickAsset(paySide: false),
        ),
        DexWorth(
          q == null ? null : deps.worth(_receive, q.receive),
          textKey: const Key('dex-receive-worth'),
        ),
        if (deps.display(_receive).impersonates != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: DexImpersonationWarning(asset: deps.display(_receive)),
          ),
        if (_problem != null) ...[
          const SizedBox(height: 12),
          _problemNotice(context),
        ],
        if (q != null) ...[
          // Above the details, so it is on a phone screen without
          // scrolling: the user should see it before the button.
          if (_feeWarning(q) case final warning?) ...[
            const SizedBox(height: 12),
            warning,
          ],
          const SizedBox(height: 12),
          _details(context, q),
          if (q.priceImpact >= kDexPriceImpactWarning) ...[
            const SizedBox(height: 12),
            DexNotice(
              key: const Key('dex-impact-warning'),
              kind: DexNoticeKind.warning,
              title:
                  'This swap moves the price '
                  '${DexFormat.percent(q.priceImpact)}',
              detail:
                  'The pool is small for this amount, so you get noticeably '
                  'less than the current rate. A smaller amount gets a '
                  'better price.',
            ),
          ],
        ],
      ],
    );
  }

  Widget _details(BuildContext context, BeamSwapQuote q) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final paySym = _sym(q.payAsset);
    final receiveSym = _sym(q.receiveAsset);
    final impactHigh = q.priceImpact >= kDexPriceImpactWarning;
    return DexCard(
      child: Column(
        children: [
          DexDetailRow(
            label: 'Rate',
            valueKey: const Key('dex-rate'),
            value:
                '1 $paySym ≈ ${DexFormat.number(q.effectiveRate)} '
                '$receiveSym',
          ),
          DexDetailRow(
            label: 'Price change from your swap',
            valueKey: const Key('dex-impact'),
            value: DexFormat.percent(q.priceImpact),
            valueColor: impactHigh ? colors.accentColorRed : null,
          ),
          DexDetailRow(
            label: 'Pool fee (${q.kind.feePercent})',
            valueKey: const Key('dex-pool-fee'),
            value: '${DexFormat.exact(q.fee)} $paySym',
          ),
          DexDetailRow(
            label: 'Network fee',
            valueKey: const Key('dex-network-fee'),
            value: '≈ ${DexFormat.exact(q.networkFee)} BEAM',
            note: deps.worthOfBeam(q.networkFee),
            noteKey: const Key('dex-network-fee-worth'),
          ),
          DexDetailRow(
            key: const Key('dex-protection'),
            label: 'Price protection',
            valueKey: const Key('dex-protection-value'),
            value: DexFormat.percent(_protection),
            onTap: _pickProtection,
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.textSubtitle1,
            ),
          ),
        ],
      ),
    );
  }

  /// A warning when the network fee is [kDexFeeShareWarning] or more of
  /// what is swapped, both valued in BEAM (the paid side, or the received
  /// side when only that has a price). Null below that, or when neither
  /// side can be valued.
  Widget? _feeWarning(BeamSwapQuote q) {
    final value =
        deps.valueInBeam(q.payAsset, q.pay) ??
        deps.valueInBeam(q.receiveAsset, q.receive);
    if (value == null || value <= BigInt.zero) return null;
    final share = BeamRatio(q.networkFee, value);
    if (share < kDexFeeShareWarning) return null;
    final percent = DexFormat.percent(share);
    final String title;
    if (share > BeamRatio.one) {
      title = 'The network fee is more than what you swap';
    } else if (share > BeamRatio(BigInt.one, BigInt.two)) {
      title = 'The network fee is more than half of what you swap';
    } else {
      title = 'The network fee is $percent of what you swap';
    }
    final swapped = q.payAsset == 0
        ? 'the ${DexFormat.exact(q.pay)} BEAM you swap'
        : 'what you swap (worth about ${DexFormat.compact(value)} BEAM)';
    return DexNotice(
      key: const Key('dex-fee-warning'),
      kind: DexNoticeKind.warning,
      title: title,
      detail:
          'Every swap costs ${DexFormat.exact(q.networkFee)} BEAM in network '
          'fees, whatever the amount. Here that is $percent of $swapped. '
          'A larger swap pays the same fee.',
    );
  }

  Widget _problemNotice(BuildContext context) {
    final pay = _sym(_pay);
    final receive = _sym(_receive);
    switch (_problem!) {
      case _Problem.noPool:
        final viaBeam =
            _pay != 0 &&
            _receive != 0 &&
            dexPoolsForPair(deps, _pay, 0).isNotEmpty &&
            dexPoolsForPair(deps, 0, _receive).isNotEmpty;
        return DexNotice(
          key: const Key('dex-no-pool'),
          sticker: BeamMoments.trading,
          title: 'No pool trades $pay for $receive yet',
          detail: viaBeam
              ? 'Swaps on BEAM go through pools. Both trade against BEAM: '
                    'swap $pay for BEAM first, then BEAM for $receive.'
              : 'Swaps on BEAM go through pools. Pick another asset, or '
                    'create this pool and earn its fees.',
          actionLabel: viaBeam ? 'Swap $pay for BEAM' : null,
          onAction: viaBeam ? _receiveBeam : null,
          secondaryLabel: 'Create a pool',
          onSecondary: _createPool,
        );
      case _Problem.poolEmpty:
        final pools = deps.pools.all
            ?.where((p) => p.pairs(_pay, _receive))
            .toList();
        return DexNotice(
          key: const Key('dex-pool-empty'),
          sticker: BeamMoments.trading,
          title: 'The $pay/$receive pool is empty',
          detail:
              'Nobody has added coins to it yet, so it cannot swap. '
              'Add the first coins and set its price.',
          actionLabel: pools == null || pools.isEmpty ? null : 'Add coins',
          onAction: pools == null || pools.isEmpty
              ? null
              : () => _openPool(pools.first),
        );
      case _Problem.tooSmall:
        return DexNotice(
          key: const Key('dex-too-small'),
          title: 'Too small to get any $receive',
          detail:
              'After the pool fee nothing is left to swap. Try a larger '
              'amount.',
        );
      case _Problem.refused:
        return DexNotice(
          key: const Key('dex-refused'),
          sticker: BeamMoments.somethingWentWrong,
          kind: DexNoticeKind.error,
          title: 'The DEX would not price this swap',
          detail:
              'It said: "${_problemDetail ?? 'unknown reason'}". '
              'Nothing was sent.',
          actionLabel: 'Try again',
          onAction: _requote,
        );
      case _Problem.failed:
        return DexNotice(
          key: const Key('dex-quote-failed'),
          sticker: BeamMoments.somethingWentWrong,
          kind: DexNoticeKind.error,
          title: "Couldn't get a price",
          detail:
              "The wallet didn't answer. This is not something you "
              'did, and nothing was sent.',
          actionLabel: 'Try again',
          onAction: _requote,
        );
      case _Problem.priceMoved:
        return DexNotice(
          key: const Key('dex-price-moved'),
          kind: DexNoticeKind.warning,
          title:
              'The price moved ${DexFormat.percent(_moved!)} since your '
              'quote',
          detail:
              'That is more than your '
              '${DexFormat.percent(_protection)} price protection, so '
              'nothing was sent.',
          actionLabel: 'Get a new price',
          onAction: _requote,
        );
      case _Problem.buildFailed:
        return DexNotice(
          key: const Key('dex-build-failed'),
          sticker: BeamMoments.somethingWentWrong,
          kind: DexNoticeKind.error,
          title: "Couldn't build the swap",
          detail:
              "The wallet didn't answer or refused the swap. Nothing "
              'was sent.',
          actionLabel: 'Try again',
          onAction: _requote,
        );
    }
  }

  void _receiveBeam() {
    setState(() => _receive = 0);
    _onAmountChanged(_amount.text);
  }

  void _createPool() {
    unawaited(
      showDexPage<void>(
        context,
        deps,
        (_) => BeamDexCreatePoolView(deps: deps, aidA: _pay, aidB: _receive),
      ),
    );
  }

  void _openPool(BeamPool pool) {
    unawaited(
      showDexPage<void>(
        context,
        deps,
        (_) => BeamDexPoolDetailView(deps: deps, pool: pool),
      ),
    );
  }

  Future<void> _pickProtection() async {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget picker(BuildContext ctx) =>
        _ProtectionPicker(deps: deps, selected: _protection);
    final BeamRatio? chosen;
    if (deps.desktop) {
      chosen = await showDexPage<BeamRatio>(context, deps, picker);
    } else {
      chosen = await showModalBottomSheet<BeamRatio>(
        context: context,
        backgroundColor: colors.popupBG,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: picker,
      );
    }
    if (chosen != null && mounted) setState(() => _protection = chosen!);
  }
}

class _ProtectionPicker extends StatelessWidget {
  const _ProtectionPicker({required this.deps, required this.selected});

  final BeamDexDeps deps;
  final BeamRatio selected;

  String _label(BeamRatio r) {
    if (r == kDexProtections.first) return '1% — the most BEAM allows';
    if (r == kDexProtections.last) {
      return '0.1% — strict; fails more often when others trade';
    }
    return DexFormat.percent(r);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'If the price moves against you by more than this before your '
          'swap is built, Campfire stops and shows you the new price. '
          'Nothing is sent.',
          style: STextStyles.smallMed14(context),
        ),
        const SizedBox(height: 8),
        Text(
          'After you confirm, BEAM itself never accepts a result more than '
          '1% worse: if someone trades first, it redoes your swap within '
          '1% or cancels it. (Also called slippage tolerance.)',
          style: STextStyles.smallMed12(context),
        ),
        const SizedBox(height: 12),
        for (final r in kDexProtections)
          InkWell(
            key: Key('dex-protection-${r.denominator}'),
            onTap: () => Navigator.of(context).pop(r),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Icon(
                    r == selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: r == selected
                        ? colors.radioButtonIconEnabled
                        : colors.radioButtonIconBorder,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _label(r),
                      style: STextStyles.smallMed14(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    if (deps.desktop) {
      return DexPage(deps: deps, title: 'Price protection', body: body);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Price protection', style: STextStyles.pageTitleH2(context)),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}
