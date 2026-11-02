/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: show exactly what this name transaction does — what leaves
//    the wallet, the network fee, where the money goes, and for a transfer
//    the new owner's key — and sign it only after Campfire's PIN/password.
// 2. Primary CTA: the outcome — "Pay & register alice", "Pay & renew
//    alice", "Transfer alice", "List alice for sale", "Stop selling alice",
//    "Buy alice", "Claim 500 BEAM".
// 3. Taps from app open: register = Names (1) → Get a name (2) → Get alice
//    (3) → this button (4) → PIN. Renew = Names → alice → Renew → this.
//
// Every number is decoded from the transaction the core built
// (`BansPrepared.summary`), never from the earlier estimate. Right after
// the PIN the transaction is built once more from the chain as it is now:
// if the BEAM price (or a seller's price, or the amount waiting) moved,
// nothing is sent and the new total is shown for a fresh confirmation.
//
// Exit-intent — what could make an impatient person leave:
// * "Why is $10 1,162 BEAM?" — the dollar price sits next to the BEAM
//   amount with one line saying who sets it and why it is paid in BEAM.
// * A surprise fee — the network fee is its own line, from the built tx.
// * "Did I just give my name to a stranger?" — a transfer shows 16
//   characters of the key (64 bits, `BansKey.checkCode`) in large type,
//   says it cannot be undone, and needs a tick that all 16 were checked.
// * "Buying a name for 100,000 BEAM and it expires next month?" — a
//   purchase says, before signing, that it does not renew the name.
// * A price that changed under the user — never signed silently; the new
//   total is shown first.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';

enum _Phase { review, checking, sending, failed, unknown }

/// Confirms one prepared BANS transaction and sends it.
///
/// Pops with a [BeamNameSent] once sent, or null when the user went back.
/// The success moment is shown by the screen it returns to, not here.
class BeamNameConfirmView extends StatefulWidget {
  const BeamNameConfirmView({
    super.key,
    required this.deps,
    required this.prepared,
    required this.rebuild,
    this.clock,
  });

  final BeamNamesDeps deps;
  final BansPrepared prepared;

  /// Builds the same transaction again from the chain as it is now. Runs
  /// after the PIN, right before signing.
  final Future<BansPrepared> Function() rebuild;

  /// The wallet's last block, to turn heights into dates.
  final BansClock? clock;

  /// Opens the confirmation (a page on mobile, a dialog on desktop).
  static Future<BeamNameSent?> show(
    BuildContext context, {
    required BeamNamesDeps deps,
    required BansPrepared prepared,
    required Future<BansPrepared> Function() rebuild,
    BansClock? clock,
  }) => showNamesPage<BeamNameSent>(
    context,
    deps,
    (_) => BeamNameConfirmView(
      deps: deps,
      prepared: prepared,
      rebuild: rebuild,
      clock: clock,
    ),
  );

  @override
  State<BeamNameConfirmView> createState() => _BeamNameConfirmViewState();
}

class _BeamNameConfirmViewState extends State<BeamNameConfirmView> {
  late BansPrepared _p = widget.prepared;
  _Phase _phase = _Phase.review;
  bool _moved = false;
  bool _ack = false;
  bool _showBlocks = false;
  String? _error;
  String? _gateMessage;

  /// Set synchronously by the first tap, before the PIN / password gate
  /// opens, and cleared when this attempt ends. A second activation that
  /// lands first (same frame, a held key) returns at once instead of
  /// opening a second gate, which could pay twice.
  bool _inFlight = false;

  BeamNamesDeps get deps => widget.deps;
  BansSummary get s => _p.summary;
  String get _name => s.name?.value ?? '';

  bool get _unlisting =>
      s.action == BansAction.setPrice &&
      (s.listPrice == null || s.listPrice!.amount == BigInt.zero);

  @override
  void initState() {
    super.initState();
    deps.sync.addListener(_rebuildUi);
    deps.balances.addListener(_rebuildUi);
  }

  @override
  void dispose() {
    deps.sync.removeListener(_rebuildUi);
    deps.balances.removeListener(_rebuildUi);
    super.dispose();
  }

  void _toggleBlocks() => setState(() => _showBlocks = !_showBlocks);

  void _rebuildUi() {
    if (mounted) setState(() {});
  }

  String _amount(BansAmount a) =>
      '${NamesFormat.exact(a.amount, places: deps.decimals(a.assetId))} ${deps.symbol(a.assetId)}';

