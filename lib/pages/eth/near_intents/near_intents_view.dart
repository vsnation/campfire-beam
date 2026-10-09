/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: bring a coin from another chain (BTC, ZEC, LTC… any coin
//    NEAR Intents swaps) into this Ethereum wallet as ETH, and then buy
//    WBEAM with it.
// 2. Primary CTA: "Get a BTC deposit address" (the outcome of this
//    screen), then on the next screen the deposit itself happens in the
//    user's other wallet.
// 3. Taps from app open: wallet → Swap (2) → "Pay with BTC, ZEC, LTC…"
//    (3) → coin, amount, refund address → the button (4).
//
// Exit-intent:
// * "Is this a scam?" — NEAR Intents is named, the ETH lands in this
//   wallet's own address (shown), and the next screen's address is only
//   shown when NEAR Intents' signature on it checks out.
// * "What do I get?" — the ETH, its worth, the least it can be, and the
//   WBEAM that buys right now, before any address exists.
// * "What if it goes wrong?" — the refund address is asked in plain words
//   and the coins go back there if the swap cannot happen.
// * Fees — "included above" with NEAR Intents' 0.25% named.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/near_intents/near_intents_store.dart';
import '../../../wallets/ethereum/near_intents/one_click_client.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../widgets/beam/dex/dex_amount_field.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../uniswap/uniswap_deps.dart';
import '../uniswap/uniswap_format.dart';
import 'near_intents_deposit_view.dart';
import 'near_intents_token_picker.dart';
import 'near_intents_widgets.dart';

/// What the NEAR Intents screens need besides the Uniswap swap's deps.
class NearIntentsDeps {
  NearIntentsDeps({
    required this.uniswap,
    required this.client,
    required this.store,
    required this.walletId,
    this.onBuyWbeam,
  });

  final UniswapDeps uniswap;
  final OneClickClient client;
  final NearIntentsStore store;
  final String walletId;

  /// Opens the Uniswap swap with [eth] wei of ETH to spend on WBEAM.
  final void Function(BuildContext context, BigInt eth)? onBuyWbeam;

  /// This wallet's address: where the ETH arrives.
  String get recipient => uniswap.signer.address;

  List<OneClickToken>? _tokens;

  /// Every coin NEAR Intents takes, except ETH on Ethereum itself.
  Future<List<OneClickToken>> tokens() async => _tokens ??= sortOneClickTokens(
    (await client.tokens()).where((t) => t.assetId != kOneClickEthOnEthereum),
  );
}

enum _Problem { failed, refused }

class NearIntentsView extends StatefulWidget {
  const NearIntentsView({super.key, required this.deps, this.initial});

  final NearIntentsDeps deps;
  final OneClickToken? initial;

  static Future<void> show(BuildContext context, NearIntentsDeps deps) =>
      showDexPage<void>(
        context,
        deps.uniswap,
        (_) => NearIntentsView(deps: deps),
      );

  @override
  State<NearIntentsView> createState() => _NearIntentsViewState();
}

class _NearIntentsViewState extends State<NearIntentsView> {
  OneClickToken? _coin;
  final _amount = TextEditingController();
  final _refund = TextEditingController();
  UniAmountInput _input = UniAmountInput.empty;
  OneClickQuote? _quote;
  UniQuote? _wbeam;
  bool _quoting = false;
  bool _busy = false;
  _Problem? _problem;
  String? _problemText;
  bool _buyWbeam = true;
  Timer? _debounce;
  int _seq = 0;
  List<NearIntentsSwap> _open = const [];

  NearIntentsDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    _coin = widget.initial;
    unawaited(_loadDefaults());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _amount.dispose();
    _refund.dispose();
    super.dispose();
  }

  Future<void> _loadDefaults() async {
    try {
      final list = await deps.tokens();
      if (_coin == null && list.isNotEmpty && mounted) {
        setState(() => _coin = list.first);
      }
    } catch (_) {
      if (mounted) setState(() => _problem = _Problem.failed);
    }
    final saved = await deps.store.all(deps.walletId);
    if (mounted) setState(() => _open = saved.where((s) => s.isOpen).toList());
  }

  UniToken get _coinAsUni => UniToken(
    address: '0x0000000000000000000000000000000000000001',
    symbol: _coin?.symbol ?? '',
    decimals: _coin?.decimals ?? 8,
  );

  void _changed() {
    _debounce?.cancel();
    _seq++;
    setState(() {
      _input = _coin == null
          ? UniAmountInput.empty
          : UniFormat.parse(_amount.text, _coinAsUni);
      _quote = null;
      _wbeam = null;
      _problem = null;
      _quoting = _input.isPositive && _refund.text.trim().isNotEmpty;
    });
    if (_quoting) {
      _debounce = Timer(const Duration(milliseconds: 600), _requote);
    }
  }

  Future<void> _pickCoin() async {
    final chosen = await showNearIntentsTokenPicker(context, deps: deps);
    if (chosen == null || !mounted) return;
    setState(() {
      if (chosen.blockchain != _coin?.blockchain) _refund.clear();
      _coin = chosen;
    });
    _changed();
  }

  Future<void> _requote() async {
    final coin = _coin;
    final amount = _input.value;
    final refund = _refund.text.trim();
    if (coin == null || amount == null || refund.isEmpty) return;
    final seq = ++_seq;
    try {
      final q = await deps.client.quote(
        origin: coin,
        amountIn: amount,
        recipient: deps.recipient,
        refundTo: refund,
        dry: true,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _quote = q;
        _quoting = false;
      });
      // What that ETH buys in WBEAM right now (keeping the gas).
      unawaited(_priceWbeam(q.minAmountOut, seq));
    } on OneClickError catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = _Problem.refused;
        _problemText = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = _Problem.failed;
      });
    }
  }

  Future<void> _priceWbeam(BigInt eth, int seq) async {
    try {
      final q = await deps.uniswap.service.quote(
        tokenIn: UniToken.eth,
        tokenOut: kWbeamToken,
        amountIn: eth,
      );
      if (mounted && seq == _seq) setState(() => _wbeam = q);
    } catch (_) {
      // The ETH estimate alone is still right.
    }
  }

  Future<void> _getAddress() async {
    final coin = _coin;
    final amount = _input.value;
    if (coin == null || amount == null || _busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final q = await deps.client.quote(
        origin: coin,
        amountIn: amount,
        recipient: deps.recipient,
        refundTo: _refund.text.trim(),
        dry: false,
      );
      final swap = NearIntentsSwap(
        walletId: deps.walletId,
        quote: q,
        origin: coin,
        createdAt: DateTime.now().toUtc(),
        buyWbeam: _buyWbeam,
      );
      await deps.store.save(swap);
      if (!mounted) return;
      setState(() => _busy = false);
      await NearIntentsDepositView.show(context, deps: deps, swap: swap);
      if (mounted) unawaited(_loadDefaults());
    } on OneClickError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = _Problem.refused;
        _problemText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = _Problem.failed;
      });
    }
  }

  ({VoidCallback? onPressed, String? reason}) _cta() {
    final coin = _coin;
    if (_busy) return (onPressed: null, reason: 'Asking NEAR Intents…');
    if (coin == null) {
      return (onPressed: null, reason: 'Pick the coin you have.');
    }
    if (_input.error != null) return (onPressed: null, reason: _input.error);
    if (!_input.isPositive) {
      return (
        onPressed: null,
        reason: 'Enter how much ${coin.symbol} you send.',
      );
    }
    if (_refund.text.trim().isEmpty) {
      return (
        onPressed: null,
        reason: 'Add your ${coin.chainName} address for a refund.',
      );
    }
    if (_problem != null) return (onPressed: null, reason: null);
    if (_quoting || _quote == null) {
      return (onPressed: null, reason: 'Getting a price from NEAR Intents…');
    }
    return (onPressed: _getAddress, reason: null);
  }

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    return DexPage(
      deps: deps.uniswap,
      title: 'Pay with another coin',
      body: _form(context),
      bottom: DexPrimaryAction(
        deps: deps.uniswap,
        buttonKey: const Key('ni-cta'),
        label: _coin == null
            ? 'Get a deposit address'
            : 'Get a ${_coin!.symbol} deposit address',
        reason: cta.reason,
        onPressed: cta.onPressed,
      ),
    );
  }

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final label = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final coin = _coin;
    final q = _quote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Send BTC, ZEC, LTC or 200 other coins from any wallet or '
          'exchange. NEAR Intents swaps them into ETH and delivers it to '
          'this wallet; then buy WBEAM with it here.',
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        for (final s in _open) ...[
          const SizedBox(height: 12),
          NearIntentsOpenSwapCard(
            swap: s,
            onTap: () async {
              await NearIntentsDepositView.show(context, deps: deps, swap: s);
              if (mounted) unawaited(_loadDefaults());
            },
          ),
        ],
        const SizedBox(height: 12),
        Text('You send', style: label),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('ni-amount'),
          assetButtonKey: const Key('ni-coin'),
          controller: _amount,
          asset: null,
          assetLabel: coin == null
              ? Text('Choose', style: STextStyles.smallMed14(context))
              : NearIntentsCoinChip(token: coin),
          error: _input.error != null,
          onChanged: (_) => _changed(),
          onAssetTap: _pickCoin,
        ),
        if (coin != null && _input.isPositive && coin.priceUsd != null)
          DexWorth(
            '≈ ${(_input.value!.toDouble() / UniFormat.unit(coin.decimals).toDouble() * coin.priceUsd!).toStringAsFixed(2)} USD',
            textKey: const Key('ni-amount-worth'),
          ),
        const SizedBox(height: 12),
        Text(
          coin == null
              ? 'Your address for a refund'
              : 'Your ${coin.chainName} address for a refund',
          style: label,
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('ni-refund'),
          controller: _refund,
          onChanged: (_) => _changed(),
          autocorrect: false,
          enableSuggestions: false,
          style: STextStyles.smallMed14(context)
              .copyWith(color: colors.textDark),
          decoration: InputDecoration(
            hintText: coin == null
                ? 'Address'
                : 'If the swap cannot happen, your ${coin.symbol} goes back here',
          ),
        ),
        const SizedBox(height: 12),
        Text('You get in this wallet', style: label),
        const SizedBox(height: 6),
        DexCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DexDetailRow(
                label: 'ETH',
                valueKey: const Key('ni-eth'),
                value: q == null
                    ? (_quoting ? '…' : '—')
                    : '≈ ${UniFormat.compact(q.amountOut, 18)} ETH',
                note: q?.amountOutUsd == null
                    ? null
                    : '≈ ${double.parse(q!.amountOutUsd!).toStringAsFixed(2)} USD',
              ),
              if (q != null)
                DexDetailRow(
                  label: 'At least',
                  valueKey: const Key('ni-min'),
                  value: '${UniFormat.compact(q.minAmountOut, 18)} ETH',
                ),
              if (q?.timeEstimate != null)
                DexDetailRow(
                  label: 'Takes about',
                  value: _duration(q!.timeEstimate!),
                  note: 'after your deposit is confirmed',
                ),
              DexDetailRow(
                address: true,
                label: 'Delivered to',
                value: UniFormat.short(deps.recipient),
                note: 'this wallet',
              ),
              const DexDetailRow(
                label: 'Fees',
                value: 'Included above',
                note: 'NEAR Intents 0.25% + network fees',
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          key: const Key('ni-buy-wbeam'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _buyWbeam,
          onChanged: (v) => setState(() => _buyWbeam = v ?? true),
          title: Text(
            _wbeam == null
                ? 'Then buy WBEAM with the ETH'
                : 'Then buy WBEAM with it: about '
                      '${UniFormat.compact(_wbeam!.amountOut, 8)} WBEAM now',
            key: const Key('ni-wbeam-estimate'),
            style: STextStyles.smallMed14(context),
          ),
        ),
        if (_problem != null) ...[
          const SizedBox(height: 8),
          _problemNotice(context),
        ],
      ],
    );
  }

  static String _duration(int seconds) => seconds < 90
      ? '$seconds seconds'
      : seconds < 5400
      ? '${(seconds / 60).round()} minutes'
      : '${(seconds / 3600).toStringAsFixed(1)} hours';

  Widget _problemNotice(BuildContext context) => switch (_problem!) {
    _Problem.refused => DexNotice(
      key: const Key('ni-refused'),
      kind: DexNoticeKind.warning,
      title: 'NEAR Intents would not price this',
      detail:
          'It said: "${_problemText ?? 'no reason given'}". Check the amount '
          'and the refund address. Nothing was sent.',
    ),
    _Problem.failed => DexNotice(
      key: const Key('ni-failed'),
      sticker: BeamMoments.somethingWentWrong,
      kind: DexNoticeKind.error,
      title: "Couldn't reach NEAR Intents",
      detail:
          'This is not something you did, and nothing was sent. With Tor on '
          'it can take a moment longer.',
      actionLabel: 'Try again',
      onAction: () {
        setState(() => _problem = null);
        unawaited(_loadDefaults());
        _changed();
      },
    ),
  };
}
