/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: pay with a coin from another chain, get BEAM in this wallet.
// 2. Primary CTA: "Get a BTC deposit address" (the ticker follows the
//    coin). Paying happens on the next screen, from any wallet.
// 3. Taps from app open: BEAM wallet → Buy (1) → amount (and a refund
//    address, pre-filled when Campfire has one) → the button (2).
//
// Exit-intent:
// * "What do I get?" — about how much BEAM, as buybeam.my prices it, in
//   which wallet, and how long it usually takes, before any address
//   exists.
// * "Is there a minimum?" — said up front ("Smallest buy right now: about
//   $1,000"), and when an amount is under it, the amount that is not, one
//   tap away.
// * "Who has my money?" — buybeam.my is named; the BEAM goes to a new
//   address of this wallet that Campfire makes itself; refunds go to the
//   user's own address on the coin's chain.
// * "It doesn't work" — every refusal says what happened, that nothing was
//   sent, and the one thing that fixes it.
// * "I wanted WBEAM" — one link at the bottom.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../widgets/beam/dex/dex_amount_field.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/send/beam_send_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import 'buy_beam_coin_picker.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_order_view.dart';
import 'buy_beam_orders_view.dart';
import 'buy_beam_routes.dart';
import 'buy_beam_widgets.dart';
import 'buy_beam_words.dart';

/// The coin the form starts with: BTC, on Bitcoin.
bool isBuyBeamDefaultCoin(BuyBeamAsset a) =>
    a.symbol == 'BTC' &&
    a.isNative &&
    (a.blockchain == 'btc' || a.blockchain == 'bitcoin');

final _evmAddress = RegExp(r'^0x[0-9a-fA-F]{40}$');

typedef _Cta = ({VoidCallback? onPressed, String? reason});

class BuyBeamView extends ConsumerStatefulWidget {
  const BuyBeamView({super.key, required this.deps});

  final BuyBeamDeps deps;

  /// Opens the form: a page on a phone, a dialog on desktop.
  static Future<void> show(BuildContext context, BuyBeamDeps deps) =>
      showBuyBeamPage<void>(context, deps, (_) => BuyBeamView(deps: deps));

  @override
  ConsumerState<BuyBeamView> createState() => _BuyBeamViewState();
}

class _BuyBeamViewState extends ConsumerState<BuyBeamView> {
  List<BuyBeamAsset>? _assets;
  bool _assetsFailed = false;
  BuyBeamAsset? _coin;
  final _amount = TextEditingController();
  final _refund = TextEditingController();
  final _amountFocus = FocusNode();
  final _refundFocus = FocusNode();
  BuyBeamAmount? _value;
  String? _amountError;

  /// The refund address is the one Campfire filled in.
  String? _prefilled;
  bool _busy = false;
  BuyBeamError? _orderError;
  String? _walletProblem;

