/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: send exactly this much of this coin to this address; then
//    see the buy go through until the BEAM is in the wallet.
// 2. Primary CTA: "Copy address" while the payment is awaited; after it,
//    the one next step: back to the wallet, "See it in your wallet" once
//    the wallet has the BEAM, "Start a new buy" when no payment came,
//    "Contact buybeam.my support" when buybeam.my needs a look.
// 3. Taps: it opens by itself from "Get a … deposit address"; later, Buy →
//    "Your buys" → the buy.
//
// Exit-intent (§1.7):
// * "Which network? How much exactly?" — the coin and its network are
//   said above the address, the exact amount has its own copy button.
// * "Did it work?" — four steps, each ticked as it happens; the screen
//   updates by itself. "Arrived" is said only once this wallet has the
//   BEAM transaction; until then it says buybeam.my sent it.
// * "Can I close this?" — said: the buy keeps going; Campfire must be
//   opened again within 12 hours for the BEAM to arrive (a regular BEAM
//   address needs the wallet online).
// * "It went wrong" — what happened, where the coins are (sent back, or
//   never taken), and the one next step.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../wallets/beam/buy/buybeam_order.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../eth/uniswap/uniswap_format.dart';
import 'buy_beam_deps.dart';
import 'buy_beam_routes.dart';
import 'buy_beam_view.dart';
import 'buy_beam_widgets.dart';
import 'buy_beam_words.dart';

class BuyBeamOrderView extends StatefulWidget {
  const BuyBeamOrderView({
    super.key,
    required this.deps,
    required this.depositAddress,
    this.now,
  });

  final BuyBeamDeps deps;

  /// The buy's only handle.
  final String depositAddress;

  /// "today" is counted from this (tests); the clock when null.
  final DateTime Function()? now;

  static Future<void> show(
    BuildContext context,
    BuyBeamDeps deps,
    String depositAddress,
  ) => showBuyBeamPage<void>(
    context,
    deps,
    (_) => BuyBeamOrderView(deps: deps, depositAddress: depositAddress),
  );

  @override
  State<BuyBeamOrderView> createState() => _BuyBeamOrderViewState();
}

class _BuyBeamOrderViewState extends State<BuyBeamOrderView> {
  bool _copied = false;
  bool _amountCopied = false;

  /// This wallet has the BEAM buybeam.my sent.
  bool _arrived = false;
  Timer? _arrival;

