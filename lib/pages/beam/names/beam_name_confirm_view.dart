/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
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
// Exit-intent (§1.7) — what could make an impatient person leave:
// * "Why is $10 1,162 BEAM?" — the dollar price sits next to the BEAM
//   amount with one line saying who sets it and why it is paid in BEAM.
// * A surprise fee — the network fee is its own line, from the built tx.
// * "Did I just give my name to a stranger?" — a transfer shows the key's
//   fingerprint in large type, says it cannot be undone, and needs a tick.
// * "Buying a name for 100,000 BEAM and it expires next month?" — a
//   purchase says, before signing, that it does not renew the name.
// * A price that changed under the user — never signed silently; the new
//   total is shown first.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
      '${NamesFormat.exact(a.amount)} ${deps.symbol(a.assetId)}';

  String _beam(BigInt v) => '${NamesFormat.exact(v)} BEAM';

  String get _title => switch (s.action) {
    BansAction.register => 'Confirm registration',
    BansAction.extend => 'Confirm renewal',
    BansAction.setOwner => 'Confirm transfer',
    BansAction.setPrice => _unlisting ? 'Stop selling' : 'Confirm listing',
    BansAction.buy => 'Confirm purchase',
    BansAction.claimAll ||
    BansAction.claimSaleProceeds ||
    BansAction.pay => 'Confirm claim',
  };

  String get _heading {
    final years = s.periods == null ? '' : NamesFormat.years(s.periods!);
    return switch (s.action) {
      BansAction.register => 'Register $_name for $years',
      BansAction.extend => 'Renew $_name for $years',
      BansAction.setOwner => 'Give $_name to another wallet',
      BansAction.setPrice =>
        _unlisting
            ? 'Take $_name off sale'
            : 'List $_name for ${_amount(s.listPrice!)}',
      BansAction.buy => 'Buy $_name',
      BansAction.claimSaleProceeds ||
      BansAction.claimAll => 'Claim the money from your name sale',
      BansAction.pay => 'Send to $_name',
    };
  }

  String get _cta => switch (s.action) {
    BansAction.register => 'Pay & register $_name',
    BansAction.extend => 'Pay & renew $_name',
    BansAction.setOwner => 'Transfer $_name',
    BansAction.setPrice =>
      _unlisting ? 'Stop selling $_name' : 'List $_name for sale',
    BansAction.buy => 'Buy $_name',
    BansAction.claimAll || BansAction.claimSaleProceeds =>
      'Claim ${s.youReceive.map(_amount).join(' + ')}',
    BansAction.pay => 'Send',
  };

  String get _authReason => switch (s.action) {
    BansAction.register => 'Authenticate to register $_name',
    BansAction.extend => 'Authenticate to renew $_name',
    BansAction.setOwner => 'Authenticate to transfer $_name',
    BansAction.setPrice => 'Authenticate to change the sale of $_name',
    BansAction.buy => 'Authenticate to buy $_name',
    _ => 'Authenticate to claim',
  };

  /// What the wallet lacks for this transaction, in words; null when it
  /// has enough (or its balance is not known yet).
  String? get _shortfall {
    for (final a in s.youPay.where((a) => a.assetId != 0)) {
      final have = deps.available(a.assetId);
      if (have != null && have < a.amount) {
        return 'You have ${NamesFormat.readable(have)} '
            '${deps.symbol(a.assetId)}; this needs '
            '${NamesFormat.readable(a.amount)} ${deps.symbol(a.assetId)}.';
      }
    }
    var need = s.totalBeam;
    for (final r in s.youReceive.where((r) => r.assetId == 0)) {
      need -= r.amount; // a BEAM claim pays its own fee
    }
    if (need <= BigInt.zero) return null;
    final have = deps.available(0);
    if (have != null && have < need) {
      return 'You have ${NamesFormat.readable(have)} BEAM; this needs '
          '${NamesFormat.readable(need)} BEAM.';
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
    setState(() {
      _gateMessage = null;
      _error = null;
    });
    final ok = await deps.authenticate(context, reason: _authReason);
    if (!mounted) return;
    if (ok != true) {
      setState(() {
        _gateMessage = ok == false
            ? (deps.desktop
                  ? "That password didn't match. Nothing was sent."
                  : "That PIN didn't match. Nothing was sent.")
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
        _error = 'Nothing was sent. ${namesErrorText(e)}';
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
            ? 'Nothing was sent. ${namesErrorText(e)}'
            : "We couldn't confirm whether it was sent. Check your "
                  'transaction history before trying again, so nothing is '
                  'paid twice.';
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
                BansAction.buy =>
                  'The seller changed the price; here is the new total.',
                BansAction.claimSaleProceeds || BansAction.claimAll =>
                  'The amount waiting changed; here is the new amount.',
                _ => 'The BEAM price moved; here is the new total.',
              },
              detail: s.action == BansAction.buy
                  ? 'Nothing was sent. Check the new price and confirm again.'
                  : 'Nothing was sent. The dollar price is the same; '
                        "BEAM's rate changed since the first quote. Check "
                        'the total and confirm again.',
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
                  ? 'Not sure it was sent'
                  : "It wasn't sent",
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
    final clock = widget.clock;
    String? dateOf(int? h) => h == null || clock == null
        ? null
        : '≈ ${NamesFormat.date(clock.dateOf(h))}';
    final rows = <Widget>[
      NamesDetailRow(
        label: 'Name',
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
                  ? 'Yours until'
                  : 'Renewed until',
              value: until,
              valueKey: const Key('names-confirm-expiry'),
              sub: _showBlocks ? NamesFormat.block(s.expireHeight!) : null,
              onTap: _toggleBlocks,
            ),
          );
        }
        rows.add(
          NamesDetailRow(
            label: s.action == BansAction.register ? 'Name price' : 'Price',
            value: s.youPay.map(_amount).join(' + '),
            valueKey: const Key('names-confirm-pay-0'),
            sub: s.usdTotal == null
                ? null
                : '${NamesFormat.usd(s.usdTotal!)} · '
                      '${NamesFormat.years(s.periods ?? 1)}',
          ),
        );
        rows.add(_feeRow());
        rows.add(
          NamesDetailRow(
            label: 'Paid to',
            value: 'The BEAM DAO vault',
            sub: _shortCid(s.contractId),
          ),
        );
      case BansAction.buy:
        rows.add(
          NamesDetailRow(
            label: "Seller's price",
            value: s.youPay.map(_amount).join(' + '),
            valueKey: const Key('names-confirm-pay-0'),
          ),
        );
        rows.add(_feeRow());
        final until = dateOf(s.expireHeight);
        if (until != null) {
          rows.add(
            NamesDetailRow(
              label: 'Yours until',
              value: until,
              valueKey: const Key('names-confirm-expiry'),
              sub: _showBlocks ? NamesFormat.block(s.expireHeight!) : null,
              onTap: _toggleBlocks,
            ),
          );
        }
        rows.add(
          const NamesDetailRow(
            label: 'Paid to',
            value: 'The seller, through the BEAM vault',
          ),
        );
      case BansAction.setOwner:
        rows.add(_feeRow());
      case BansAction.setPrice:
        rows.add(
          NamesDetailRow(
            label: 'Price',
            value: _unlisting ? 'Not for sale' : _amount(s.listPrice!),
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
              label: 'You receive',
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
    label: 'Network fee',
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
          label: 'You get',
          value: _beam(beamIn - s.fee),
          valueKey: const Key('names-confirm-total'),
        );
      }
    }
    final tokens = s.youPay.where((a) => a.assetId != 0).map(_amount);
    return NamesTotalBox(
      label: 'Total',
      value: [_beam(s.totalBeam), ...tokens].join(' + '),
      valueKey: const Key('names-confirm-total'),
    );
  }

  static String _rateText(String? usdPerBeam) =>
      usdPerBeam == null ? '' : ' (1 BEAM ≈ \$$usdPerBeam)';

  List<Widget> _afterTotal(StackColors colors) {
    final note = switch (s.action) {
      BansAction.register || BansAction.extend =>
        "The price is set by BEAM's name service in dollars and paid in "
            "BEAM at today's rate${_rateText(s.usdPerBeamText)}.",
      BansAction.buy =>
        'Buying does not renew the name: you get the time left on it. Renew '
            'it afterwards to keep it longer.',
      BansAction.setPrice =>
        _unlisting
            ? 'Nobody can buy $_name after this.'
            : 'Anyone can buy $_name at this price at any moment, with no '
                  'further question to you. The payment waits for you on '
                  'the Names screen, where you claim it.',
      BansAction.claimSaleProceeds || BansAction.claimAll =>
        s.youReceive.any((r) => r.assetId == 0)
            ? 'The network fee is taken from the money you claim.'
            : 'The network fee is paid from your BEAM.',
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
                'New owner',
                style: STextStyles.smallMed12(context)
                    .copyWith(color: colors.infoItemLabel),
              ),
              const SizedBox(height: 4),
              Text(
                BansKey.fingerprint(s.ownerKey!),
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
          title: "This can't be undone",
          detail:
              '$_name will belong to the wallet with key '
              '${BansKey.fingerprint(s.ownerKey!)}. Only that wallet can '
              'give it back.',
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
      'I checked ${BansKey.fingerprint(s.ownerKey!)} with the receiving '
      'wallet.',
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
    final busy = _phase == _Phase.checking || _phase == _Phase.sending;
    if (_phase == _Phase.unknown) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: 'Back to my names',
        onPressed: () => Navigator.of(context).pop(),
      );
    }
    if (busy) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: _phase == _Phase.checking
            ? 'Checking the price once more…'
            : 'Sending…',
        onPressed: null,
      );
    }
    if (!deps.canSpend) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: _cta,
        onPressed: null,
        reason: 'Signing is paused until your wallet is up to date.',
      );
    }
    final short = _shortfall;
    if (short != null) {
      final add = deps.onAddFunds;
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-confirm-cta'),
        label: add == null ? _cta : 'Add BEAM',
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
        reason: 'Tick the box once the key matches.',
      );
    }
    return NamesPrimaryAction(
      deps: deps,
      buttonKey: const Key('names-confirm-cta'),
      label: _cta,
      onPressed: _confirm,
    );
  }
}