  String _beam(BigInt v) => '${NamesFormat.exact(v)} BEAM';

  String get _title {
    final l10n = context.l10n;
    return switch (s.action) {
      BansAction.register => l10n.namesConfirmRegistrationTitle,
      BansAction.extend => l10n.namesConfirmRenewalTitle,
      BansAction.setOwner => l10n.namesConfirmTransferTitle,
      BansAction.setPrice =>
        _unlisting ? l10n.namesStopSellingTitle : l10n.namesConfirmListingTitle,
      BansAction.buy => l10n.namesConfirmPurchaseTitle,
      BansAction.claimAll ||
      BansAction.claimSaleProceeds ||
      BansAction.pay => l10n.namesConfirmClaimTitle,
    };
  }

  String get _heading {
    final l10n = context.l10n;
    // Register and renew always carry their years.
    final years = s.periods ?? 1;
    return switch (s.action) {
      BansAction.register => l10n.namesHeadingRegister(_name, years),
      BansAction.extend => l10n.namesHeadingRenew(_name, years),
      BansAction.setOwner => l10n.namesHeadingTransfer(_name),
      BansAction.setPrice =>
        _unlisting
            ? l10n.namesHeadingUnlist(_name)
            : l10n.namesListNameFor(_name, _amount(s.listPrice!)),
      BansAction.buy => l10n.namesBuyName(_name),
      BansAction.claimSaleProceeds ||
      BansAction.claimAll => l10n.namesHeadingClaimSale,
      BansAction.pay => l10n.namesHeadingSend(_name),
    };
  }

  String get _cta {
    final l10n = context.l10n;
    return switch (s.action) {
      BansAction.register => l10n.namesPayAndRegister(_name),
      BansAction.extend => l10n.namesPayAndRenew(_name),
      BansAction.setOwner => l10n.namesTransferName(_name),
      BansAction.setPrice =>
        _unlisting
            ? l10n.namesStopSellingName(_name)
            : l10n.namesListForSale(_name),
      BansAction.buy => l10n.namesBuyName(_name),
      BansAction.claimAll || BansAction.claimSaleProceeds =>
        l10n.namesClaimAmount(s.youReceive.map(_amount).join(' + ')),
      BansAction.pay => l10n.namesSend,
    };
  }

  String get _authReason {
    final l10n = context.l10n;
    return switch (s.action) {
      BansAction.register => l10n.namesAuthRegister(_name),
      BansAction.extend => l10n.namesAuthRenew(_name),
      BansAction.setOwner => l10n.namesAuthTransfer(_name),
      BansAction.setPrice => l10n.namesAuthChangeSale(_name),
      BansAction.buy => l10n.namesAuthBuy(_name),
      _ => l10n.namesAuthClaim,
    };
  }

  /// What the wallet lacks for this transaction, in words; null when it
  /// has enough (or its balance is not known yet).
  String? get _shortfall {
    for (final a in s.youPay.where((a) => a.assetId != 0)) {
      final have = deps.available(a.assetId);
      if (have != null && have < a.amount) {
        return context.l10n.namesYouHaveThisNeeds(
          '${NamesFormat.readable(have, places: deps.decimals(a.assetId))} ${deps.symbol(a.assetId)}',
          '${NamesFormat.readable(a.amount, places: deps.decimals(a.assetId))} ${deps.symbol(a.assetId)}',
        );
      }
    }
    var need = s.totalBeam;
    for (final r in s.youReceive.where((r) => r.assetId == 0)) {
      need -= r.amount; // a BEAM claim pays its own fee
    }
    if (need <= BigInt.zero) return null;
    final have = deps.available(0);
    if (have != null && have < need) {
      return context.l10n.namesYouHaveThisNeeds(
        '${NamesFormat.readable(have)} BEAM',
        '${NamesFormat.readable(need)} BEAM',
      );
    }
    return null;
  }

  static bool _sameMoney(BansSummary a, BansSummary b) =>
      listEquals(a.youPay, b.youPay) &&
      listEquals(a.youReceive, b.youReceive) &&
      a.fee == b.fee &&
      a.ownerKey == b.ownerKey &&
      a.listPrice == b.listPrice &&
      a.periods == b.periods;