  BuyBeamDeps get deps => widget.deps;
  BuyBeamController get c => deps.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_rebuild);
    unawaited(() async {
      await c.resumeAll();
      // Where it is now, not where it was when the app last looked.
      if (c.order(widget.depositAddress)?.isOpen ?? false) {
        await c.poll(widget.depositAddress);
      }
      if (mounted) _watchArrival();
    }());
  }

  @override
  void dispose() {
    c.removeListener(_rebuild);
    _arrival?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) return;
    setState(() {});
    _watchArrival();
  }

  /// Once buybeam.my has sent the BEAM, looks for it in the wallet until
  /// it is there.
  void _watchArrival() {
    final o = c.order(widget.depositAddress);
    final tx = o?.beamTxId;
    final check = deps.receivedInWallet;
    if (_arrived ||
        _arrival != null ||
        check == null ||
        tx == null ||
        o?.lastState != BuyBeamState.delivered) {
      return;
    }
    Future<void> look() async {
      bool got;
      try {
        got = await check(tx);
      } catch (_) {
        got = false;
      }
      if (!mounted || !got) return;
      _arrival?.cancel();
      setState(() => _arrived = true);
    }

    _arrival = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(look()),
    );
    unawaited(look());
  }

  Future<void> _copy(String text, {bool amount = false}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => amount ? _amountCopied = true : _copied = true);
  }

  void _back() => Navigator.of(context).pop();

  void _newBuy() => unawaited(
    Navigator.of(context).pushReplacement(
      buyBeamRoute<void>(context, deps, (_) => BuyBeamView(deps: deps)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final o = c.order(widget.depositAddress);
    if (o == null) {
      return DexPage(
        deps: deps,
        title: 'Your buy',
        body: Text('Loading your buy…', style: STextStyles.label(context)),
      );
    }
    final s = o.lastState ?? BuyBeamState.awaitingDeposit;
    final String label;
    final VoidCallback action;
    switch (s) {
      case BuyBeamState.awaitingDeposit:
        label = _copied ? 'Address copied' : 'Copy address';
        action = () => unawaited(_copy(o.depositAddress));
      case BuyBeamState.delivered when _arrived:
        label = 'See it in your wallet';
        action = () => unawaited(
          deps.onOpenTransaction?.call(context, o.beamTxId) ??
              Future.sync(_back),
        );
      case BuyBeamState.delivered:
        label = 'Back to your wallet';
        action = _back;
      case BuyBeamState.expired:
        label = 'Start a new buy';
        action = _newBuy;
      case BuyBeamState.failed:
      case BuyBeamState.attention:
        label = 'Contact buybeam.my support';
        action = () => deps.onOpenSupport?.call();
      case BuyBeamState.refunded:
      case BuyBeamState.depositDetected:
      case BuyBeamState.swapping:
      case BuyBeamState.buying:
      case BuyBeamState.processing:
      case BuyBeamState.sending:
      case BuyBeamState.inProgress:
        label = 'Back to your wallet';
        action = _back;
    }
    return DexPage(
      deps: deps,
      title: s == BuyBeamState.awaitingDeposit
          ? 'Send ${o.sendAmount} ${o.symbol}'
          : 'Buy BEAM',
      body: _body(context, o, s),
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('buy-order-cta'),
        label: label,
        onPressed: action,
      ),
    );
  }

  Widget _body(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final quiet = STextStyles.label(context)
        .copyWith(color: colors.textSubtitle1);
    final waiting = s == BuyBeamState.awaitingDeposit;
    final pollError = c.pollError(o.depositAddress);
    final notice = _notice(context, o, s);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (o.sandbox) ...[
          const DexNotice(
            key: Key('buy-sandbox'),
            title: "buybeam.my's test mode: nothing to pay",
          ),
          const SizedBox(height: 12),
        ],
        if (notice != null) ...[notice, const SizedBox(height: 12)],
        if (waiting) ..._payment(context, o),
        BuyStepList(steps: buyBeamSteps(s, arrived: _arrived)),
        const SizedBox(height: 12),
        _details(context, o, s),
        if (o.isOpen) ...[
          const SizedBox(height: 12),
          Text(
            'Keep Campfire open until your BEAM arrives. If you close it, '
            'open it again within 12 hours.',
            key: const Key('buy-keep-open'),
            style: quiet,
          ),
          const SizedBox(height: 4),
          Text(
            'You can leave this screen — your buy keeps going.',
            key: const Key('buy-can-leave'),
            style: quiet,
          ),
        ],
        if (pollError != null && o.isOpen) ...[
          const SizedBox(height: 4),
          Text(
            pollError.code.unreachable
                ? "Couldn't reach buybeam.my just now. Campfire keeps "
                      'checking.'
                : "buybeam.my's last answer didn't make sense. Campfire "
                      'keeps checking.',
            key: const Key('buy-poll-error'),
            style: quiet,
          ),
        ],
      ],
    );
  }

  List<Widget> _payment(BuildContext context, BuyBeamOrder o) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final deadline = o.deadline?.toLocal();
    return [
      RoundedContainer(
        color: colors.warningBackground,
        child: Text(
          'Send only ${o.symbol} on the ${o.chainName} network to this '
          'address.',
          key: const Key('buy-network-warning'),
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
            key: const Key('buy-qr'),
            data: o.depositAddress,
            size: 150,
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
                BuyCoinIcon(assetId: o.assetId, symbol: o.symbol, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${o.chainName} deposit address',
                    style: STextStyles.label(context),
                  ),
                ),
                CustomTextButton(
                  key: const Key('buy-copy-address'),
                  text: _copied ? 'Copied' : 'Copy',
                  onTap: () => unawaited(_copy(o.depositAddress)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              o.depositAddress,
              key: const Key('buy-deposit-address'),
              style: STextStyles.smallMed14(context).copyWith(
                color: colors.textDark,
                fontFeatures: kAddressFontFeatures,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      DexCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Send exactly', style: STextStyles.label(context)),
                  Text(
                    '${o.sendAmount} ${o.symbol}',
                    key: const Key('buy-exact-amount'),
                    style: STextStyles.titleBold12(context)
                        .copyWith(color: colors.textDark, fontSize: 16),
                  ),
                ],
              ),
            ),
            CustomTextButton(
              key: const Key('buy-copy-amount'),
              text: _amountCopied ? 'Copied' : 'Copy',
              onTap: () => unawaited(_copy(o.sendAmount, amount: true)),
            ),
          ],
        ),
      ),
      if (deadline != null) ...[
        const SizedBox(height: 8),
        Text(
          'This address works until ${_when(deadline)}.',
          key: const Key('buy-deadline'),
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
      ],
      const SizedBox(height: 12),
    ];
  }

  String _when(DateTime t) {
    final now = (widget.now?.call() ?? DateTime.now()).toLocal();
    final hm =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
    final today =
        t.year == now.year && t.month == now.month && t.day == now.day;
    if (today) return '$hm today';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '$hm on ${t.day} ${months[t.month - 1]}';
  }

  Widget _details(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    final estimate = o.beamEstimate == null
        ? null
        : BuyBeamWords.beam(BuyBeamWords.groth(o.beamEstimate!));
    // Paid once buybeam.my has seen the payment.
    final paid = !const {
      BuyBeamState.awaitingDeposit,
      BuyBeamState.expired,
      BuyBeamState.failed,
    }.contains(s);
    return DexCard(
      child: Column(
        children: [
          DexDetailRow(
            label: paid ? 'You paid' : 'You pay',
            value: '${o.sendAmount} ${o.symbol}',
          ),
          if (estimate != null)
            DexDetailRow(
              label: _arrived ? 'You got' : 'You get',
              valueKey: const Key('buy-order-estimate'),
              value: '≈ $estimate',
            ),
          DexDetailRow(label: 'Arrives in', value: deps.walletName),
          DexDetailRow(
            address: true,
            label: 'Refunds go to',
            value: UniFormat.shortAny(o.refundAddress),
          ),
          // The order's handle, for buybeam.my's support.
          if (s != BuyBeamState.awaitingDeposit)
            DexDetailRow(
              address: true,
              label: 'Order',
              valueKey: const Key('buy-order-address'),
              value: UniFormat.shortAny(o.depositAddress),
              trailing: CustomTextButton(
                key: const Key('buy-copy-order'),
                text: _copied ? 'Copied' : 'Copy',
                onTap: () => unawaited(_copy(o.depositAddress)),
              ),
            ),
          if (o.beamTxId != null)
            DexDetailRow(
              address: true,
              label: 'BEAM transaction',
              valueKey: const Key('buy-beam-tx'),
              value: UniFormat.shortAny(o.beamTxId!),
            ),
        ],
      ),
    );
  }

  Widget? _notice(BuildContext context, BuyBeamOrder o, BuyBeamState s) {
    switch (s) {
      case BuyBeamState.delivered:
        final got = o.beamEstimate == null
            ? 'Your BEAM'
            : '≈ ${BuyBeamWords.beam(BuyBeamWords.groth(o.beamEstimate!))}';
        if (_arrived) {
          return DexNotice(
            key: const Key('buy-arrived'),
            kind: DexNoticeKind.success,
            title: 'Your BEAM has arrived',
            detail: '$got is in ${deps.walletName}.',
          );
        }
        return DexNotice(
          key: const Key('buy-delivered'),
          title: 'buybeam.my sent your BEAM',
          detail:
              '$got shows in ${deps.walletName} as soon as Campfire '
              'accepts it — keep Campfire open.',
        );
      case BuyBeamState.refunded:
        return DexNotice(
          key: const Key('buy-refunded'),
          kind: DexNoticeKind.warning,
          title:
              'Your payment was sent back to '
              '${UniFormat.shortAny(o.refundAddress)}',
          detail:
              "buybeam.my couldn't buy the BEAM, so your ${o.symbol} went "
              'back to your ${o.chainName} address. There is nothing else '
              'to do.',
        );
      case BuyBeamState.expired:
        return const DexNotice(
          key: Key('buy-expired'),
          kind: DexNoticeKind.warning,
          title: 'No payment arrived in time. Nothing was taken.',
          detail:
              'This address no longer takes payments. Start a new buy '
              'to get a new one.',
        );
      case BuyBeamState.failed:
        return const DexNotice(
          key: Key('buy-failed'),
          kind: DexNoticeKind.error,
          title: "The payment couldn't be processed",
          detail:
              'Contact buybeam.my support with this order (copy it below). '
              'They can see where your coins are.',
        );
      case BuyBeamState.attention:
        return const DexNotice(
          key: Key('buy-attention'),
          kind: DexNoticeKind.warning,
          title: 'buybeam.my is checking this order',
          detail:
              'Contact their support with this order (copy it below). '
              'Campfire keeps checking meanwhile.',
        );
      case BuyBeamState.awaitingDeposit:
      case BuyBeamState.depositDetected:
      case BuyBeamState.swapping:
      case BuyBeamState.buying:
      case BuyBeamState.processing:
      case BuyBeamState.sending:
      case BuyBeamState.inProgress:
        return null;
    }
  }
}
