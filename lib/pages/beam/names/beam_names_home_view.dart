/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: show my names (and whether any needs renewing), and let me
//    get one.
// 2. Primary CTA: "Get a name".
// 3. Taps from app open: Names (1) → Get a name (2). Any name's details:
//    Names (1) → the name (2).
//
// BANS (BEAM's name service) in place of Firo's Spark Names, built into
// the wallet. Mobile: one list with the button pinned at the bottom.
// Desktop: Campfire's two columns, as Spark Names had them (get a name |
// my names).
//
// Exit-intent (§1.7) — what could make an impatient person leave:
// * "What is a name?" — the empty state says it in one sentence.
// * "Am I about to lose my name?" — a renewal warning sits above the list
//   with a one-tap Renew.
// * "Someone bought my name — where is the money?" — a claim card when the
//   wallet can see it; when this version cannot, it says so plainly and
//   offers a way to check.
// * A blank screen while loading — the last names read are shown at once,
//   otherwise placeholders with what is happening.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../widgets/background.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_name_confirm_view.dart';
import 'beam_name_detail_view.dart';
import 'beam_name_key_view.dart';
import 'beam_name_register_view.dart';

/// The Names screen: my names and "Get a name".
class BeamNamesHomeView extends StatefulWidget {
  const BeamNamesHomeView({super.key, required this.deps});

  static const String routeName = '/beamNamesHomeView';

  final BeamNamesDeps deps;

  @override
  State<BeamNamesHomeView> createState() => _BeamNamesHomeViewState();
}

class _BeamNamesHomeViewState extends State<BeamNamesHomeView> {
  BansMyNames? _names;
  bool _loading = false;
  Object? _error;

  BansInbox? _inbox;
  bool _claimUnsupported = false;
  bool _claiming = false;
  String? _claimMessage;

  BeamNameSent? _lastSent;

  BeamNamesDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    _names = deps.lastNames;
    deps.sync.addListener(_rebuild);
    deps.pending.addListener(_rebuild);
    unawaited(_load());
  }

  @override
  void dispose() {
    deps.sync.removeListener(_rebuild);
    deps.pending.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final names = await deps.bans.myNames();
      deps.lastNames = names;
      deps.pending.reconcile(names);
      if (mounted) setState(() => _names = names);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    if (mounted) setState(() => _loading = false);
    await _loadInbox();
  }

  Future<void> _loadInbox() async {
    try {
      final inbox = await deps.bans.inbox();
      if (mounted) {
        setState(() {
          _inbox = inbox;
          _claimUnsupported = false;
        });
      }
    } on BansClaimUnsupported {
      if (mounted) setState(() => _claimUnsupported = true);
    } catch (_) {
      // Keep what was shown; the names list carries its own error.
    }
  }

  String _price(BansAmount a) =>
      '${NamesFormat.readable(a.amount)} ${deps.symbol(a.assetId)}';

  void _onSent(BeamNameSent? sent) {
    if (sent == null || !mounted) return;
    setState(() {
      _lastSent = sent;
      _claimMessage = null;
    });
    unawaited(_load());
  }

  Future<void> _getAName({String? initial}) async {
    _onSent(
      await BeamNameRegisterView.show(
        context,
        deps: deps,
        initialName: initial,
      ),
    );
  }

  Future<void> _open(BansDomain d, BansClock clock) async {
    _onSent(
      await BeamNameDetailView.show(
        context,
        deps: deps,
        domain: d,
        clock: clock,
      ),
    );
  }

  Future<void> _claim(Future<BansPrepared> Function() build) async {
    setState(() {
      _claiming = true;
      _claimMessage = null;
    });
    final BansPrepared prepared;
    try {
      prepared = await build();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _claiming = false;
        _claimMessage = namesErrorText(e);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _claiming = false);
    _onSent(
      await BeamNameConfirmView.show(
        context,
        deps: deps,
        prepared: prepared,
        rebuild: build,
      ),
    );
  }

  /// On a core that cannot read the inbox, a sale's payment can still be
  /// claimed: building the claim shows whether anything is waiting.
  Future<void> _checkSaleMoney() async {
    final assets = {
      0,
      for (final d in _names?.names ?? const <BansDomain>[])
        if (d.salePrice != null) d.salePrice!.assetId,
    };
    setState(() {
      _claiming = true;
      _claimMessage = null;
    });
    for (final aid in assets) {
      Future<BansPrepared> build() => deps.bans.prepareClaimSaleProceeds(aid);
      try {
        await build();
      } on BansShaderRefused catch (e) {
        if (e.refusal == BansRefusal.noFunds ||
            e.refusal == BansRefusal.nothingToClaim) {
          continue;
        }
        if (!mounted) return;
        setState(() {
          _claiming = false;
          _claimMessage = namesErrorText(e);
        });
        return;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _claiming = false;
          _claimMessage = namesErrorText(e);
        });
        return;
      }
      if (!mounted) return;
      await _claim(build);
      return;
    }
    if (!mounted) return;
    setState(() {
      _claiming = false;
      _claimMessage = 'Nothing from a name sale is waiting for this wallet.';
    });
  }

  // ------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) =>
      deps.desktop ? _desktop(context) : _mobile(context);

  Widget _mobile(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          titleSpacing: 0,
          title: Text('Names', style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: _content(context),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: _cta(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DesktopScaffold(
      appBar: DesktopAppBar(
        isCompactHeight: true,
        background: colors.popupBG,
        leading: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 20),
              child: AppBarIconButton(
                size: 32,
                color: colors.textFieldDefaultBG,
                shadows: const [],
                icon: SvgPicture.asset(
                  Assets.svg.arrowLeft,
                  width: 18,
                  height: 18,
                  colorFilter: ColorFilter.mode(
                    colors.topNavIconPrimary,
                    BlendMode.srcIn,
                  ),
                ),
                onPressed: Navigator.of(context).pop,
              ),
            ),
            SvgPicture.asset(
              Assets.svg.robotHead,
              width: 32,
              height: 32,
              colorFilter: ColorFilter.mode(colors.textDark, BlendMode.srcIn),
            ),
            const SizedBox(width: 10),
            Text('Names', style: STextStyles.desktopH3(context)),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.only(top: 24, left: 24, right: 24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 460,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _columnLabel(context, 'Get a name'),
                  const SizedBox(height: 14),
                  RoundedWhiteContainer(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Let people pay alice instead of a 67-character '
                          'address.',
                          style: STextStyles.desktopTextSmall(context),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Names cost \$10 a year for 5 or more characters, '
                          '\$120 for 4 and \$320 for 3, paid in BEAM at '
                          "today's rate.",
                          style: STextStyles.desktopTextExtraExtraSmall(
                            context,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _cta(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Flexible(
              child: SizedBox(
                width: 520,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _columnLabel(context, 'My names'),
                    const SizedBox(height: 14),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 24),
                        children: _content(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _columnLabel(BuildContext context, String text) => Text(
    text,
    style: STextStyles.desktopTextExtraSmall(context).copyWith(
      color: Theme.of(context)
          .extension<StackColors>()!
          .textFieldActiveSearchIconLeft,
    ),
  );

  Widget _cta() => NamesPrimaryAction(
    deps: deps,
    buttonKey: const Key('names-home-cta'),
    label: 'Get a name',
    onPressed: _getAName,
  );

  List<Widget> _content(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final names = _names;
    final out = <Widget>[NamesSyncBanner(deps: deps)];

    final sent = _lastSent;
    if (sent != null) {
      out.addAll([_sentCard(context, sent), const SizedBox(height: 12)]);
    }

    if (names == null) {
      if (_error != null) {
        out.add(
          NamesNotice(
            key: const Key('names-home-error'),
            kind: NamesNoticeKind.error,
            title: "Can't read your names right now",
            detail: namesErrorText(_error!),
            actionLabel: 'Try again',
            onAction: _load,
          ),
        );
      } else {
        out.addAll(_placeholders(context));
      }
      return out;
    }

    if (_error != null) {
      out.addAll([
        NamesNotice(
          kind: NamesNoticeKind.warning,
          title: "Couldn't refresh your names",
          detail:
              'Showing them as they were a moment ago. '
              '${namesErrorText(_error!)}',
          actionLabel: 'Try again',
          onAction: _load,
        ),
        const SizedBox(height: 12),
      ]);
    }

    final clock = BansClock(tipHeight: names.tipHeight, tipTime: names.tipTime);
    final sorted = [...names.names]
      ..sort(
        (a, b) =>
            _rank(a, names.tipHeight).compareTo(_rank(b, names.tipHeight)),
      );

    out.addAll(_renewWarning(context, sorted, clock));
    out.addAll(_moneyCards(context));

    final incoming = [
      for (final p in deps.pending.items)
        if ((p.kind == BansPendingKind.register ||
                p.kind == BansPendingKind.buy) &&
            !names.names.any((d) => d.name == p.name))
          p,
    ];

    if (sorted.isEmpty && incoming.isEmpty) {
      out.add(_empty(context));
    } else {
      if (!deps.desktop) out.add(const NamesSectionLabel('My names'));
      for (final p in incoming) {
        out.addAll([_pendingCard(context, p), const SizedBox(height: 8)]);
      }
      for (final d in sorted) {
        out.addAll([_nameCard(context, d, clock), const SizedBox(height: 8)]);
      }
    }

    out.addAll([
      if (_claimUnsupported) ...[
        const SizedBox(height: 4),
        ..._stockCoreNotice(),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: CustomTextButton(
          key: const Key('names-home-receive'),
          text: 'Receive a name from another wallet',
          onTap: () => BeamNameKeyView.show(context, deps),
        ),
      ),
    ]);
    if (_loading) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Checking for changes…',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textSubtitle2),
          ),
        ),
      );
    }
    return out;
  }

  /// Renewal first, then soonest expiry, expired-for-good names last.
  static int _rank(BansDomain d, int tip) {
    final s = d.statusAt(tip);
    if (s == BansNameStatus.availableAgain) return 1 << 40;
    if (s == BansNameStatus.onHold) return -(1 << 40) + d.expireHeight;
    return d.expireHeight;
  }

  List<Widget> _placeholders(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return [
      for (var i = 0; i < 2; i++) ...[
        Container(
          height: 64,
          decoration: BoxDecoration(
            color: colors.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 8),
      ],
      Text(
        'Reading your names from the BEAM network…',
        key: const Key('names-home-loading'),
        style: STextStyles.smallMed12(context)
            .copyWith(color: colors.textSubtitle1),
      ),
    ];
  }

  Widget _empty(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return NamesCard(
      key: const Key('names-home-empty'),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const BeamStickerImage(BeamSticker.hi, size: 112),
          const SizedBox(height: 8),
          Text(
            "You don't have a name yet",
            style: STextStyles.titleBold12(context),
          ),
          const SizedBox(height: 6),
          // On desktop the "Get a name" card beside it already says what a
          // name is for and what it costs; here, what will be in this list.
          if (deps.desktop)
            Text(
              'Names you get, or receive from another wallet, show here '
              'with the date each one renews.',
              textAlign: TextAlign.center,
              style: STextStyles.smallMed14(context)
                  .copyWith(color: colors.textSubtitle1),
            )
          else ...[
            Text(
              'Let people pay alice instead of a 67-character address.',
              textAlign: TextAlign.center,
              style: STextStyles.smallMed14(context),
            ),
            const SizedBox(height: 6),
            Text(
              'From \$10 a year, paid in BEAM.',
              textAlign: TextAlign.center,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ],
        ],
      ),
    );
  }

  Widget _nameCard(BuildContext context, BansDomain d, BansClock clock) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final st = NameStatusText.of(d, clock, _price);
    final pending = deps.pending.of(d.name);
    return NamesCard(
      key: Key('names-home-name-${d.name}'),
      onTap: () => _open(d, clock),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, style: STextStyles.titleBold12(context)),
                const SizedBox(height: 4),
                Text(
                  pending?.label ?? st.text,
                  key: Key('names-home-status-${d.name}'),
                  style: STextStyles.smallMed12(context).copyWith(
                    color: pending == null
                        ? st.color(colors)
                        : colors.accentColorYellow,
                  ),
                ),
                if (st.saleLine != null && pending == null) ...[
                  const SizedBox(height: 2),
                  Text(
                    st.saleLine!,
                    key: Key('names-home-sale-${d.name}'),
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.accentColorBlue),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: colors.textSubtitle1),
        ],
      ),
    );
  }

  Widget _pendingCard(BuildContext context, BansPendingName p) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return NamesCard(
      key: Key('names-home-pending-${p.name}'),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: STextStyles.titleBold12(context)),
                const SizedBox(height: 4),
                Text(
                  p.label,
                  style: STextStyles.smallMed12(context)
                      .copyWith(color: colors.accentColorYellow),
                ),
              ],
            ),
          ),
          Icon(Icons.hourglass_top_rounded, color: colors.accentColorYellow),
        ],
      ),
    );
  }

  List<Widget> _renewWarning(
    BuildContext context,
    List<BansDomain> sorted,
    BansClock clock,
  ) {
    final due = [
      for (final d in sorted)
        if (NameStatusText.needsRenewal(d, clock.tipHeight) &&
            deps.pending.of(d.name) == null)
          d,
    ];
    if (due.isEmpty) return const [];
    final d = due.first;
    final onHold = d.statusAt(clock.tipHeight) == BansNameStatus.onHold;
    final more = due.length > 1 ? ' (and ${due.length - 1} more)' : '';
    final days = NamesFormat.daysBetween(clock.tipHeight, d.expireHeight);
    final renewBy = NamesFormat.date(
      clock.dateOf(BansTimeline.holdEndHeight(d.expireHeight)),
    );
    return [
      NamesNotice(
        key: const Key('names-home-renew-warning'),
        kind: NamesNoticeKind.warning,
        title: onHold
            ? '${d.name} has expired$more'
            : '${d.name} expires ${NamesFormat.inDays(days)}$more',
        detail: onHold
            ? 'Renew it by $renewBy to keep it. After that anyone can take '
                  'it.'
            : 'Renew it to keep it. After it expires you still have 90 '
                  'days.',
        actionLabel: 'Renew ${d.name}',
        actionKey: const Key('names-home-renew-action'),
        onAction: () => _open(d, clock),
      ),
      const SizedBox(height: 12),
    ];
  }

  /// Sale proceeds to claim, payments to the names, or, on a core that
  /// cannot see them, the plain limitation.
  List<Widget> _moneyCards(BuildContext context) {
    final out = <Widget>[];
    final inbox = _inbox;
    if (!_claimUnsupported && inbox != null) {
      final totals = <int, BigInt>{};
      for (final a in inbox.saleProceeds) {
        totals[a.assetId] = (totals[a.assetId] ?? BigInt.zero) + a.amount;
      }
      for (final e in totals.entries) {
        final amount = _price(BansAmount(e.key, e.value));
        out.addAll([
          NamesNotice(
            key: Key('names-home-proceeds-${e.key}'),
            kind: NamesNoticeKind.success,
            title: 'You sold a name: $amount is waiting for you',
            detail: e.key == 0
                ? 'Claim it to move it into your balance. The network fee '
                      'comes out of it.'
                : 'Claim it to move it into your balance. The network fee '
                      'is paid in BEAM.',
            actionLabel: _claiming ? 'Preparing…' : 'Claim $amount',
            actionKey: Key('names-home-claim-${e.key}'),
            onAction: _claiming
                ? null
                : () => _claim(() => deps.bans.prepareClaimSaleProceeds(e.key)),
          ),
          const SizedBox(height: 12),
        ]);
      }
      if (inbox.payments.isNotEmpty) {
        out.addAll([
          const NamesNotice(
            key: Key('names-home-payments'),
            title: 'People paid your names',
            detail: 'Claim those payments from your wallet home screen.',
          ),
          const SizedBox(height: 12),
        ]);
      }
    }
    if (_claimMessage != null) {
      out.addAll([
        NamesNotice(
          key: const Key('names-home-claim-message'),
          title: _claimMessage!,
        ),
        const SizedBox(height: 12),
      ]);
    }
    return out;
  }

  /// On a core that cannot run the BANS shader at privilege 1: the plain
  /// limitation, below the list (claim-related parts only).
  List<Widget> _stockCoreNotice() {
    final out = <Widget>[];
    if (_claimUnsupported) {
      out.addAll([
        NamesNotice(
          key: const Key('names-home-claim-unsupported'),
          title: "This version can't see payments to your names yet",
          detail:
              'They are safe in the BEAM vault and can be claimed with the '
              'full Campfire build of this wallet. Money from a name you '
              'sold can be claimed now.',
          actionLabel: _claiming ? 'Checking…' : 'Check for money from a sale',
          actionKey: const Key('names-home-check-sale'),
          onAction: _claiming ? null : _checkSaleMoney,
        ),
        const SizedBox(height: 12),
      ]);
    }
    return out;
  }

  Widget _sentCard(BuildContext context, BeamNameSent sent) {
    final s = sent.summary;
    final n = s.name?.value ?? '';
    final (String title, String detail) = switch (s.action) {
      BansAction.register || BansAction.buy => (
        '$n is on its way to you',
        "It's usually yours within 2 minutes. People can then pay "
            '${s.name?.display ?? n}.',
      ),
      BansAction.extend => (
        'Renewal of $n sent',
        'It shows the new date once confirmed, usually within 2 minutes.',
      ),
      BansAction.setOwner => (
        'Transfer of $n sent',
        'It leaves this wallet once confirmed, usually within 2 minutes.',
      ),
      BansAction.setPrice =>
        s.listPrice == null || s.listPrice!.amount == BigInt.zero
            ? ('$n is coming off sale', 'Usually within 2 minutes.')
            : (
                '$n is being listed for ${_price(s.listPrice!)}',
                'Anyone can buy it once confirmed, usually within 2 '
                    'minutes.',
              ),
      _ => (
        'Claim sent',
        '${s.youReceive.map(_price).join(' + ')} arrives in your balance '
            'once confirmed.',
      ),
    };
    final celebrate =
        s.action == BansAction.register || s.action == BansAction.extend;
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      key: const Key('names-home-sent'),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          if (celebrate) ...[
            const BeamAnimatedStickerView(BeamMoments.walletCreated, size: 64),
            const SizedBox(width: 12),
          ] else ...[
            Icon(
              Icons.check_circle_outline_rounded,
              color: colors.accentColorGreen,
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.titleBold12(context)),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: STextStyles.smallMed12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
