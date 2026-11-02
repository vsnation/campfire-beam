/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: show exactly what this DEX transaction does — what leaves the
//    wallet, what arrives, the network fee and where it goes — and send it
//    only after Campfire's PIN / password.
// 2. Primary CTA: the outcome — "Swap 0.02 BEAM", "Add liquidity",
//    "Withdraw", "Create pool".
// 3. Taps from app open: swap = wallet → Swap → amount → "Swap now" (3),
//    this screen's button is the 4th tap, then the PIN.
//
// Every number here is decoded from the transaction bytes that `execute`
// sends (`BeamPreparedDexCall`), never from the earlier quote, except the
// pool fee, which the kernel does not carry: it is labelled as included.
//
// Exit-intent — what could make an impatient person leave:
// * "Is this a scam?" — the destination is the DEX contract, named and
//   shortened, and the total leaving the wallet is in one coloured box.
// * "Is this the real FOMO?" — an asset Campfire does not vouch for is
//   named with its number everywhere on this screen ("FOMO #999"), and a
//   warning above the amounts says it is not verified, or which verified
//   asset it copies, as the swap form does.
// * A surprise fee — the network fee is its own line, from the built tx.
// * "How much is that?" — every amount, the fee and the total say what
//   they are worth in the user's currency (or "No price").
// * Pool creation's 10 BEAM deposit — a warning and a tick box before the
//   button works.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_quotes.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_service.dart';
import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/beam/dex/dex_format.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/simple_copy_button.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/rounded_white_container.dart';

enum _Phase { review, sending, sent, unknown }

/// Confirms one prepared DEX transaction and sends it.
///
/// Pops with the transaction id once sent, or null when the user went
/// back. A prepared call is sent at most once; after a failed send this
/// screen never offers to send it again.
class BeamDexConfirmView extends StatefulWidget {
  const BeamDexConfirmView({
    super.key,
    required this.deps,
    required this.prepared,
    this.priceMoved,
  });

  final BeamDexDeps deps;
  final BeamPreparedDexCall prepared;

  /// For a swap: how much less the built transaction receives than the
  /// quote did, as a fraction (already within the user's price protection).
  final BeamRatio? priceMoved;

  /// Opens the confirmation (a page on mobile, a dialog on desktop) and
  /// returns the transaction id when it was sent.
  static Future<String?> show(
    BuildContext context, {
    required BeamDexDeps deps,
    required BeamPreparedDexCall prepared,
    BeamRatio? priceMoved,
  }) => showDexPage<String>(
    context,
    deps,
    (_) => BeamDexConfirmView(
      deps: deps,
      prepared: prepared,
      priceMoved: priceMoved,
    ),
  );

  @override
  State<BeamDexConfirmView> createState() => _BeamDexConfirmViewState();
}

class _BeamDexConfirmViewState extends State<BeamDexConfirmView> {
  _Phase _phase = _Phase.review;
  bool _ackDeposit = false;
  String? _gateMessage;
  String? _txId;

  BeamDexDeps get deps => widget.deps;
  BeamPreparedDexCall get p => widget.prepared;

  late final Map<String, String> _args = {
    for (final kv in p.args.split(','))
      if (kv.contains('='))
        kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
  };