  BuyBeamDeps get deps => widget.deps;
  BuyBeamController get c => deps.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    c.cancelQuote();
    unawaited(c.resumeAll());
    unawaited(c.refreshLimits());
    unawaited(_load());
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    c.cancelQuote();
    _amount.dispose();
    _refund.dispose();
    _amountFocus.dispose();
    _refundFocus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool refresh = false}) async {
    try {
      final list = await c.assets(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _assets = list;
        _assetsFailed = false;
      });
      if (_coin == null && list.isNotEmpty) {
        final btc = list.where(isBuyBeamDefaultCoin);
        await _setCoin(btc.isEmpty ? list.first : btc.first);
      }
    } catch (_) {
      if (mounted) setState(() => _assetsFailed = true);
    }
  }

  Future<void> _setCoin(BuyBeamAsset coin) async {
    final previous = _coin;
    setState(() => _coin = coin);
    if (previous?.blockchain != coin.blockchain) {
      // A refund address only works on its own chain.
      if (_refund.text.trim().isEmpty || _refund.text == _prefilled) {
        _refund.clear();
        _prefilled = null;
      }
      final mine = await deps.refundAddressFor?.call(coin);
      if (mounted && mine != null && _refund.text.trim().isEmpty) {
        _refund.text = mine;
        _prefilled = mine;
      }
    }
    _changed();
  }

  Future<void> _pickCoin() async {
    final chosen = await showBuyBeamCoinPicker(context, deps: deps);
    if (chosen == null || !mounted) return;
    await _setCoin(chosen);
  }

  String? get _refundError {
    final coin = _coin;
    final r = _refund.text.trim();
    if (coin == null || r.isEmpty || !coin.isEvm) return null;
    if (_evmAddress.hasMatch(r)) return null;
    return '${coin.chainName} addresses start with 0x and have 42 '
        'characters.';
  }

  void _changed() {
    final coin = _coin;
    final parsed = coin == null
        ? (amount: null, error: null)
        : BuyBeamAmount.parse(_amount.text, decimals: coin.decimals);
    setState(() {
      _value = parsed.amount;
      _amountError = parsed.error;
      _orderError = null;
      _walletProblem = null;
    });
    final v = _value;
    final refund = _refund.text.trim();
    if (coin == null ||
        v == null ||
        !v.isPositive ||
        !v.exact ||
        refund.isEmpty ||
        _refundError != null) {
      c.requestQuote(null);
      return;
    }
    c.requestQuote(
      BuyBeamQuoteRequest(asset: coin, amount: v, refundAddress: refund),
    );
  }

  void _setAmount(String text) {
    _amount.text = text;
    _changed();
  }

  // ---------------------------------------------------------------- order

  Future<void> _getAddress() async {
    final coin = _coin;
    final v = _value;
    if (coin == null || v == null || _busy) return;
    setState(() {
      _busy = true;
      _orderError = null;
      _walletProblem = null;
    });
    try {
      final order = await c.placeOrder(
        asset: coin,
        amount: v,
        refundAddress: _refund.text.trim(),
        beamWalletId: deps.walletId,
        newBeamAddress: deps.newBeamAddress,
        quote: c.quote,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        buyBeamRoute<void>(
          context,
          deps,
          (_) => BuyBeamOrderView(
            deps: deps,
            depositAddress: order.depositAddress,
          ),
        ),
      );
    } on BuyBeamError catch (e) {
      if (mounted) setState(() => _orderError = e);
    } on BuyBeamWalletNotReady {
      if (mounted) {
        setState(
          () => _walletProblem =
              'Your BEAM wallet is still starting, so it cannot make an '
              'address for the BEAM yet. Try again in a moment.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _walletProblem =
              "Campfire couldn't finish setting up this buy. Nothing was "
              'sent. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  _Cta _cta() {
    final coin = _coin;
    if (_busy) return _off('Asking buybeam.my for a deposit address…');
    if (_assetsFailed) return _off(null);
    if (coin == null) {
      return _off(
        _assets == null
            ? 'Loading the coins buybeam.my takes…'
            : 'Pick the coin you pay with.',
      );
    }
    if (_amountError != null) return _off(_amountError);
    final v = _value;
    if (v == null || !v.isPositive) {
      return _off('Enter how much ${coin.symbol} you pay.');
    }
    if (!v.exact) return _off(null);
    if (_refund.text.trim().isEmpty) {
      return _off('Add your ${coin.chainName} address for a refund.');
    }
    if (_refundError != null) return _off(_refundError);
    if (c.quoteError != null) return _off(null);
    if (c.quoting || c.quote == null) {
      return _off('Getting a price from buybeam.my…');
    }
    return (onPressed: _getAddress, reason: null);
  }

  static _Cta _off(String? reason) => (onPressed: null, reason: reason);

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    final coin = _coin;
    return DexPage(
      deps: deps,
      title: 'Buy BEAM',
      body: _form(context),
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('buy-cta'),
        label: coin == null
            ? 'Get a deposit address'
            : 'Get a ${coin.symbol} deposit address',
        reason: cta.reason,
        onPressed: cta.onPressed,
      ),
    );
  }

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final label = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final quiet = STextStyles.label(context)
        .copyWith(color: colors.textSubtitle1);
    final coin = _coin;
    final v = _value;
    final mine = c.orders(beamWalletId: deps.walletId);
    final hint = c.minimumHintUsd;
    final worth = coin?.priceUsd != null && v != null && v.isPositive
        ? '≈ ${BuyBeamWords.usd(v.value * coin!.priceUsd!)}'
        : null;
    final problem = _problem(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mine.isNotEmpty) ...[
          _yourBuys(context, mine.where((o) => o.isOpen).length),
          const SizedBox(height: 12),
        ],
        if (_assetsFailed) ...[
          DexNotice(
            key: const Key('buy-assets-failed'),
            sticker: BeamMoments.somethingWentWrong,
            kind: DexNoticeKind.error,
            title: "Couldn't reach buybeam.my",
            detail: [
              'This is not something you did. Nothing was sent.',
              if (deps.tor) 'If Tor is on, a new connection usually helps.',
            ].join(' '),
            actionLabel: 'Try again',
            onAction: () {
              setState(() => _assetsFailed = false);
              unawaited(_load(refresh: true));
            },
          ),
          const SizedBox(height: 12),
        ],
        Text('You pay', style: label),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('buy-amount'),
          assetButtonKey: const Key('buy-coin'),
          controller: _amount,
          focusNode: _amountFocus,
          asset: null,
          assetLabel: coin == null
              ? Text('Choose', style: STextStyles.smallMed14(context))
              : BuyCoinChip(asset: coin),
          error: _amountError != null,
          onChanged: (_) => _changed(),
          onAssetTap: _assets == null ? null : _pickCoin,
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (worth != null) ...[
                Text(worth, key: const Key('buy-worth'), style: quiet),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: hint == null
                    ? const SizedBox.shrink()
                    : Text(
                        'Smallest buy right now: about '
                        '${BuyBeamWords.usd(hint)}',
                        key: const Key('buy-minimum-hint'),
                        textAlign: TextAlign.right,
                        style: quiet,
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          coin == null
              ? 'Your address, for a refund if the buy can\'t go through'
              : 'Your ${coin.chainName} address, for a refund if the buy '
                    'can\'t go through',
          style: label,
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('buy-refund'),
          controller: _refund,
          focusNode: _refundFocus,
          onChanged: (_) => _changed(),
          autocorrect: false,
          enableSuggestions: false,
          style: STextStyles.smallMed14(context).copyWith(
            color: colors.textDark,
            fontFeatures: kAddressFontFeatures,
          ),
          decoration: InputDecoration(
            hintText: coin == null
                ? 'Address'
                : 'Paste your ${coin.symbol} address',
          ),
        ),
        if (_refundError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              _refundError!,
              key: const Key('buy-refund-error'),
              style: STextStyles.label(context)
                  .copyWith(color: colors.textError),
            ),
          ),
        const SizedBox(height: 12),
        Text('You get', style: label),
        const SizedBox(height: 6),
        _gets(context),
        if (problem != null) ...[const SizedBox(height: 12), problem],
        const SizedBox(height: 16),
        Text(
          'buybeam.my buys the BEAM and sends it to your wallet.',
          key: const Key('buy-footer'),
          style: quiet,
        ),
        if (deps.onWantWbeam != null) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: CustomTextButton(
              key: const Key('buy-want-wbeam'),
              text: 'Want WBEAM on Ethereum instead?',
              onTap: () => deps.onWantWbeam!(context, ref),
            ),
          ),
        ],
      ],
    );
  }

  Widget _yourBuys(BuildContext context, int open) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DexCard(
      key: const Key('buy-your-buys'),
      onTap: () => unawaited(BuyBeamOrdersView.show(context, deps)),
      child: Row(
        children: [
          Icon(
            open > 0 ? Icons.hourglass_top_rounded : Icons.history_rounded,
            size: 18,
            color: open > 0 ? colors.accentColorOrange : colors.textDark3,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              open > 0 ? 'Your buys ($open in progress)' : 'Your buys',
              style: STextStyles.smallMed14(context)
                  .copyWith(color: colors.textDark),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: colors.textSubtitle1,
          ),
        ],
      ),
    );
  }

  Widget _gets(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final quiet = STextStyles.label(context)
        .copyWith(color: colors.textSubtitle1);
    final q = c.quote;
    final quoting = c.quoting;
    final big = STextStyles.titleBold12(context)
        .copyWith(color: colors.textDark, fontSize: 18);
    return DexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const BuyBeamIcon(size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: q != null
                    ? Text(
                        '≈ ${BuyBeamWords.beam(q.beamGroth)}',
                        key: const Key('buy-estimate'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: big,
                      )
                    : quoting
                    ? const Align(
                        alignment: Alignment.centerLeft,
                        child: BeamSkeletonLine(
                          key: Key('buy-estimate-loading'),
                          width: 150,
                          height: 20,
                        ),
                      )
                    : Text(
                        'BEAM',
                        key: const Key('buy-estimate-empty'),
                        style: big.copyWith(color: colors.textSubtitle1),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Arrives in ${deps.walletName}',
            key: const Key('buy-arrives-in'),
            style: quiet,
          ),
          if (q?.etaSeconds != null) ...[
            const SizedBox(height: 2),
            Text(
              BuyBeamWords.eta(q!.etaSeconds!),
              key: const Key('buy-eta'),
              style: quiet,
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------- problems

  Widget? _problem(BuildContext context) {
    final coin = _coin;
    final v = _value;
    if (coin == null) return null;
    if (_walletProblem != null) {
      return DexNotice(
        key: const Key('buy-wallet-problem'),
        kind: DexNoticeKind.warning,
        title: 'Nothing was sent',
        detail: _walletProblem,
        actionLabel: 'Try again',
        onAction: () => unawaited(_getAddress()),
      );
    }
    if (v != null && v.isPositive && !v.exact) {
      final nearest = v.nearestExact();
      return DexNotice(
        key: const Key('buy-inexact'),
        kind: DexNoticeKind.warning,
        title: "buybeam.my can't take exactly ${v.text} ${coin.symbol}",
        detail: nearest == null
            ? "Campfire can't send buybeam.my an exact amount of "
                  '${coin.symbol}. Pick another coin.'
            : 'It would read it as a slightly different amount, and the '
                  'payment would not match. $nearest ${coin.symbol} is '
                  'read exactly.',
        actionLabel: nearest == null
            ? 'Pick another coin'
            : 'Use $nearest ${coin.symbol}',
        onAction: nearest == null
            ? () => unawaited(_pickCoin())
            : () => _setAmount(nearest),
      );
    }
    final e = _orderError ?? c.quoteError;
    if (e == null) return null;
    String? minimum;
    if (e.code.belowMinimum && e.minimumUsd != null) {
      final price =
          coin.priceUsd ??
          (e.orderValueUsd != null && v != null && v.value > 0
              ? e.orderValueUsd! / v.value
              : null);
      minimum = BuyBeamWords.minimumAmount(
        e.minimumUsd!,
        coin,
        priceUsd: price,
      );
    }
    final p = BuyBeamWords.problem(
      e,
      coin: coin,
      minimum: minimum,
      tor: deps.tor,
    );
    return DexNotice(
      key: Key('buy-problem-${e.code.wire}'),
      sticker: e.code.unreachable ? BeamMoments.somethingWentWrong : null,
      kind: p.serious || e.code.unreachable
          ? DexNoticeKind.error
          : DexNoticeKind.warning,
      title: p.title,
      detail: p.detail,
      actionLabel: p.fixLabel,
      onAction: p.fix == null ? null : () => _fix(p.fix!, minimum),
    );
  }

  void _fix(BuyFix fix, String? minimum) {
    switch (fix) {
      case BuyFix.useMinimum:
        if (minimum != null) _setAmount(minimum);
      case BuyFix.editAmount:
        _amountFocus.requestFocus();
        _amount.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _amount.text.length,
        );
      case BuyFix.pickCoin:
        unawaited(_pickCoin());
      case BuyFix.editRefund:
        _refundFocus.requestFocus();
      case BuyFix.tryAgain:
        if (_orderError != null || _walletProblem != null) {
          unawaited(_getAddress());
        } else {
          c.requote();
        }
      case BuyFix.contactSupport:
        deps.onOpenSupport?.call();
    }
  }
}
