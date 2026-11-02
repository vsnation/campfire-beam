/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: keep this name — see until when it is yours and renew it.
//    Transfer and selling are secondary.
// 2. Primary CTA: "Renew alice for 1 year".
// 3. Taps from app open: Names (1) → alice (2) → Renew (3) → Pay & renew
//    alice (4) → PIN.
//
// Dates, never block heights (a tap on the date shows the block). The
// renewal is capped at what fits within 50 years, as the contract allows.
//
// Exit-intent — what could make an impatient person leave:
// * "When does it run out?" — the first line under the name.
// * "Will I lose it if I miss the date?" — the 90-day grace is spelled
//   out with its last day.
// * "What happens to money from a sale?" — said before listing.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import '../../../widgets/custom_buttons/simple_copy_button.dart';
import 'beam_name_confirm_view.dart';
import 'beam_name_sell_view.dart';
import 'beam_name_transfer_view.dart';

/// One of my names: until when it is mine, renew, transfer, sell.
///
/// Pops with the [BeamNameSent] of whatever was sent from here.
class BeamNameDetailView extends StatefulWidget {
  const BeamNameDetailView({
    super.key,
    required this.deps,
    required this.domain,
    required this.clock,
  });

  final BeamNamesDeps deps;

  /// The name's record as last read.
  final BansDomain domain;

  /// The wallet's block when [domain] was read, to turn heights into dates.
  final BansClock clock;

  static Future<BeamNameSent?> show(
    BuildContext context, {
    required BeamNamesDeps deps,
    required BansDomain domain,
    required BansClock clock,
  }) => showNamesPage<BeamNameSent>(
    context,
    deps,
    (_) => BeamNameDetailView(deps: deps, domain: domain, clock: clock),
  );

  @override
  State<BeamNameDetailView> createState() => _BeamNameDetailViewState();
}

class _BeamNameDetailViewState extends State<BeamNameDetailView> {
  int _years = 1;
  bool _showBlocks = false;
  bool _preparing = false;
  String? _error;
  BansParams? _params;

  BeamNamesDeps get deps => widget.deps;
  BansDomain get d => widget.domain;
  BansClock get clock => widget.clock;
  BansName get name => BansName(d.name);
  BansNameStatus get status => d.statusAt(clock.tipHeight);
  bool get _pastHold => status == BansNameStatus.availableAgain;

  int get _maxYears => BansTimeline.maxExtendPeriods(
    expireHeight: d.expireHeight,
    tipHeight: clock.tipHeight,
  );

  /// The chosen years, within what the contract allows now.
  int get _y => _maxYears == 0 ? 1 : _years.clamp(1, _maxYears);

  @override
  void initState() {
    super.initState();
    deps.sync.addListener(_rebuild);
    unawaited(_loadParams());
  }

