/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: show exactly what this swap does — what leaves the wallet,
//    what arrives (and the least that may), the network fee, the contract
//    it goes to — and send it only after Campfire's PIN / password.
// 2. Primary CTA: the outcome, "Swap 0.01 ETH".
// 3. Taps from app open: wallet → Swap → amount → "Swap 0.01 ETH" (3);
//    this screen's button is the 4th, then the PIN.
//
// Nothing is signed before the PIN: the Permit2 signature (for a token)
// is made after it, and the transaction is measured again with it; if it
// would need more gas than shown here, this screen shows the new numbers
// instead of sending.
//
// Exit-intent (§1.7): "Is this a scam?" — the contract is Uniswap's
// Universal Router, named with its address; "What if the price moves?" —
// the least you receive is on the screen and Ethereum enforces it; "Did it
// work?" — the screen waits for Ethereum and says what actually arrived.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/eth_rpc.dart';
import '../../../wallets/ethereum/uniswap/uniswap_constants.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_container.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';
import 'uniswap_widgets.dart';

enum _Phase { review, sending, waiting, done, failed, unknown }

/// Pops with the transaction hash once sent, or null when the user went
/// back. A swap is sent at most once from here.
class UniswapReviewView extends StatefulWidget {
  const UniswapReviewView({
    super.key,
    required this.deps,
    required this.review,
  });

  final UniswapDeps deps;
  final UniSwapReview review;

  static Future<String?> show(
    BuildContext context, {
    required UniswapDeps deps,
    required UniSwapReview review,
  }) => showDexPage<String>(
    context,
    deps,
    (_) => UniswapReviewView(deps: deps, review: review),
  );

  @override
  State<UniswapReviewView> createState() => _UniswapReviewViewState();
}

class _UniswapReviewViewState extends State<UniswapReviewView> {
  late UniSwapReview _review = widget.review;
  _Phase _phase = _Phase.review;
  String? _hash;
  UniTxOutcome? _outcome;
  String? _error;

  UniswapDeps get deps => widget.deps;
  UniQuote get q => _review.quote;

  String _amt(BigInt v, UniToken t) =>
      '${UniFormat.exact(v, t.decimals)} ${t.symbol}';