  Future<void> _confirm() async {
    if (_inFlight) return;
    setState(() {
      _inFlight = true;
      _gateMessage = null;
      _error = null;
    });
    try {
      await _authorizeAndSend();
    } finally {
      if (mounted) {
        setState(() => _inFlight = false);
      } else {
        _inFlight = false;
      }
    }
  }

  Future<void> _authorizeAndSend() async {
    final ok = await deps.authenticate(context, reason: _authReason);
    if (!mounted) return;
    if (ok != true) {
      setState(() {
        _gateMessage = ok == false
            ? (deps.desktop
                  ? context.l10n.namesWrongPassword
                  : context.l10n.namesWrongPin)
            : null;
      });
      return;
    }
    setState(() => _phase = _Phase.checking);
    final BansPrepared fresh;
    try {
      fresh = await widget.rebuild();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = joinSentences([
          context.l10n.namesNothingSent,
          namesErrorText(e),
        ]);
      });
      return;
    }
    if (!mounted) return;
    if (!_sameMoney(s, fresh.summary)) {
      setState(() {
        _p = fresh;
        _moved = true;
        _phase = _Phase.review;
      });
      return;
    }
    setState(() {
      _p = fresh;
      _phase = _Phase.sending;
    });
    final String txId;
    try {
      txId = await deps.bans.execute(fresh);
    } catch (e) {
      if (!mounted) return;
      // The core answering with an error means it refused the
      // transaction; anything else (no answer, a dropped connection) leaves
      // the outcome unknown, and retrying could pay twice.
      final refused = e is BeamRpcException || e is BansException;
      setState(() {
        _phase = refused ? _Phase.failed : _Phase.unknown;
        _error = refused
            ? joinSentences([context.l10n.namesNothingSent, namesErrorText(e)])
            : context.l10n.namesSendUnknown;
      });
      return;
    }
    _recordPending(txId, fresh.summary);
    if (s.action == BansAction.claimSaleProceeds ||
        s.action == BansAction.claimAll) {
      unawaited(deps.inboxMonitor?.refresh(force: true));
    }
    if (!mounted) return;
    Navigator.of(context).pop(BeamNameSent(txId: txId, summary: fresh.summary));
  }

  void _recordPending(String txId, BansSummary sum) {
    final name = sum.name?.value;
    if (name == null) return;
    final kind = switch (sum.action) {
      BansAction.register => BansPendingKind.register,
      BansAction.extend => BansPendingKind.renew,
      BansAction.setOwner => BansPendingKind.transfer,
      BansAction.setPrice =>
        _unlisting ? BansPendingKind.unlist : BansPendingKind.list,
      BansAction.buy => BansPendingKind.buy,
      _ => null,
    };
    if (kind == null) return;
    deps.pending.add(
      BansPendingName(
        name: name,
        kind: kind,
        txId: txId,
        sentAt: DateTime.now(),
        expireAtLeast: sum.action == BansAction.extend
            ? sum.expireHeight
            : null,
        listPrice: kind == BansPendingKind.list ? sum.listPrice : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    return NamesPage(
      deps: deps,
      title: _title,
      onClose: _phase == _Phase.sending || _phase == _Phase.checking
          ? () {}
          : null,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NamesSyncBanner(deps: deps),
          if (_moved) ...[
            NamesNotice(
              key: const Key('names-confirm-moved'),
              kind: NamesNoticeKind.warning,
              title: switch (s.action) {
                BansAction.buy => l10n.namesMovedSellerPrice,
                BansAction.claimSaleProceeds ||
                BansAction.claimAll => l10n.namesMovedClaimAmount,
                _ => l10n.namesMovedBeamPrice,
              },
              detail: s.action == BansAction.buy
                  ? l10n.namesMovedBuyDetail
                  : l10n.namesMovedRateDetail,
            ),
            const SizedBox(height: 12),
          ],
          Text(
            _heading,
            key: const Key('names-confirm-heading'),
            style: deps.desktop
                ? STextStyles.desktopTextMedium(context)
                : STextStyles.pageTitleH2(context),
          ),
          const SizedBox(height: 12),
          NamesCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _rows(colors),
            ),
          ),
          const SizedBox(height: 12),
          _totalBox(),
          ..._afterTotal(colors),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NamesNotice(
              key: const Key('names-confirm-error'),
              kind: _phase == _Phase.unknown
                  ? NamesNoticeKind.warning
                  : NamesNoticeKind.error,
              title: _phase == _Phase.unknown
                  ? l10n.namesNotSureSent
                  : l10n.namesNotSent,
              detail: _error,
            ),
          ],
          if (_gateMessage != null) ...[
            const SizedBox(height: 12),
            NamesNotice(
              key: const Key('names-confirm-gate'),
              kind: NamesNoticeKind.warning,
              title: _gateMessage!,
            ),
          ],
        ],
      ),
      bottom: _bottom(),
    );
  }

  List<Widget> _rows(StackColors colors) {
    final l10n = context.l10n;
    final clock = widget.clock;
    String? dateOf(int? h) => h == null || clock == null
        ? null
        : '≈ ${NamesFormat.date(clock.dateOf(h))}';
    final rows = <Widget>[
      NamesDetailRow(
        label: l10n.namesRowName,
        value: s.name?.display ?? '',
        valueKey: const Key('names-confirm-name'),
      ),
    ];
    switch (s.action) {
      case BansAction.register:
      case BansAction.extend:
        final until = dateOf(s.expireHeight);
        if (until != null) {
          rows.add(
            NamesDetailRow(
              label: s.action == BansAction.register
                  ? l10n.namesRowYoursUntil
                  : l10n.namesRowRenewedUntil,
              value: until,
              valueKey: const Key('names-confirm-expiry'),
              sub: _showBlocks ? NamesFormat.block(s.expireHeight!) : null,
              onTap: _toggleBlocks,
            ),
          );
        }
        rows.add(
          NamesDetailRow(
            label: s.action == BansAction.register
                ? l10n.namesRowNamePrice
                : l10n.namesPriceLabel,
            value: s.youPay.map(_amount).join(' + '),
            valueKey: const Key('names-confirm-pay-0'),
            sub: s.usdTotal == null
                ? null
                : l10n.namesUsdForYears(
                    NamesFormat.usd(s.usdTotal!),
                    s.periods ?? 1,
                  ),
          ),
        );
        rows.add(_feeRow());
        rows.add(
          NamesDetailRow(
            label: l10n.namesRowPaidTo,
            value: l10n.namesPaidToDaoVault,
            sub: _shortCid(s.contractId),
          ),
        );
      case BansAction.buy:
        rows.add(
          NamesDetailRow(
            label: l10n.namesRowSellerPrice,
            value: s.youPay.map(_amount).join(' + '),
            valueKey: const Key('names-confirm-pay-0'),
          ),
        );
        rows.add(_feeRow());
        final until = dateOf(s.expireHeight);
        if (until != null) {
          rows.add(
            NamesDetailRow(
              label: l10n.namesRowYoursUntil,
              value: until,
              valueKey: const Key('names-confirm-expiry'),
              sub: _showBlocks ? NamesFormat.block(s.expireHeight!) : null,
              onTap: _toggleBlocks,
            ),
          );
        }
        rows.add(
          NamesDetailRow(
            label: l10n.namesRowPaidTo,
            value: l10n.namesPaidToSeller,
          ),
        );
      case BansAction.setOwner:
        rows.add(_feeRow());
      case BansAction.setPrice:
        rows.add(
          NamesDetailRow(
            label: l10n.namesPriceLabel,
            value: _unlisting ? l10n.namesNotForSale : _amount(s.listPrice!),
            valueKey: const Key('names-confirm-price'),
          ),
        );
        rows.add(_feeRow());
      case BansAction.claimSaleProceeds:
      case BansAction.claimAll:
      case BansAction.pay:
        rows.removeAt(0);
        for (final r in s.youReceive) {
          rows.add(
            NamesDetailRow(
              label: l10n.namesRowYouReceive,
              value: _amount(r),
              valueKey: Key('names-confirm-receive-${r.assetId}'),
            ),
          );
        }
        rows.add(_feeRow());
    }
    return rows;
  }

  Widget _feeRow() => NamesDetailRow(
    label: context.l10n.beamNetworkFee,
    value: _beam(s.fee),
    valueKey: const Key('names-confirm-fee'),
  );

  static String _shortCid(String cid) => cid.length < 16
      ? cid
      : '${cid.substring(0, 6)}…${cid.substring(cid.length - 6)}';

  Widget _totalBox() {
    final isClaim =
        s.action == BansAction.claimSaleProceeds ||
        s.action == BansAction.claimAll;
    if (isClaim) {
      final beamIn = s.youReceive
          .where((r) => r.assetId == 0)
          .fold(BigInt.zero, (t, r) => t + r.amount);
      if (beamIn > BigInt.zero) {
        return NamesTotalBox(
          label: context.l10n.namesTotalYouGet,
          value: _beam(beamIn - s.fee),
          valueKey: const Key('names-confirm-total'),
        );
      }
    }
    final tokens = s.youPay.where((a) => a.assetId != 0).map(_amount);
    return NamesTotalBox(
      label: context.l10n.namesTotal,
      value: [_beam(s.totalBeam), ...tokens].join(' + '),
      valueKey: const Key('names-confirm-total'),
    );
  }

  List<Widget> _afterTotal(StackColors colors) {
    final l10n = context.l10n;
    final rate = s.usdPerBeamText;
    final note = switch (s.action) {
      BansAction.register || BansAction.extend =>
        rate == null
            ? l10n.namesConfirmPriceNote
            : l10n.namesConfirmPriceNoteRate(rate),
      BansAction.buy => l10n.namesBuyNote,
      BansAction.setPrice =>
        _unlisting ? l10n.namesUnlistNote(_name) : l10n.namesListNote(_name),
      BansAction.claimSaleProceeds || BansAction.claimAll =>
        s.youReceive.any((r) => r.assetId == 0)
            ? l10n.namesClaimFeeFromClaim
            : l10n.namesClaimFeeFromBeam,
      _ => null,
    };
    final out = <Widget>[];
    if (note != null) {
      out
        ..add(const SizedBox(height: 12))
        ..add(
          Text(
            note,
            key: const Key('names-confirm-note'),
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        );
    }
    if (s.action == BansAction.setOwner) {
      out.addAll([
        const SizedBox(height: 12),
        NamesCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.namesNewOwner,
                style: STextStyles.smallMed12(context)
                    .copyWith(color: colors.infoItemLabel),
              ),
              const SizedBox(height: 4),
              Text(
                BansKey.checkCode(s.ownerKey!),
                key: const Key('names-confirm-fingerprint'),
                style: STextStyles.pageTitleH1(context),
              ),
              const SizedBox(height: 4),
              SelectableText(
                s.ownerKey!,
                style: STextStyles.smallMed12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        NamesNotice(
          kind: NamesNoticeKind.warning,
          title: l10n.namesCantBeUndone,
          detail: l10n.namesTransferIrreversible(
            _name,
            BansKey.checkCode(s.ownerKey!),
          ),
        ),
      ]);
    }
    return out;
  }

  /// The transfer's "I checked the key" tick, pinned right above the
  /// button it unlocks.
  Widget _ackBox() => CheckboxListTile(
    key: const Key('names-confirm-ack'),
    contentPadding: EdgeInsets.zero,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    value: _ack,
    onChanged: _phase == _Phase.review || _phase == _Phase.failed
        ? (v) => setState(() => _ack = v ?? false)
        : null,
    title: Text(
      context.l10n.namesAckCheckCode(
        BansKey.checkCodeLength,
        BansKey.checkCode(s.ownerKey!),
      ),
      style: STextStyles.smallMed12(context),
    ),
  );

  Widget _bottom() {
    final action = _action();
    if (s.action != BansAction.setOwner || _phase == _Phase.unknown) {
      return action;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_ackBox(), action],
    );
  }

  Widget _action() {
    final l10n = context.l10n;
    final busy = _phase == _Phase.checking || _phase == _Phase.sending;
    if (_phase == _Phase.unknown) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: l10n.namesBackToMyNames,
        onPressed: () => Navigator.of(context).pop(),
      );
    }
    if (busy) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: _phase == _Phase.checking
            ? l10n.namesCheckingPriceAgain
            : l10n.namesSending,
        onPressed: null,
      );
    }
    if (!deps.canSpend) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: _cta,
        onPressed: null,
        reason: l10n.namesSigningPaused,
      );
    }
    final short = _shortfall;
    if (short != null) {
      final add = deps.onAddFunds;
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: add == null ? _cta : l10n.namesAddBeam,
        onPressed: add,
        reason: short,
      );
    }
    if (s.action == BansAction.setOwner && !_ack) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: _cta,
        onPressed: null,
        reason: l10n.namesTickBox,
      );
    }
    return NamesPrimaryAction(
      deps: deps,
      buttonKey: const Key('names-confirm-cta'),
      label: _cta,
      onPressed: _inFlight ? null : _confirm,
    );
  }
}