  @override
  void dispose() {
    deps.sync.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadParams() async {
    try {
      final p = await deps.bans.params();
      if (mounted) setState(() => _params = p);
    } catch (_) {
      // The estimate stays hidden; the confirmation shows the exact price.
    }
  }

  String _price(BansAmount a) =>
      '${NamesFormat.readable(a.amount, places: deps.decimals(a.assetId))} ${deps.symbol(a.assetId)}';

  String _date(int h) => NamesFormat.date(clock.dateOf(h));

  int get _holdEnd => BansTimeline.holdEndHeight(d.expireHeight);

  Future<void> _run(Future<BansPrepared> Function() build) async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    final BansPrepared prepared;
    try {
      prepared = await build();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = namesErrorText(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    final sent = await BeamNameConfirmView.show(
      context,
      deps: deps,
      prepared: prepared,
      rebuild: build,
      clock: clock,
    );
    if (sent != null && mounted) Navigator.of(context).pop(sent);
  }

  Future<void> _renew() {
    final n = name;
    final years = _y;
    return _run(() => deps.bans.prepareExtend(n, years));
  }

  Future<void> _unlist() {
    final n = name;
    final aid = d.salePrice?.assetId ?? 0;
    return _run(() => deps.bans.prepareSetPrice(n, aid, BigInt.zero));
  }

  Future<void> _push(Future<BeamNameSent?> Function() open) async {
    final sent = await open();
    if (sent != null && mounted) Navigator.of(context).pop(sent);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final st = NameStatusText.of(d, clock, _price);
    final pending = deps.pending.of(d.name);
    return NamesPage(
      deps: deps,
      title: d.name,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NamesSyncBanner(deps: deps),
          NamesCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.display,
                        key: const Key('names-detail-name'),
                        style: STextStyles.pageTitleH2(context),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        pending?.label ?? st.text,
                        key: const Key('names-detail-status'),
                        style: STextStyles.smallMed12(context).copyWith(
                          color: pending == null
                              ? st.color(colors)
                              : colors.accentColorYellow,
                        ),
                      ),
                    ],
                  ),
                ),
                SimpleCopyButton(data: name.display),
              ],
            ),
          ),
          const SizedBox(height: 12),
          NamesCard(
            child: Column(
              children: [
                NamesDetailRow(
                  label: status == BansNameStatus.onHold || _pastHold
                      ? l10n.namesRowExpiredOn
                      : l10n.namesRowYoursUntil,
                  value: '≈ ${_date(d.expireHeight)}',
                  valueKey: const Key('names-detail-expiry'),
                  sub: _showBlocks ? NamesFormat.block(d.expireHeight) : null,
                  onTap: () => setState(() => _showBlocks = !_showBlocks),
                ),
                if (status == BansNameStatus.onHold)
                  NamesDetailRow(
                    label: l10n.namesRowRenewBy,
                    value: '≈ ${_date(_holdEnd)}',
                    valueColor: colors.accentColorRed,
                  ),
                if (d.salePrice != null)
                  NamesDetailRow(
                    label: l10n.namesRowForSaleAt,
                    value: _price(d.salePrice!),
                    valueKey: const Key('names-detail-price'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _pastHold ? l10n.namesGraceOver : l10n.namesGraceInfo,
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 16),
          NamesSectionLabel(l10n.namesRenewSection),
          NamesCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_maxYears > 0)
                  NamesYearsStepper(
                    value: _y,
                    max: _maxYears,
                    onChanged: (v) => setState(() {
                      _years = v;
                      _error = null;
                    }),
                  )
                else
                  Text(
                    l10n.namesPaidUpMax(d.name),
                    style: STextStyles.smallMed12(context),
                  ),
                if (_maxYears > 0) ...[
                  const SizedBox(height: 8),
                  NamesDetailRow(
                    label: l10n.namesPriceLabel,
                    value: NamesFormat.usd(name.usdPerPeriod * _y),
                    valueKey: const Key('names-detail-renew-usd'),
                    sub: _estimateText(),
                  ),
                ],
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NamesNotice(
              key: const Key('names-detail-error'),
              kind: NamesNoticeKind.error,
              title: l10n.namesCouldntPrepare,
              detail: _error,
            ),
          ],
          const SizedBox(height: 16),
          NamesSectionLabel(l10n.namesMoreSection),
          NamesSecondaryAction(
            key: const Key('names-detail-transfer'),
            deps: deps,
            label: l10n.namesTransferToAnother,
            onPressed: _pastHold || _preparing
                ? null
                : () => _push(
                    () => BeamNameTransferView.show(
                      context,
                      deps: deps,
                      domain: d,
                      clock: clock,
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          NamesSecondaryAction(
            key: const Key('names-detail-sell'),
            deps: deps,
            label: d.isListed
                ? l10n.namesStopSellingName(d.name)
                : l10n.namesSellName(d.name),
            onPressed: _pastHold || _preparing
                ? null
                : d.isListed
                ? _unlist
                : () => _push(
                    () => BeamNameSellView.show(
                      context,
                      deps: deps,
                      domain: d,
                      clock: clock,
                    ),
                  ),
          ),
          if (_pastHold) ...[
            const SizedBox(height: 8),
            Text(
              l10n.namesExpiredCantTransfer,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ] else if (d.isListed) ...[
            const SizedBox(height: 8),
            Text(
              l10n.namesListedPaymentWaits,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
        ],
      ),
      bottom: _bottom(),
    );
  }

  String? _estimateText() {
    final est = _params?.estimate(name, _y);
    if (est == null) return null;
    final mid = (est.minGroth + est.maxGroth) ~/ BigInt.two;
    return context.l10n.namesAboutBeamToday('${NamesFormat.whole(mid)} BEAM');
  }

  Widget _bottom() {
    const key = Key('names-detail-cta');
    final l10n = context.l10n;
    final label = l10n.namesRenewNameForYears(d.name, _y);
    if (_preparing) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: key,
        label: l10n.namesPreparing,
        onPressed: null,
        reason: l10n.namesBuildingTx,
      );
    }
    if (_maxYears == 0) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: key,
        label: l10n.namesRenewName(d.name),
        onPressed: null,
        reason: l10n.namesNothingToRenew,
      );
    }
    if (!deps.canSpend) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: key,
        label: label,
        onPressed: null,
        reason: l10n.namesRenewingPaused,
      );
    }
    return NamesPrimaryAction(
      deps: deps,
      buttonKey: key,
      label: label,
      onPressed: _renew,
    );
  }
}
