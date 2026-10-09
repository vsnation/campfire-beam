/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: swap one Ethereum token for another on Uniswap, from this
//    wallet, directly on Uniswap's own contracts.
// 2. Primary CTA: the outcome, "Swap 0.01 ETH" ("Swap" until an amount is
//    typed); "Allow 1,000 WBEAM" comes first, once, for a token Uniswap
//    may not take yet.
// 3. Taps from app open: wallet → Swap (2), type an amount, "Swap 0.01
//    ETH" (3); then the review and Campfire's PIN.
//
// Exit-intent (§1.7):
// * A greyed-out button with no reason — every disabled state says why
//   above it (no amount, not enough of the token, not enough ETH for the
//   network fee, no pool, still pricing).
// * Waiting for a price — "Getting the best price…" while every Uniswap
//   pool is checked; the route that wins is named ("WBEAM → ETH · v4 ·
//   1%").
// * Fear of a bad price — the rate in plain words, what both sides are
//   worth, the price change from the swap (amber from 3%, red with a tick
//   box from 10%), and "you receive at least" under the price protection.
// * Fake tokens — anything not on Campfire's list carries a warning with
//   its address; a copy of a real ticker says "Not the real USDT".
// * Fees — the network fee in ETH and money before anything is signed.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/eth_rpc.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_quoter.dart';
import '../../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../../widgets/beam/dex/dex_amount_field.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import 'uniswap_approve_view.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';
import 'uniswap_pools_view.dart';
import 'uniswap_review_view.dart';
import 'uniswap_token_picker.dart';
import 'uniswap_widgets.dart';

/// From this price change the swap is shown in warning colours.
const double kUniImpactWarning = 0.03;

/// From this price change the user ticks a box before the button works.
const double kUniImpactBlock = 0.10;

/// Price protection choices, in hundredths of a percent.
const List<int> kUniSlippageChoices = [50, 100, 300, 500];

enum _Problem { noPool, tooSmall, failed, sameAsset }

typedef _Cta = ({VoidCallback? onPressed, String? reason});

class UniswapSwapView extends StatefulWidget {
  const UniswapSwapView({
    super.key,
    required this.deps,
    this.initialPay = UniToken.eth,
    this.initialReceive = kWbeamToken,
    this.embedded = false,
    this.onPairChanged,
    this.initialAmount,
    this.onPayWithOtherCoin,
    this.onQuoteChanged,
  });

  final UniswapDeps deps;
  final UniToken initialPay;
  final UniToken initialReceive;

  /// Told when the two tokens change (the desktop pools column follows).
  final void Function(UniToken pay, UniToken receive)? onPairChanged;

  /// An amount of [initialPay] to start with (ETH that just arrived from
  /// NEAR Intents).
  final BigInt? initialAmount;

  /// Opens NEAR Intents ("Pay with BTC, ZEC, LTC or another coin"); null
  /// hides the link.
  final VoidCallback? onPayWithOtherCoin;

  /// True inside the desktop view: the form without a page around it.
  final bool embedded;

  /// Told when the price shown changes (the desktop pools column marks
  /// the pools the swap uses).
  final void Function(UniQuote? quote)? onQuoteChanged;

  @override
  State<UniswapSwapView> createState() => _UniswapSwapViewState();
}

class _UniswapSwapViewState extends State<UniswapSwapView> {
  late UniToken _pay = widget.initialPay;
  late UniToken _receive = widget.initialReceive;
  final _amount = TextEditingController();
  final _receiveText = TextEditingController();
  UniAmountInput _input = UniAmountInput.empty;

