/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: let Uniswap's Permit2 contract move this token, for exactly
//    the amount being swapped unless the user asks for more, before the
//    first swap of it.
// 2. Primary CTA: "Allow 1,000 WBEAM".
// 3. One extra step, once per token and amount: the swap form's button
//    opens it, the PIN confirms it, then the swap review follows by itself.
//
// Exit-intent: "Why another transaction?" is answered in one line;
// "Is this unlimited?" — no, the exact amount is the default and named on
// the button; USDT's two steps are said before they happen; the network
// fee is shown before the PIN.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/eth_rpc.dart';
import '../../../wallets/ethereum/uniswap/uniswap_constants.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';

enum _Phase { choose, sending, waiting, failed }

/// Pops true once Permit2 may take the token (the approval is mined).
class UniswapApproveView extends StatefulWidget {
  const UniswapApproveView({
    super.key,
    required this.deps,
    required this.approval,
  });

  final UniswapDeps deps;
  final UniApproval approval;

  static Future<bool?> show(
    BuildContext context, {
    required UniswapDeps deps,
    required UniApproval approval,
  }) => showDexPage<bool>(
    context,
    deps,
    (_) => UniswapApproveView(deps: deps, approval: approval),
  );

  @override
  State<UniswapApproveView> createState() => _UniswapApproveViewState();
}

class _UniswapApproveViewState extends State<UniswapApproveView> {
  bool _unlimited = false;
  _Phase _phase = _Phase.choose;
  UniFees? _fees;
  String? _error;
  String? _hash;

  UniswapDeps get deps => widget.deps;
  UniApproval get a => widget.approval;
  bool get _twoSteps => a.kind == UniApprovalKind.resetThenApprove;

  static final _max = (BigInt.one << 256) - BigInt.one;

  @override
  void initState() {
    super.initState();
    unawaited(
      deps.service.fees().then((f) {
        if (mounted) setState(() => _fees = f);
      }, onError: (Object _) {}),
    );
  }

  String get _amountText =>
      '${UniFormat.exact(a.amount, a.token.decimals)} ${a.token.symbol}';

  Future<void> _allow() async {
    final ok = await deps.authenticate(
      context,
      reason: 'Authenticate to allow ${a.token.symbol}',
    );
    if (ok != true || !mounted) return;
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    try {
      if (_twoSteps) {
        final reset = await deps.service.approvalTx(
          token: a.token,
          amount: BigInt.zero,
          owner: deps.signer.address,
        );
        final h = await deps.signer.send(
          reset.withNote('Uniswap: reset ${a.token.symbol} permission to 0'),
        );
        setState(() {
          _phase = _Phase.waiting;
          _hash = h;
        });
        final r = await deps.service.waitForReceipt(h);
        if (r == null || !r.success) throw StateError('reset not mined');
        if (!mounted) return;
        setState(() => _phase = _Phase.sending);
      }
      final tx = await deps.service.approvalTx(
        token: a.token,
        amount: _unlimited ? _max : a.amount,
        owner: deps.signer.address,
      );
      final hash = await deps.signer.send(
        tx.withNote(
          _unlimited
              ? 'Uniswap: allow any amount of ${a.token.symbol}'
              : 'Uniswap: allow $_amountText',
        ),
      );
      if (!mounted) return;
      setState(() {
        _phase = _Phase.waiting;
        _hash = hash;
      });
      final r = await deps.service.waitForReceipt(hash);
      if (!mounted) return;
      if (r != null && r.success) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _phase = _Phase.failed;
        _error = r == null
            ? 'Ethereum has not confirmed it yet. It may still go through; '
                  'try the swap again in a minute.'
            : 'Ethereum refused it. Nothing was approved.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = e is EthRpcError
            ? 'Your Ethereum node said: "${e.message}". Nothing was approved.'
            : 'It did not go through. Nothing was approved.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final busy = _phase == _Phase.sending || _phase == _Phase.waiting;
    final fee = _fees == null
        ? null
        : BigInt.from(_twoSteps ? 120000 : 60000) *
              (_fees!.baseFee + _fees!.maxPriorityFeePerGas);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Before ${a.token.symbol} can be swapped, Ethereum needs your '
          'permission for Uniswap to move it. This is its own transaction; '
          'nothing is swapped yet, and the swap comes right after.',
          style: STextStyles.smallMed14(context),
        ),
        const SizedBox(height: 12),
        DexChoiceChips<bool>(
          values: const [false, true],
          selected: _unlimited,
          labelOf: (v) => v ? 'Any amount' : 'Only $_amountText',
          keyOf: (v) => Key('uni-approve-${v ? 'any' : 'exact'}'),
          onSelected: (v) {
            if (!busy) setState(() => _unlimited = v);
          },
        ),
        const SizedBox(height: 8),
        Text(
          _unlimited
              ? 'No permission needed next time. Each swap still needs your '
                    'PIN and a signature that lasts 30 minutes.'
              : 'Exactly what this swap uses. The next swap of '
                    '${a.token.symbol} asks again.',
          key: const Key('uni-approve-explain'),
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        if (_twoSteps) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('uni-approve-two-steps'),
            kind: DexNoticeKind.info,
            title: '${a.token.symbol} takes two steps',
            detail:
                '${a.token.symbol} only changes a permission from zero, so '
                'Campfire first sets the old one to 0, then to the new '
                'amount: two transactions, one PIN.',
          ),
        ],
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(
                address: true,
                label: 'Token',
                value:
                    '${a.token.symbol} (${UniFormat.short(a.token.address)})',
              ),
              DexDetailRow(
                address: true,
                label: 'Allowed to move it',
                value:
                    'Uniswap Permit2 '
                    '(${UniFormat.short(UniswapAddresses.permit2)})',
              ),
              DexDetailRow(
                label: 'Network fee',
                valueKey: const Key('uni-approve-fee'),
                value: fee == null
                    ? '…'
                    : '≈ ${UniFormat.compact(fee, 18)} ETH',
                note: fee == null ? null : deps.worth(UniToken.eth, fee),
              ),
            ],
          ),
        ),
        if (_phase == _Phase.waiting) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('uni-approve-waiting'),
            title: 'Waiting for Ethereum to confirm…',
            detail:
                'Usually under a minute. The swap review opens by itself.'
                '${_hash == null ? '' : '\n${UniFormat.short(_hash!)}'}',
          ),
        ],
        if (_phase == _Phase.failed && _error != null) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('uni-approve-failed'),
            sticker: BeamMoments.somethingWentWrong,
            kind: DexNoticeKind.error,
            title: "The permission didn't go through",
            detail: _error,
          ),
        ],
      ],
    );
    return DexPage(
      deps: deps,
      title: 'Allow ${a.token.symbol}',
      body: body,
      onClose: busy ? () {} : null,
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('uni-approve-cta'),
        label: _unlimited
            ? 'Allow any amount of ${a.token.symbol}'
            : 'Allow $_amountText',
        reason: switch (_phase) {
          _Phase.sending => 'Sending…',
          _Phase.waiting => 'Waiting for Ethereum…',
          _ => null,
        },
        onPressed: busy ? null : _allow,
      ),
    );
  }
}