  int get _aid1 => int.parse(_args['aid1'] ?? '0');
  int get _aid2 => int.parse(_args['aid2'] ?? '0');

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_rebuild);
  }

  @override
  void dispose() {
    deps.changes.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  String get _title => switch (p.action) {
    BeamDexAction.swap => context.l10n.dexConfirmSwapTitle,
    BeamDexAction.addLiquidity => context.l10n.dexConfirmDepositTitle,
    BeamDexAction.withdraw => context.l10n.dexConfirmWithdrawalTitle,
    BeamDexAction.createPool => context.l10n.dexConfirmNewPoolTitle,
  };

  String get _heading {
    final l10n = context.l10n;
    switch (p.action) {
      case BeamDexAction.swap:
        // Trade args: aid1 = received, aid2 = paid.
        return l10n.dexConfirmSwapHeading(
          deps.assetName(_aid2),
          deps.assetName(_aid1),
        );
      case BeamDexAction.addLiquidity:
        return l10n.dexConfirmAddHeading(_pair());
      case BeamDexAction.withdraw:
        return l10n.dexConfirmWithdrawHeading(_pair());
      case BeamDexAction.createPool:
        return l10n.dexConfirmCreateHeading(_pair());
    }
  }

  String _pair() {
    final lo = _aid1 < _aid2 ? _aid1 : _aid2;
    final hi = _aid1 < _aid2 ? _aid2 : _aid1;
    return '${deps.assetLabel(lo)}/${deps.assetLabel(hi)}';
  }

  /// Assets on this screen Campfire does not vouch for, BEAM first then by
  /// id. LP tokens are left out: the DEX contract itself names those.
  List<int> get _unverified => [
    for (final a in _order({...p.pays.keys, ...p.receives.keys, _aid1, _aid2}))
      if (a != 0 && !deps.display(a).verified && deps.poolOfLpToken(a) == null)
        a,
  ];

  Widget _unverifiedNotice(int assetId) {
    final d = deps.display(assetId);
    final copied = d.impersonates == null
        ? null
        : BeamAssetCatalog.verified[d.impersonates];
    final label = deps.assetLabel(assetId);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DexNotice(
        key: Key('dex-confirm-unverified-$assetId'),
        kind: DexNoticeKind.warning,
        title: copied == null
            ? l10n.dexConfirmUnverifiedTitle(label)
            : l10n.beamAssetNotTheVerified(copied.symbol, '${copied.id}'),
        detail: copied == null
            ? l10n.dexConfirmUnverifiedDetail(d.idLabel)
            : l10n.dexConfirmImpostorDetail(label, d.idLabel),
      ),
    );
  }

  String get _cta => switch (p.action) {
    BeamDexAction.swap => _swapLabel,
    BeamDexAction.addLiquidity => context.l10n.dexAddLiquidityCta,
    BeamDexAction.withdraw => context.l10n.dexWithdrawCta,
    BeamDexAction.createPool => context.l10n.dexCreatePoolCta,
  };

  String get _done => switch (p.action) {
    BeamDexAction.swap => context.l10n.dexSentSwap,
    BeamDexAction.addLiquidity => context.l10n.dexSentDeposit,
    BeamDexAction.withdraw => context.l10n.dexSentWithdrawal,
    BeamDexAction.createPool => context.l10n.dexSentNewPool,
  };

  String _amount(int assetId, BigInt v) =>
      '${DexFormat.exact(v, places: deps.decimals(assetId))} ${deps.assetName(assetId)}';

  /// "Swap 0.02 BEAM": what the swap spends, from the built transaction.
  String get _swapLabel {
    if (p.pays.length != 1) return context.l10n.dexSwapCta;
    final paid = p.pays.entries.single;
    return context.l10n.dexSwapAmountCta(_amount(paid.key, paid.value));
  }

  /// What everything leaving the wallet is worth, when every part of it
  /// has a price.
  String? get _totalWorth {
    var groth = BigInt.zero;
    for (final e in _totalOut.entries) {
      final v = deps.valueInBeam(e.key, e.value);
      if (v == null) return null;
      groth += v;
    }
    // In BEAM too, without a fiat price, when other assets are part of it.
    return deps.worthOfBeam(groth, inBeam: _totalOut.keys.any((a) => a != 0));
  }

  /// Assets in a stable order: BEAM first, then by id.
  static List<int> _order(Iterable<int> ids) =>
      ids.toList()..sort((a, b) => a == 0 ? -1 : (b == 0 ? 1 : a - b));

  Map<int, BigInt> get _totalOut {
    final out = <int, BigInt>{...p.pays};
    out[0] = (out[0] ?? BigInt.zero) + p.fee;
    return out;
  }

  Future<void> _confirm() async {
    if (_phase != _Phase.review) return;
    // Set before the first await: a second tap lands here and returns.
    setState(() {
      _phase = _Phase.sending;
      _gateMessage = null;
    });
    final ok = await deps.authenticate(context, reason: _authReason);
    if (!mounted) return;
    if (ok != true) {
      setState(() {
        _phase = _Phase.review;
        _gateMessage = ok == false
            ? (deps.desktop
                  ? context.l10n.dexWrongPassword
                  : context.l10n.dexWrongPin)
            : null;
      });
      return;
    }
    if (!deps.canSpend) {
      setState(() {
        _phase = _Phase.review;
        _gateMessage = context.l10n.dexFellBehind;
      });
      return;
    }
    try {
      final txId = await deps.dex.execute(p);
      if (!mounted) return;
      setState(() {
        _txId = txId;
        _phase = _Phase.sent;
      });
      unawaited(deps.pools.refresh());
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _Phase.unknown);
    }
  }

  String get _authReason => switch (p.action) {
    BeamDexAction.swap => context.l10n.dexAuthSwap,
    BeamDexAction.addLiquidity => context.l10n.dexAuthAddLiquidity,
    BeamDexAction.withdraw => context.l10n.dexAuthWithdraw,
    BeamDexAction.createPool => context.l10n.dexAuthCreatePool,
  };

  void _close() => Navigator.of(context).pop(_txId);

  @override
  Widget build(BuildContext context) {
    return PopScope<String>(
      canPop: _phase != _Phase.sending,
      child: DexPage(
        deps: deps,
        // Once sent, the page itself says "Swap sent" under the sticker; a
        // title saying it too read twice.
        title: _phase == _Phase.sent ? '' : _title,
        onClose: _phase == _Phase.sending ? () {} : _close,
        body: switch (_phase) {
          _Phase.sent => _sentBody(context),
          _Phase.unknown => _unknownBody(context),
          _ => _reviewBody(context),
        },
        bottom: _bottom(context),
      ),
    );
  }

  Widget _bottom(BuildContext context) {
    switch (_phase) {
      case _Phase.sent:
      case _Phase.unknown:
        return DexPrimaryAction(
          deps: deps,
          buttonKey: const Key('dex-confirm-done'),
          label: _phase == _Phase.sent
              ? context.l10n.commonDone
              : context.l10n.commonBack,
          onPressed: _close,
        );
      case _Phase.review:
      case _Phase.sending:
        final String? reason;
        if (_phase == _Phase.sending) {
          reason = context.l10n.dexSending;
        } else if (!deps.canSpend) {
          reason = context.l10n.dexPausedUntilSynced;
        } else if (p.action == BeamDexAction.createPool && !_ackDeposit) {
          reason = context.l10n.dexTickBox;
        } else {
          reason = null;
        }
        final enabled =
            _phase == _Phase.review &&
            deps.canSpend &&
            (p.action != BeamDexAction.createPool || _ackDeposit);
        // The total sits with the button, as in Campfire's send
        // confirmation, so the number that matters is never scrolled away.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_gateMessage != null) ...[
              DexNotice(
                key: const Key('dex-gate-message'),
                kind: DexNoticeKind.error,
                title: _gateMessage!,
              ),
              const SizedBox(height: 12),
            ],
            _total(context),
            const SizedBox(height: 12),
            DexPrimaryAction(
              deps: deps,
              buttonKey: const Key('dex-confirm-cta'),
              label: _cta,
              reason: reason,
              onPressed: enabled ? _confirm : null,
            ),
          ],
        );
    }
  }

  Widget _total(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.titleBold12(context)
        .copyWith(color: colors.textConfirmTotalAmount);
    return RoundedContainer(
      color: colors.snackBarBackSuccess,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.dexTotalLeaving, style: style),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  [
                    for (final a in _order(_totalOut.keys))
                      _amount(a, _totalOut[a]!),
                  ].join(' + '),
                  key: const Key('dex-confirm-total'),
                  textAlign: TextAlign.right,
                  style: STextStyles.itemSubtitle12(context)
                      .copyWith(color: colors.textConfirmTotalAmount),
                ),
                if (_totalWorth case final worth?)
                  Text(
                    worth,
                    key: const Key('dex-confirm-total-worth'),
                    textAlign: TextAlign.right,
                    style: STextStyles.label(context)
                        .copyWith(color: colors.textConfirmTotalAmount),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewBody(BuildContext context) {
    final quote = p.quote;
    final receivesNote =
        p.action == BeamDexAction.swap && p.invoke.entries.single.isDependent;
    final l10n = context.l10n;
    final payLabel = switch (p.action) {
      BeamDexAction.createPool => l10n.dexDepositLocked,
      BeamDexAction.withdraw => l10n.dexYouReturn,
      _ => l10n.dexYouPay,
    };
    final pays = _order(p.pays.keys);
    final receives = _order(p.receives.keys);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DexSyncBanner(deps: deps),
        if (!deps.desktop) ...[
          Text(_heading, style: STextStyles.pageTitleH1(context)),
          const SizedBox(height: 12),
        ] else ...[
          Text(_heading, style: STextStyles.desktopTextMedium(context)),
          const SizedBox(height: 16),
        ],
        for (final a in _unverified) _unverifiedNotice(a),
        if (p.action == BeamDexAction.createPool) ...[
          _depositWarning(context),
          const SizedBox(height: 12),
        ],
        _card(
          context,
          children: [
            for (var i = 0; i < pays.length; i++)
              _line(
                context,
                label: i == 0 ? payLabel : '',
                id: 'pays-${pays[i]}',
                text: _amount(pays[i], p.pays[pays[i]]!),
                worth: deps.worth(pays[i], p.pays[pays[i]]!),
              ),
            for (var i = 0; i < receives.length; i++)
              _line(
                context,
                label: i == 0 ? l10n.dexYouReceive : '',
                id: 'receives-${receives[i]}',
                text: _amount(receives[i], p.receives[receives[i]]!),
                worth: deps.worth(receives[i], p.receives[receives[i]]!),
              ),
            if (receivesNote)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.dexSwapRedoNote,
                  style: STextStyles.label(context),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          context,
          children: [
            if (quote is BeamSwapQuote)
              _line(
                context,
                label: l10n.dexPoolFeeIncluded(quote.kind.feePercent),
                id: 'pool-fee',
                text: _amount(quote.payAsset, quote.fee),
              ),
            _line(
              context,
              label: l10n.beamNetworkFee,
              id: 'fee',
              text: _amount(0, p.fee),
              worth: deps.worthOfBeam(p.fee),
            ),
            _line(
              context,
              label: l10n.dexSentTo,
              id: 'destination',
              text: p.contractId == kDexContractId
                  ? l10n.dexDestinationDex(DexFormat.shortId(p.contractId))
                  : l10n.dexDestinationContract(
                      DexFormat.shortId(p.contractId),
                    ),
            ),
          ],
        ),
        if (widget.priceMoved != null && !widget.priceMoved!.isZero) ...[
          const SizedBox(height: 12),
          DexNotice(
            kind: DexNoticeKind.info,
            title: l10n.dexPriceMovedTitle(
              DexFormat.percent(widget.priceMoved!),
            ),
            detail: l10n.dexPriceMovedWithin,
          ),
        ],
      ],
    );
  }

  Widget _depositWarning(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final deposit =
        '${DexFormat.exact(p.pays[0] ?? kDexPoolCreateDeposit)} BEAM';
    final l10n = context.l10n;
    return RoundedContainer(
      color: colors.warningBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 20,
                color: colors.warningForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.dexConfirmDepositWarning(deposit),
                  key: const Key('dex-create-warning'),
                  style: STextStyles.smallMed14(context)
                      .copyWith(color: colors.warningForeground),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l10n.dexConfirmNewPoolEmpty,
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.warningForeground),
          ),
          const SizedBox(height: 4),
          InkWell(
            key: const Key('dex-create-ack'),
            onTap: () => setState(() => _ackDeposit = !_ackDeposit),
            child: Row(
              children: [
                Checkbox(
                  value: _ackDeposit,
                  onChanged: (v) => setState(() => _ackDeposit = v ?? false),
                  activeColor: colors.checkboxBGChecked,
                  checkColor: colors.checkboxIconChecked,
                ),
                Expanded(
                  child: Text(
                    l10n.dexConfirmDepositAck(deposit),
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.warningForeground),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required List<Widget> children}) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      borderColor: deps.desktop ? colors.background : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// "label · exact value", the value selectable so it can be checked,
  /// with what it is worth under it ([worth]: "≈ 1.20 USD", "No price").
  /// Keys: `dex-confirm-<id>` and `dex-confirm-<id>-worth`.
  Widget _line(
    BuildContext context, {
    required String label,
    required String id,
    required String text,
    String? worth,
  }) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final value = SelectableText(
      text,
      key: Key('dex-confirm-$id'),
      textAlign: TextAlign.right,
      style: STextStyles.itemSubtitle12(context)
          .copyWith(color: colors.textDark),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: STextStyles.smallMed12(context)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: worth == null
                ? value
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      value,
                      Text(
                        worth,
                        key: Key('dex-confirm-$id-worth'),
                        textAlign: TextAlign.right,
                        style: STextStyles.label(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sentBody(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    // "0.5 BEAM and 0.0001 bETH": each further amount joins the list the
    // same way.
    final arriving = p.receives.isEmpty
        ? null
        : [for (final a in _order(p.receives.keys)) _amount(a, p.receives[a]!)]
              .reduce(l10n.dexAmountsAnd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        // The Beam girl celebrates a finished swap (never on the review
        // step); other DEX actions keep Campfire's check mark.
        if (p.action == BeamDexAction.swap)
          const Center(
            child: BeamAnimatedStickerView(
              BeamMoments.swapDone,
              key: Key('dex-swap-done-sticker'),
              size: 120,
            ),
          )
        else
          Icon(
            Icons.check_circle_rounded,
            size: 64,
            color: colors.accentColorGreen,
          ),
        const SizedBox(height: 12),
        Text(
          _done,
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH1(context),
        ),
        const SizedBox(height: 8),
        Text(
          p.action == BeamDexAction.createPool
              ? l10n.dexDoneCreatePool
              : arriving == null
              ? l10n.dexDoneConfirms
              : l10n.dexDoneArriving(arriving),
          textAlign: TextAlign.center,
          style: STextStyles.smallMed14(context),
        ),
        const SizedBox(height: 20),
        RoundedWhiteContainer(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    l10n.dexTransactionId,
                    style: STextStyles.smallMed12(context),
                  ),
                  SimpleCopyButton(data: _txId ?? ''),
                ],
              ),
              const SizedBox(height: 4),
              SelectableText(
                _txId ?? '',
                key: const Key('dex-success-txid'),
                style: STextStyles.itemSubtitle12(context),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unknownBody(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        DexNotice(
          key: const Key('dex-send-unknown'),
          kind: DexNoticeKind.warning,
          title: context.l10n.dexSendUnknownTitle,
          detail: context.l10n.dexSendUnknownDetail,
        ),
      ],
    );
  }
}
