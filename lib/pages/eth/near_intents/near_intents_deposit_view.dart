/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: show where to send the coin (address, QR, memo, amount,
//    deadline), then where the swap is, until the ETH is in this wallet.
// 2. Primary CTA: "Copy address" while waiting; once the ETH is here, "Buy
//    WBEAM with 0.033 ETH" (or "Done").
// 3. Taps: this screen opens from "Get a … deposit address"; the deposit
//    happens in the user's other wallet; coming back shows the progress.
//
// Exit-intent: "Is this address real?" — "Signed by NEAR Intents"
// (the signature is checked before this screen opens); "Which network?" —
// named in the warning, with what happens to anything else; "Did it
// work?" — the status updates by itself and names the next step; "What if
// I close the app?" — the swap is kept and shows on the previous screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/near_intents/near_intents_store.dart';
import '../../../wallets/ethereum/near_intents/one_click_client.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_container.dart';
import '../uniswap/uniswap_format.dart';
import 'near_intents_view.dart';
import 'near_intents_widgets.dart';

class NearIntentsDepositView extends StatefulWidget {
  const NearIntentsDepositView({
    super.key,
    required this.deps,
    required this.swap,
    this.pollEvery = const Duration(seconds: 15),
  });

  final NearIntentsDeps deps;
  final NearIntentsSwap swap;
  final Duration pollEvery;

  static Future<void> show(
    BuildContext context, {
    required NearIntentsDeps deps,
    required NearIntentsSwap swap,
  }) => showDexPage<void>(
    context,
    deps.uniswap,
    (_) => NearIntentsDepositView(deps: deps, swap: swap),
  );

  @override
  State<NearIntentsDepositView> createState() => _NearIntentsDepositViewState();
}

class _NearIntentsDepositViewState extends State<NearIntentsDepositView> {
  OneClickStatus? _status;
  Timer? _timer;
  bool _copied = false;

  NearIntentsSwap get swap => widget.swap;
  OneClickQuote get q => swap.quote;

  @override
  void initState() {
    super.initState();
    unawaited(_poll());
    _timer = Timer.periodic(widget.pollEvery, (_) => unawaited(_poll()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final s = await widget.deps.client.status(
        swap.depositAddress,
        memo: q.depositMemo,
      );
      if (!mounted) return;
      setState(() => _status = s);
      if (swap.lastState != s.state) {
        swap.lastState = s.state;
        await widget.deps.store.save(swap);
      }
      if (s.state.isFinal) _timer?.cancel();
    } catch (_) {
      // Shown as "checking…"; the next poll tries again.
    }
  }

  String get _amount =>
      '${UniFormat.exact(q.amountIn, swap.origin.decimals)} ${swap.origin.symbol}';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: swap.depositAddress));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final state = _status?.state ?? swap.lastState;
    final arrived = _status?.amountOut;
    final done = state == OneClickState.success;
    final onBuy = widget.deps.onBuyWbeam;
    final buyable = done && swap.buyWbeam && arrived != null && onBuy != null;
    final String label;
    final VoidCallback? action;
    if (buyable) {
      label = 'Buy WBEAM with ${UniFormat.compact(arrived, 18)} ETH';
      action = () {
        Navigator.of(context).pop();
        onBuy(context, arrived);
      };
    } else if (state?.isFinal ?? false) {
      label = 'Done';
      action = () => Navigator.of(context).pop();
    } else {
      label = _copied ? 'Address copied' : 'Copy address';
      action = _copy;
    }
    return DexPage(
      deps: widget.deps.uniswap,
      title: 'Send $_amount',
      body: _body(context, state),
      bottom: DexPrimaryAction(
        deps: widget.deps.uniswap,
        buttonKey: const Key('ni-deposit-cta'),
        label: label,
        onPressed: action,
      ),
    );
  }

  Widget _body(BuildContext context, OneClickState? state) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final waiting = state == null || state == OneClickState.pendingDeposit;
    final deadline = q.deadline?.toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _statusNotice(context, state),
        if (waiting) ...[
          const SizedBox(height: 12),
          RoundedContainer(
            color: colors.warningBackground,
            child: Text(
              'Send exactly $_amount on ${swap.origin.chainName}. '
              '${swap.origin.isNative ? '' : 'Only ${swap.origin.symbol} on ${swap.origin.chainName}. '}'
              'Other coins or networks sent here are lost.',
              key: const Key('ni-network-warning'),
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.warningForeground),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(
                key: const Key('ni-qr'),
                data: swap.depositAddress,
                size: 160,
                backgroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 10),
          DexCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    NearIntentsCoinIcon(token: swap.origin, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${swap.origin.chainName} deposit address',
                        style: STextStyles.label(context),
                      ),
                    ),
                    CustomTextButton(
                      key: const Key('ni-copy'),
                      text: _copied ? 'Copied' : 'Copy',
                      onTap: _copy,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(
                  swap.depositAddress,
                  key: const Key('ni-deposit-address'),
                  style: STextStyles.smallMed14(context).copyWith(
                    color: colors.textDark,
                    fontFeatures: kAddressFontFeatures,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.verified_rounded,
                      size: 14,
                      color: colors.accentColorGreen,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Signed by NEAR Intents',
                        key: const Key('ni-signed'),
                        style: STextStyles.label(context)
                            .copyWith(color: colors.accentColorGreen),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (q.depositMemo != null) ...[
            const SizedBox(height: 10),
            DexNotice(
              key: const Key('ni-memo'),
              kind: DexNoticeKind.error,
              title: 'Add this memo: ${q.depositMemo}',
              detail:
                  'Without it the coins cannot be matched to your swap and are '
                  'lost.',
            ),
          ],
        ],
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(label: 'You send', value: _amount),
              DexDetailRow(
                label: 'You get here',
                value: '≈ ${UniFormat.compact(q.amountOut, 18)} ETH',
                note: 'at least ${UniFormat.compact(q.minAmountOut, 18)} ETH',
              ),
              if (deadline != null && waiting)
                DexDetailRow(
                  label: 'Send before',
                  valueKey: const Key('ni-deadline'),
                  value:
                      '${deadline.hour.toString().padLeft(2, '0')}:'
                      '${deadline.minute.toString().padLeft(2, '0')}',
                  note: 'the address stops working after that',
                ),
              DexDetailRow(
                address: true,
                label: 'Refunds go to',
                value: UniFormat.shortAny(q.refundTo),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusNotice(BuildContext context, OneClickState? state) {
    final s = _status;
    switch (state) {
      case null:
      case OneClickState.pendingDeposit:
        return const DexNotice(
          key: Key('ni-status-waiting'),
          title: 'Waiting for your deposit',
          detail:
              'Send it from any wallet or exchange. This screen updates by '
              'itself; you can close it and come back.',
        );
      case OneClickState.knownDepositTx:
        return const DexNotice(
          key: Key('ni-status-seen'),
          title: 'Deposit seen — waiting for its network to confirm it',
        );
      case OneClickState.processing:
        return const DexNotice(
          key: Key('ni-status-processing'),
          title: 'Swapping into ETH…',
          detail: 'The ETH arrives in this wallet when it is done.',
        );
      case OneClickState.success:
        final got = s?.amountOut;
        return DexNotice(
          key: const Key('ni-status-success'),
          kind: DexNoticeKind.success,
          title: got == null
              ? 'Your ETH is in this wallet'
              : '${UniFormat.compact(got, 18)} ETH arrived in this wallet',
        );
      case OneClickState.incompleteDeposit:
        return DexNotice(
          key: const Key('ni-status-incomplete'),
          kind: DexNoticeKind.warning,
          title: 'Less than $_amount arrived',
          detail:
              'Send the rest to the same address before the deadline, or the '
              'deposit is refunded to your address.',
        );
      case OneClickState.refunded:
        return DexNotice(
          key: const Key('ni-status-refunded'),
          kind: DexNoticeKind.warning,
          title: 'Refunded to your ${swap.origin.chainName} address',
          detail: s?.refundReason == null
              ? 'The swap could not be done, so your coins went back.'
              : 'NEAR Intents said: "${s!.refundReason}".',
        );
      case OneClickState.failed:
        return const DexNotice(
          key: Key('ni-status-failed'),
          kind: DexNoticeKind.error,
          title: 'The swap failed',
          detail:
              'NEAR Intents could not complete it. Search for the deposit '
              'address on explorer.near-intents.org; refunds go to your '
              'address.',
        );
    }
  }
}