  Future<void> _send() async {
    final ok = await deps.authenticate(context, reason: 'Authenticate to swap');
    if (ok != true || !mounted) return;
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    final UniPreparedSwap prepared;
    try {
      prepared = await deps.service.finalizeSwap(
        review: _review,
        signer: deps.signer,
      );
    } on UniRouteChanged {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.review;
        _error =
            'One of the pools on this route would not actually trade, so '
            'Campfire left it out. Go back for the next best price.';
      });
      return;
    } on UniGasChanged catch (e) {
      if (!mounted) return;
      setState(() {
        _review = UniSwapReview(
          quote: _review.quote,
          slippageBips: _review.slippageBips,
          minimumOut: _review.minimumOut,
          deadline: _review.deadline,
          needsPermit: _review.needsPermit,
          gasLimit: e.gasLimit,
          fees: _review.fees,
          priceMoved: _review.priceMoved,
        );
        _phase = _Phase.review;
        _error =
            'The swap needs a little more gas than first measured. The '
            'network fee below is updated; nothing was sent.';
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.review;
        _error = e is EthRpcError
            ? 'Your Ethereum node would not build it: "${e.message}". '
                  'Nothing was sent.'
            : "Couldn't build the swap. Nothing was sent.";
      });
      return;
    }
    final String hash;
    try {
      hash = await deps.signer.send(
        prepared.tx.withNote(
          'Uniswap: swap ${_amt(q.amountIn, q.tokenIn)} for ${q.tokenOut.symbol}',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Never offered again from here: it may have reached the network.
        _phase = _Phase.unknown;
        _error = '$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _hash = hash;
      _phase = _Phase.waiting;
    });
    final outcome = await deps.service
        .waitForReceipt(hash, owner: deps.signer.address, tokenOut: q.tokenOut)
        .then<UniTxOutcome?>((v) => v, onError: (Object _) => null);
    if (!mounted) return;
    unawaited(deps.refreshBalances({UniToken.eth, q.tokenIn, q.tokenOut}));
    setState(() {
      _outcome = outcome;
      _phase = outcome == null
          ? _Phase.unknown
          : outcome.success
          ? _Phase.done
          : _Phase.failed;
    });
  }

  void _close() => Navigator.of(context).pop(_hash);

  @override
  Widget build(BuildContext context) {
    final sent = _phase.index >= _Phase.waiting.index;
    final busy = _phase == _Phase.sending;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {},
      child: DexPage(
        deps: deps,
        title: sent ? 'Swap' : 'Confirm swap',
        onClose: busy ? () {} : _close,
        body: sent ? _status(context) : _summary(context),
        bottom: DexPrimaryAction(
          deps: deps,
          buttonKey: const Key('uni-review-cta'),
          label: sent ? 'Done' : 'Swap ${_amt(q.amountIn, q.tokenIn)}',
          reason: busy ? 'Signing and sending…' : null,
          onPressed: busy ? null : (sent ? _close : _send),
        ),
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final expected = _review.expectedGasCost;
    final most = _review.maxGasCost;
    final impact = q.priceImpact;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundedContainer(
          color: colors.snackBarBackInfo,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bigRow(
                context,
                'You pay',
                q.amountIn,
                q.tokenIn,
                'uni-review-pay',
              ),
              Padding(
                padding: const EdgeInsets.only(left: 38, top: 2),
                child: Text(
                  '+ the network fee, ≈ ${UniFormat.compact(expected, 18)} ETH',
                  key: const Key('uni-review-total'),
                  style: STextStyles.label(context)
                      .copyWith(color: colors.snackBarTextInfo),
                ),
              ),
              const SizedBox(height: 10),
              _bigRow(
                context,
                'You receive about',
                q.amountOut,
                q.tokenOut,
                'uni-review-receive',
              ),
              const SizedBox(height: 6),
              Text(
                'At least ${_amt(_review.minimumOut, q.tokenOut)} — if the '
                'price moves more than '
                '${UniFormat.percent(_review.slippageBips / 10000)} first, '
                'Ethereum cancels the swap and only the network fee is '
                'spent.',
                key: const Key('uni-review-minimum'),
                style: STextStyles.label(context)
                    .copyWith(color: colors.snackBarTextInfo),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(label: 'Rate', value: UniFormat.rate(q)),
              DexDetailRow(
                label: 'Route',
                value: uniRouteText(q, deps),
                note: uniRouteNote(q, deps),
              ),
              DexDetailRow(
                label: 'Price change from your swap',
                value: impact == null ? 'Unknown' : UniFormat.percent(impact),
              ),
              DexDetailRow(
                label: 'Network fee',
                valueKey: const Key('uni-review-fee'),
                value: '≈ ${UniFormat.compact(expected, 18)} ETH',
                note: deps.worth(UniToken.eth, expected),
              ),
              DexDetailRow(
                label: 'The most it can cost',
                valueKey: const Key('uni-review-fee-max'),
                value: '${UniFormat.compact(most, 18)} ETH',
              ),
              DexDetailRow(
                address: true,
                label: 'Sent to',
                value:
                    'Uniswap Universal Router '
                    '(${UniFormat.short(UniswapAddresses.universalRouter)})',
              ),
              if (_review.needsPermit)
                DexDetailRow(
                  key: const Key('uni-review-permit'),
                  label: 'You also sign',
                  value:
                      'Uniswap may take exactly '
                      '${_amt(q.amountIn, q.tokenIn)}, for 30 minutes',
                ),
            ],
          ),
        ),
        if (q.pools.any((p) => p is UniV4Pool && p.hasHooks)) ...[
          const SizedBox(height: 12),
          const DexNotice(
            key: Key('uni-review-hook'),
            kind: DexNoticeKind.warning,
            title: 'This route uses a pool with a hook',
            detail:
                'A hook is extra code its creator added to the pool. Your '
                'minimum above is still enforced by Uniswap.',
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('uni-review-error'),
            kind: DexNoticeKind.warning,
            title: 'Nothing was sent',
            detail: _error,
          ),
        ],
      ],
    );
  }

  Widget _bigRow(
    BuildContext context,
    String label,
    BigInt amount,
    UniToken token,
    String key,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final worth = deps.worth(token, amount);
    return Row(
      children: [
        UniTokenIcon(token: token, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: STextStyles.label(context)
                    .copyWith(color: colors.snackBarTextInfo),
              ),
              Text(
                _amt(amount, token),
                key: Key(key),
                style: STextStyles.titleBold12(context)
                    .copyWith(color: colors.snackBarTextInfo, fontSize: 16),
              ),
              if (worth != null)
                Text(
                  worth,
                  style: STextStyles.label(context)
                      .copyWith(color: colors.snackBarTextInfo),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _status(BuildContext context) {
    final o = _outcome;
    final link = _hash == null
        ? null
        : CustomTextButton(
            key: const Key('uni-review-explorer'),
            text: 'View on Etherscan',
            onTap: () => unawaited(
              launchUrl(
                deps.explorerTx(_hash!),
                mode: LaunchMode.externalApplication,
              ),
            ),
          );
    final DexNotice notice;
    switch (_phase) {
      case _Phase.waiting:
        notice = const DexNotice(
          key: Key('uni-review-waiting'),
          title: 'Swap sent — waiting for Ethereum…',
          detail:
              'Usually under a minute. You can close this; the swap carries '
              'on and shows in your history.',
        );
      case _Phase.done:
        final got = o?.received;
        notice = DexNotice(
          key: const Key('uni-review-done'),
          kind: DexNoticeKind.success,
          title: got == null
              ? 'Swap done'
              : 'Swap done: you received ${_amt(got, q.tokenOut)}',
          detail:
              'Network fee: ${UniFormat.compact(o!.gasCost, 18)} ETH'
              '${deps.worth(UniToken.eth, o.gasCost) == null ? '' : ' (${deps.worth(UniToken.eth, o.gasCost)})'}.',
        );
      case _Phase.failed:
        notice = DexNotice(
          key: const Key('uni-review-failed'),
          sticker: BeamMoments.somethingWentWrong,
          kind: DexNoticeKind.error,
          title: "The swap didn't go through",
          detail:
              'Most often the price moved past your protection before it '
              'was mined. Nothing was swapped; the network fee of '
              '${UniFormat.compact(o!.gasCost, 18)} ETH was spent.',
        );
      default:
        notice = DexNotice(
          key: const Key('uni-review-unknown'),
          kind: DexNoticeKind.warning,
          title: 'Not confirmed yet',
          detail:
              'Campfire could not see the swap on Ethereum yet. It may still '
              'go through: check your history in a few minutes before '
              'trying again.${_error == null ? '' : '\n$_error'}',
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        notice,
        if (link != null) ...[const SizedBox(height: 8), Center(child: link)],
      ],
    );
  }
}