  UniQuote? _quoteValue;
  UniQuote? get _quote => _quoteValue;
  set _quote(UniQuote? q) {
    if (identical(q, _quoteValue)) return;
    _quoteValue = q;
    final tell = widget.onQuoteChanged;
    if (tell != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_quoteValue, q)) tell(q);
      });
    }
  }

  bool _quoting = false;
  _Problem? _problem;
  String? _problemDetail;
  int _seq = 0;
  Timer? _debounce;
  UniFees? _fees;

  int _slippage = kUniSlippageChoices[1];
  bool _impactAck = false;
  bool _busy = false;
  String? _busyText;

  UniswapDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_rebuild);
    unawaited(_refresh());
    final start = widget.initialAmount;
    if (start != null && start > BigInt.zero) {
      _amount.text = UniFormat.plain(start, _pay.decimals);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onAmountChanged(_amount.text),
      );
    }
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

  Future<void> _refresh() async {
    unawaited(deps.refreshBalances({UniToken.eth, _pay, _receive}));
    try {
      final f = await deps.service.fees();
      if (mounted) setState(() => _fees = f);
    } catch (_) {
      // Shown as "network fee unknown" until the review measures it.
    }
  }

  // ------------------------------------------------------------------ input

  void _onAmountChanged(String text) {
    _debounce?.cancel();
    _seq++;
    setState(() {
      _input = UniFormat.parse(text, _pay);
      _quote = null;
      _problem = null;
      _impactAck = false;
      _receiveText.text = '';
      _quoting = _input.isPositive;
    });
    if (_input.isPositive) {
      _debounce = Timer(const Duration(milliseconds: 500), _requote);
    }
  }

  void _useMax() {
    var max = deps.balance(_pay);
    if (_pay.isEth) {
      // Leave the network fee in the wallet.
      final reserve = _gasReserve();
      max = max > reserve ? max - reserve : BigInt.zero;
    }
    _amount.text = UniFormat.plain(max, _pay.decimals);
    _onAmountChanged(_amount.text);
  }

  /// ETH to keep for the swap's network fee (twice the usual cost of a
  /// swap at today's fees, never less than 0.0005 ETH).
  BigInt _gasReserve() {
    final f = _fees;
    final floor =
        BigInt.from(10).pow(18) * BigInt.from(5) ~/ BigInt.from(10000);
    if (f == null) return floor;
    final v = BigInt.from(600000) * f.maxFeePerGas;
    return v > floor ? v : floor;
  }

  void _flip() {
    setState(() {
      final t = _pay;
      _pay = _receive;
      _receive = t;
    });
    unawaited(deps.refreshBalances({_pay, _receive}));
    widget.onPairChanged?.call(_pay, _receive);
    _onAmountChanged(_amount.text);
  }

  Future<void> _pickToken({required bool paySide}) async {
    final chosen = await showUniTokenPicker(
      context,
      deps: deps,
      title: paySide ? 'You pay with' : 'You receive',
      selected: paySide ? _pay : _receive,
      other: paySide ? _receive : _pay,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      if (paySide) {
        if (chosen.sameAsset(_receive)) _receive = _pay;
        _pay = chosen;
      } else {
        if (chosen.sameAsset(_pay)) _pay = _receive;
        _receive = chosen;
      }
    });
    unawaited(deps.refreshBalances({_pay, _receive}));
    widget.onPairChanged?.call(_pay, _receive);
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
    });
    try {
      final q = await deps.service.quote(
        tokenIn: _pay,
        tokenOut: _receive,
        amountIn: amount,
        owner: deps.signer.address,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _quote = q;
        _quoting = false;
        _receiveText.text = UniFormat.plain(q.amountOut, _receive.decimals);
      });
    } on UniswapNoRoute catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = switch (e.reason) {
          'sameAsset' => _Problem.sameAsset,
          'tooSmall' => _Problem.tooSmall,
          _ => _Problem.noPool,
        };
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = _Problem.failed;
        _problemDetail = e is EthRpcError ? e.message : null;
      });
    }
  }

  // ------------------------------------------------------------------- swap

  Future<void> _swapNow() async {
    final q = _quote;
    if (q == null || _busy) return;
    setState(() {
      _busy = true;
      _busyText = 'Checking what Uniswap may take…';
    });
    try {
      final approval = await deps.service.approvalFor(q, deps.signer.address);
      if (!mounted) return;
      if (approval.kind != UniApprovalKind.none) {
        setState(() => _busy = false);
        final ok = await UniswapApproveView.show(
          context,
          deps: deps,
          approval: approval,
        );
        if (ok != true || !mounted) return;
      }
      setState(() {
        _busy = true;
        _busyText = 'Checking the price again…';
      });
      final review = await deps.service.reviewSwap(
        quote: q,
        slippageBips: _slippage,
        owner: deps.signer.address,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final hash = await UniswapReviewView.show(
        context,
        deps: deps,
        review: review,
      );
      if (!mounted) return;
      if (hash != null) {
        _amount.clear();
        _onAmountChanged('');
        unawaited(deps.refreshBalances({UniToken.eth, _pay, _receive}));
      } else {
        // Back without swapping: the price is minutes old by now.
        unawaited(_requote());
      }
    } on UniRouteChanged catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _quote = e.quote;
        _receiveText.text = UniFormat.plain(
          e.quote.amountOut,
          _receive.decimals,
        );
      });
      _showRerouted();
    } on UniPriceMoved catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _quote = e.fresh;
        _receiveText.text = UniFormat.plain(
          e.fresh.amountOut,
          _receive.decimals,
        );
      });
      _showMoved(e.moved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = _Problem.failed;
        _problemDetail = e is EthRpcError ? e.message : null;
      });
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  void _showRerouted() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'The best-looking pool would not actually trade, so Campfire left '
          'it out. Here is the next best price; nothing was sent.',
        ),
      ),
    );
  }

  void _showMoved(double moved) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          'The price moved ${UniFormat.percent(moved)} since your quote, '
          'more than your ${UniFormat.percent(_slippage / 10000)} price '
          'protection. Here is the new price; nothing was sent.',
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ state

  _Cta _cta() {
    final paySym = _pay.symbol;
    if (_busy) return _off(_busyText ?? 'One moment…');
    if (_input.error != null) return _off(_input.error);
    final amount = _input.value;
    if (amount == null || amount == BigInt.zero) {
      return _off('Enter how much $paySym to swap.');
    }
    if (deps.hasBalance(_pay) && amount > deps.balance(_pay)) {
      return _off(
        'Not enough $paySym. You have '
        '${UniFormat.compact(deps.balance(_pay), _pay.decimals)} $paySym.',
      );
    }
    if (_problem != null) return _off(null);
    final q = _quote;
    if (_quoting || q == null) {
      return _off('Getting the best price from every Uniswap pool…');
    }
    if (deps.hasBalance(UniToken.eth)) {
      final need = (_pay.isEth ? amount : BigInt.zero) + _expectedFee(q);
      if (need > deps.balance(UniToken.eth)) {
        return _off(
          _pay.isEth
              ? 'Not enough ETH. You need about '
                    '${UniFormat.compact(need, 18)} ETH with the network fee.'
              : 'You need about ${UniFormat.compact(_expectedFee(q), 18)} '
                    'ETH for the network fee. You have '
                    '${UniFormat.compact(deps.balance(UniToken.eth), 18)} ETH.',
        );
      }
    }
    if ((q.priceImpact ?? 0) >= kUniImpactBlock && !_impactAck) {
      return _off('Tick the box to accept the price change.');
    }
    return (onPressed: _swapNow, reason: null);
  }

  BigInt _expectedFee(UniQuote q) {
    final f = _fees;
    if (f == null) return BigInt.zero;
    final gas = q.gasEstimate + (_pay.isEth ? BigInt.zero : kPermitGas);
    return gas * (f.baseFee + f.maxPriorityFeePerGas);
  }

  static _Cta _off(String? reason) => (onPressed: null, reason: reason);

  String get _ctaLabel {
    final amount = _input.value;
    if (amount == null || amount <= BigInt.zero) return 'Swap';
    return 'Swap ${UniFormat.exact(amount, _pay.decimals)} ${_pay.symbol}';
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    final bottom = DexPrimaryAction(
      deps: deps,
      buttonKey: const Key('uni-swap-cta'),
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
      title: 'Swap on Uniswap',
      body: body,
      bottom: bottom,
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: CustomTextButton(
              key: const Key('uni-open-pools'),
              text: 'Pools',
              onTap: _openPools,
            ),
          ),
        ),
      ],
    );
  }

  void _openPools() => unawaited(
    showDexPage<void>(
      context,
      deps,
      (_) => UniswapPoolsView(deps: deps, a: _pay, b: _receive, quote: _quote),
    ),
  );

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final labelStyle = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final q = _quote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Straight to Uniswap\'s own contracts, priced through your '
          'Ethereum node. No middleman.',
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        if (widget.onPayWithOtherCoin != null) ...[
          const SizedBox(height: 10),
          UniPayWithOtherCoinCard(onTap: widget.onPayWithOtherCoin!),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text('You pay', style: labelStyle)),
            Text(
              deps.hasBalance(_pay)
                  ? 'Balance ${UniFormat.compact(deps.balance(_pay), _pay.decimals)} ${_pay.symbol}'
                  : 'Balance …',
              key: const Key('uni-pay-balance'),
              style: STextStyles.label(context),
            ),
            const SizedBox(width: 8),
            CustomTextButton(
              key: const Key('uni-max'),
              text: 'Max',
              onTap: _useMax,
            ),
          ],
        ),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('uni-pay-amount'),
          assetButtonKey: const Key('uni-pay-token'),
          controller: _amount,
          asset: null,
          assetLabel: UniTokenChip(token: _pay, deps: deps),
          error: _input.error != null,
          onChanged: _onAmountChanged,
          onAssetTap: () => _pickToken(paySide: true),
        ),
        DexWorth(
          _input.isPositive ? deps.worth(_pay, _input.value!) : null,
          textKey: const Key('uni-pay-worth'),
        ),
        UniUnverifiedWarning(token: _pay, deps: deps),
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
          fieldKey: const Key('uni-receive-amount'),
          assetButtonKey: const Key('uni-receive-token'),
          controller: _receiveText,
          asset: null,
          assetLabel: UniTokenChip(token: _receive, deps: deps),
          readOnly: true,
          hint: _quoting ? '…' : '0',
          onAssetTap: () => _pickToken(paySide: false),
        ),
        DexWorth(
          q == null ? null : deps.worth(_receive, q.amountOut),
          textKey: const Key('uni-receive-worth'),
        ),
        UniUnverifiedWarning(token: _receive, deps: deps),
        if (_problem != null) ...[
          const SizedBox(height: 12),
          _problemNotice(context),
        ],
        if (q != null) ...[
          // Above the details, so it is on a phone screen without
          // scrolling: the user sees it before the button.
          if ((q.priceImpact ?? 0) >= kUniImpactWarning) ...[
            const SizedBox(height: 12),
            _impactNotice(context, q),
          ],
          const SizedBox(height: 12),
          _details(context, q),
        ],
      ],
    );
  }

  Widget _details(BuildContext context, UniQuote q) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final impact = q.priceImpact;
    final fee = _expectedFee(q);
    final min = q.minimumOut(_slippage);
    return DexCard(
      child: Column(
        children: [
          DexDetailRow(
            label: 'Rate',
            valueKey: const Key('uni-rate'),
            value: UniFormat.rate(q),
          ),
          DexDetailRow(
            label: 'Route',
            valueKey: const Key('uni-route'),
            value: uniRouteText(q, deps),
            note: uniRouteNote(q, deps),
            noteKey: const Key('uni-route-pools'),
            onTap: _openPools,
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.textSubtitle1,
            ),
          ),
          DexDetailRow(
            label: 'Price change from your swap',
            valueKey: const Key('uni-impact'),
            value: impact == null ? 'Unknown' : UniFormat.percent(impact),
            valueColor: (impact ?? 0) >= kUniImpactWarning
                ? colors.accentColorRed
                : null,
          ),
          DexDetailRow(
            key: const Key('uni-protection'),
            label: 'Price protection',
            valueKey: const Key('uni-protection-value'),
            value: UniFormat.percent(_slippage / 10000),
            note:
                'At least ${UniFormat.compact(min, _receive.decimals)} '
                '${_receive.symbol}',
            noteKey: const Key('uni-minimum'),
            onTap: _pickSlippage,
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: colors.textSubtitle1,
            ),
          ),
          DexDetailRow(
            label: 'Network fee',
            valueKey: const Key('uni-network-fee'),
            value: _fees == null
                ? 'Measured on the next screen'
                : '≈ ${UniFormat.compact(fee, 18)} ETH',
            note: _fees == null ? null : deps.worth(UniToken.eth, fee),
          ),
        ],
      ),
    );
  }

  Widget _impactNotice(BuildContext context, UniQuote q) {
    final impact = q.priceImpact!;
    final block = impact >= kUniImpactBlock;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DexNotice(
          key: const Key('uni-impact-warning'),
          kind: block ? DexNoticeKind.error : DexNoticeKind.warning,
          title: 'This swap moves the price ${UniFormat.percent(impact)}',
          detail:
              'The pools are small for this amount, so you get noticeably '
              'less than the current rate. A smaller amount gets a better '
              'price.',
        ),
        if (block)
          CheckboxListTile(
            key: const Key('uni-impact-ack'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _impactAck,
            onChanged: (v) => setState(() => _impactAck = v ?? false),
            title: Text(
              'I accept getting ${UniFormat.percent(impact)} less',
              style: STextStyles.smallMed14(context),
            ),
          ),
      ],
    );
  }

  Widget _problemNotice(BuildContext context) {
    final pay = _pay.symbol;
    final receive = _receive.symbol;
    switch (_problem!) {
      case _Problem.sameAsset:
        return DexNotice(
          key: const Key('uni-same-asset'),
          title: '$pay and $receive are the same coin',
          detail: 'Pick something else to receive.',
        );
      case _Problem.noPool:
        return DexNotice(
          key: const Key('uni-no-pool'),
          sticker: BeamMoments.trading,
          title: 'No Uniswap pool trades $pay for $receive',
          detail:
              'Campfire looked at every Uniswap pool between them, and at '
              'routes through ETH, USDC, USDT, DAI, WBTC and WBEAM. Pick '
              'another token.',
        );
      case _Problem.tooSmall:
        return DexNotice(
          key: const Key('uni-too-small'),
          title: 'Too small to get any $receive',
          detail: 'After the pool fee nothing is left. Try a larger amount.',
        );
      case _Problem.failed:
        return DexNotice(
          key: const Key('uni-failed'),
          sticker: BeamMoments.somethingWentWrong,
          kind: DexNoticeKind.error,
          title: "Couldn't reach Uniswap",
          detail:
              'Your Ethereum node did not answer'
              '${_problemDetail == null ? '' : ' ("$_problemDetail")'}. '
              'This is not something you did, and nothing was sent. You '
              'can pick another node in the wallet\'s network settings.',
          actionLabel: 'Try again',
          onAction: _requote,
        );
    }
  }

  Future<void> _pickSlippage() async {
    final chosen = await showDexPage<int>(
      context,
      deps,
      (_) => _SlippagePicker(deps: deps, selected: _slippage),
    );
    if (chosen != null && mounted) setState(() => _slippage = chosen);
  }
}

class _SlippagePicker extends StatelessWidget {
  const _SlippagePicker({required this.deps, required this.selected});

  final UniswapDeps deps;
  final int selected;

  String _label(int bips) => switch (bips) {
    50 => '0.5% — strict; fails more often when others trade',
    100 => '1% — a good default',
    300 => '3% — for small pools that move a lot',
    _ => '${UniFormat.percent(bips / 10000)} — only for very thin pools',
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DexPage(
      deps: deps,
      title: 'Price protection',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'If the price moves against you by more than this before your '
            'swap is mined, Ethereum cancels the swap and you keep your '
            'coins (only the network fee is spent). Also called slippage.',
            style: STextStyles.smallMed14(context),
          ),
          const SizedBox(height: 12),
          for (final b in kUniSlippageChoices)
            InkWell(
              key: Key('uni-slippage-$b'),
              onTap: () => Navigator.of(context).pop(b),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(
                      b == selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: b == selected
                          ? colors.radioButtonIconEnabled
                          : colors.radioButtonIconBorder,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _label(b),
                        style: STextStyles.smallMed14(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
