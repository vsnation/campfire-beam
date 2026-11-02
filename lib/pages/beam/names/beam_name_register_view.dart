/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: find a name that is free and get it, knowing the price in
//    dollars and in BEAM before committing.
// 2. Primary CTA: "Get alice for 1 year" (or "Buy alice for 100,000 BEAM"
//    when it is listed, "Manage alice" when it is already yours).
// 3. Taps from app open: Names (1) → Get a name (2) → type → Get alice (3)
//    → Pay & register alice (4) → PIN.
//
// Checking is live: no "Lookup" button. The name is looked up 400 ms after
// typing stops, on the wallet's own node, and only the newest answer is
// shown. Prices per length are visible before typing (honest anchoring).
//
// Exit-intent — what could make an impatient person leave:
// * "$10 a year is 1,162 BEAM?!" — dollars first, BEAM second, and one
//   line on why it is paid in BEAM; 3- and 4-letter prices shown up front.
// * Typing a name that turns out taken — said at once, with when it could
//   become free, and the field stays ready for another try.
// * Not enough BEAM — the button turns into "Add BEAM" instead of failing
//   later.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_constants.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../wallets/beam/contracts/common/invoke_data.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import 'beam_name_confirm_view.dart';
import 'beam_name_detail_view.dart';

/// How long typing must pause before the name is looked up.
const Duration kNamesLookupDebounce = Duration(milliseconds: 400);

enum _Found { available, availableAgain, mine, taken, onHold, forSale }

/// Find a name and register it (or buy it, when its owner sells it).
///
/// Pops with the [BeamNameSent] of whatever was sent from here.
class BeamNameRegisterView extends StatefulWidget {
  const BeamNameRegisterView({super.key, required this.deps, this.initialName});

  final BeamNamesDeps deps;

  /// Pre-fills the field, e.g. "Get alice again" from an expired name.
  final String? initialName;

  static Future<BeamNameSent?> show(
    BuildContext context, {
    required BeamNamesDeps deps,
    String? initialName,
  }) => showNamesPage<BeamNameSent>(
    context,
    deps,
    (_) => BeamNameRegisterView(deps: deps, initialName: initialName),
  );

  @override
  State<BeamNameRegisterView> createState() => _BeamNameRegisterViewState();
}

class _BeamNameRegisterViewState extends State<BeamNameRegisterView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  int _seq = 0;

  BansName? _name;
  BansNameProblem? _problem;
  BansResolution? _found;
  bool _looking = false;
  Object? _lookupError;

  String? _myKey;
  BansParams? _params;
  Object? _paramsError;

  int _years = 1;
  bool _preparing = false;
  String? _prepareError;

  BeamNamesDeps get deps => widget.deps;

  @override
  void initState() {
    super.initState();
    deps.sync.addListener(_rebuild);
    deps.balances.addListener(_rebuild);
    unawaited(_loadBasics());
    final initial = widget.initialName;
    if (initial != null) {
      _controller.text = initial;
      _onChanged(initial);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !deps.desktop) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    deps.sync.removeListener(_rebuild);
    deps.balances.removeListener(_rebuild);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBasics() async {
    try {
      final key = await deps.bans.myKey();
      if (mounted) setState(() => _myKey = key);
    } catch (_) {
      // Only used to recognise "yours"; a lookup error says the rest.
    }
    try {
      final p = await deps.bans.params();
      if (mounted) setState(() => _params = p);
    } catch (e) {
      if (mounted) setState(() => _paramsError = e);
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    final normal = BansName.normalise(text);
    final problem = normal.isEmpty ? null : BansName.check(normal);
    setState(() {
      _problem = problem;
      _name = normal.isEmpty || problem != null ? null : BansName(normal);
      _found = null;
      _lookupError = null;
      _prepareError = null;
      _looking = _name != null;
      _seq++;
    });
    final name = _name;
    if (name == null) return;
    _debounce = Timer(kNamesLookupDebounce, () => _lookup(name));
  }

  Future<void> _lookup(BansName name) async {
    final seq = _seq;
    setState(() {
      _looking = true;
      _lookupError = null;
    });
    try {
      final r = await deps.bans.resolve(name);
      if (!mounted || seq != _seq) return;
      setState(() {
        _found = r;
        _looking = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _lookupError = e;
        _looking = false;
      });
    }
  }

  _Found? get _state {
    final r = _found;
    if (r == null) return null;
    final d = r.domain;
    if (d == null) return _Found.available;
    if (_myKey != null && d.ownerKey == _myKey) return _Found.mine;
    final status = r.status;
    if (status == BansNameStatus.availableAgain) return _Found.availableAgain;
    if (d.isListed) return _Found.forSale;
    if (status == BansNameStatus.onHold) return _Found.onHold;
    return _Found.taken;
  }

  BansPriceEstimate? get _estimate =>
      _name == null ? null : _params?.estimate(_name!, _years);

  String _price(BansAmount a) =>
      '${NamesFormat.readable(a.amount, places: deps.decimals(a.assetId))} ${deps.symbol(a.assetId)}';

  Future<void> _get() async {
    final name = _name!;
    final years = _years;
    setState(() {
      _preparing = true;
      _prepareError = null;
    });
    Future<BansPrepared> build() => deps.bans.prepareRegister(name, years);
    await _prepareAndConfirm(build);
  }

  Future<void> _buy() async {
    final name = _name!;
    setState(() {
      _preparing = true;
      _prepareError = null;
    });
    Future<BansPrepared> build() => deps.bans.prepareBuy(name);
    await _prepareAndConfirm(build);
  }

  Future<void> _prepareAndConfirm(Future<BansPrepared> Function() build) async {
    final BansPrepared prepared;
    try {
      prepared = await build();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _prepareError = namesErrorText(e);
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
      clock: _found?.clock,
    );
    if (sent != null && mounted) Navigator.of(context).pop(sent);
  }

  Future<void> _manage() async {
    final r = _found!;
    final sent = await BeamNameDetailView.show(
      context,
      deps: deps,
      domain: r.domain!,
      clock: r.clock,
    );
    if (sent != null && mounted) Navigator.of(context).pop(sent);
  }

  @override
  Widget build(BuildContext context) {
    return NamesPage(
      deps: deps,
      title: context.l10n.namesGetANameTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NamesSyncBanner(deps: deps),
          Text(
            context.l10n.namesRegisterIntro,
            style: STextStyles.smallMed12(context).copyWith(
              color: Theme.of(context).extension<StackColors>()!.textDark3,
            ),
          ),
          const SizedBox(height: 12),
          _field(context),
          const SizedBox(height: 16),
          ..._result(context),
        ],
      ),
      bottom: _bottom(),
    );
  }

  Widget _field(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final length = BansName.normalise(_controller.text).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: colors.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(
              Constants.size.circularBorderRadius,
            ),
          ),
          child: TextField(
            key: const Key('names-register-field'),
            controller: _controller,
            focusNode: _focus,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            textAlignVertical: TextAlignVertical.center,
            inputFormatters: [
              _LowerCaseFormatter(),
              LengthLimitingTextInputFormatter(kBansNameMaxLength + 5),
            ],
            onChanged: _onChanged,
            style: STextStyles.field(context),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.zero,
              prefixIcon: Padding(
                padding: const EdgeInsets.all(14),
                child: SvgPicture.asset(
                  Assets.svg.search,
                  width: 20,
                  height: 20,
                  colorFilter: ColorFilter.mode(
                    colors.textFieldDefaultSearchIconLeft,
                    BlendMode.srcIn,
                  ),
                ),
              ),
              fillColor: Colors.transparent,
              hintText: context.l10n.namesRegisterHint,
              hintStyle: STextStyles.fieldLabel(context),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                _problem != null
                    ? BansName.describe(_problem!)
                    : context.l10n.namesRegisterRules,
                key: const Key('names-register-hint'),
                style: STextStyles.w500_10(context).copyWith(
                  color: _problem != null
                      ? colors.textError
                      : colors.textSubtitle2,
                ),
              ),
            ),
            Text(
              '$length/$kBansNameMaxLength',
              style: STextStyles.w500_10(context)
                  .copyWith(color: colors.textSubtitle2),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _result(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final name = _name;
    if (name == null) return [_tiers(context, null)];
    if (_looking) {
      return [
        NamesCard(
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.namesRegisterChecking(name.value),
                  style: STextStyles.smallMed14(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _tiers(context, name),
      ];
    }
    final err = _lookupError;
    if (err != null) {
      return [
        NamesNotice(
          key: const Key('names-register-lookup-error'),
          kind: NamesNoticeKind.error,
          title: context.l10n.namesRegisterCantCheck(name.value),
          detail: namesErrorText(err),
          actionLabel: context.l10n.namesCheckAgain,
          onAction: () => _lookup(name),
        ),
      ];
    }
    final r = _found;
    final state = _state;
    if (r == null || state == null) return [_tiers(context, name)];
    final l10n = context.l10n;
    final d = r.domain;
    final clock = r.clock;
    String date(int h) => NamesFormat.date(clock.dateOf(h));
    final out = <Widget>[];
    if (!r.walletInSync) {
      out.addAll([
        NamesNotice(
          kind: NamesNoticeKind.warning,
          title: l10n.namesRegisterMaybeOutdated,
        ),
        const SizedBox(height: 12),
      ]);
    }
    final (String title, Color color, String? detail) = switch (state) {
      _Found.available => (
        l10n.namesRegisterAvailable(name.value),
        colors.accentColorGreen,
        null,
      ),
      _Found.availableAgain => (
        l10n.namesRegisterAvailable(name.value),
        colors.accentColorGreen,
        l10n.namesRegisterAvailableAgainDetail,
      ),
      _Found.mine => (
        l10n.namesRegisterMine(name.value),
        colors.accentColorGreen,
        r.status == BansNameStatus.availableAgain
            ? l10n.namesRegisterMineExpiredDetail
            : l10n.namesRegisterMineUntil(date(d!.expireHeight)),
      ),
      _Found.taken => (
        l10n.namesRegisterTaken(name.value),
        colors.accentColorRed,
        l10n.namesRegisterTakenDetail(
          date(d!.expireHeight),
          date(BansTimeline.holdEndHeight(d.expireHeight)),
        ),
      ),
      _Found.onHold => (
        l10n.namesRegisterTaken(name.value),
        colors.accentColorRed,
        l10n.namesRegisterOnHoldDetail(
          date(BansTimeline.holdEndHeight(d!.expireHeight)),
        ),
      ),
      _Found.forSale => (
        l10n.namesRegisterForSale(name.value, _price(d!.salePrice!)),
        colors.accentColorBlue,
        r.status == BansNameStatus.onHold
            ? l10n.namesRegisterForSaleOnHoldDetail(
                date(BansTimeline.holdEndHeight(d.expireHeight)),
              )
            : l10n.namesRegisterForSaleDetail(date(d.expireHeight)),
      ),
    };
    out.add(
      NamesCard(
        key: const Key('names-register-result'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name.display, style: STextStyles.titleBold12(context)),
            const SizedBox(height: 4),
            Text(
              title,
              key: const Key('names-register-status'),
              style: STextStyles.smallMed14(context).copyWith(color: color),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                style: STextStyles.smallMed12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ],
        ),
      ),
    );
    if (state == _Found.available || state == _Found.availableAgain) {
      out.addAll([const SizedBox(height: 16), ..._quote(context, name)]);
    } else if (state == _Found.taken || state == _Found.onHold) {
      out.addAll([const SizedBox(height: 12), _tiers(context, name)]);
    }
    if (_prepareError != null) {
      out.addAll([
        const SizedBox(height: 12),
        NamesNotice(
          key: const Key('names-register-prepare-error'),
          kind: NamesNoticeKind.error,
          title: l10n.namesCouldntPrepare,
          detail: _prepareError,
        ),
      ]);
    }
    return out;
  }

  /// Prices by length, before and beside a result (honest anchoring).
  Widget _tiers(BuildContext context, BansName? name) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final mine = name == null
        ? null
        : l10n.namesNameTier(
            name.value,
            name.length,
            NamesFormat.usd(name.usdPerPeriod),
          );
    return Text(
      joinSentences([l10n.namesPriceTiers, mine], l10n),
      key: const Key('names-register-tiers'),
      style: STextStyles.smallMed12(context)
          .copyWith(color: colors.textSubtitle1),
    );
  }

  List<Widget> _quote(BuildContext context, BansName name) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final l10n = context.l10n;
    final est = _estimate;
    final usd = name.usdPerPeriod * _years;
    final beamText = est == null
        ? (_paramsError != null
              ? l10n.namesBeamPriceUnavailable
              : l10n.namesGettingBeamPrice)
        : '≈ ${NamesFormat.whole((est.minGroth + est.maxGroth) ~/ BigInt.two)}'
              ' BEAM';
    final hasNames = deps.lastNames?.names.isNotEmpty ?? false;
    final usdPerBeam = _params?.usdPerBeamText;
    return [
      NamesSectionLabel(l10n.namesHowLong),
      NamesCard(
        child: NamesYearsStepper(
          value: _years,
          max: BansTimeline.maxRegisterPeriods,
          onChanged: (v) => setState(() {
            _years = v;
            _prepareError = null;
          }),
        ),
      ),
      const SizedBox(height: 12),
      NamesCard(
        child: Column(
          children: [
            NamesDetailRow(
              label: l10n.namesPriceLabel,
              value: NamesFormat.usd(usd),
              valueKey: const Key('names-register-usd'),
              sub: l10n.namesPerYearTimesYears(
                NamesFormat.usd(name.usdPerPeriod),
                _years,
              ),
            ),
            NamesDetailRow(
              label: l10n.namesInBeamToday,
              value: beamText,
              valueKey: const Key('names-register-beam'),
            ),
            NamesDetailRow(
              label: l10n.beamNetworkFee,
              value: '≈ ${NamesFormat.exact(BeamContractFee.minimum)} BEAM',
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Text(
        usdPerBeam == null
            ? l10n.namesRegisterPriceNote
            : l10n.namesRegisterPriceNoteRate(usdPerBeam),
        key: const Key('names-register-price-note'),
        style: STextStyles.smallMed12(context)
            .copyWith(color: colors.textSubtitle1),
      ),
      if (hasNames) ...[
        const SizedBox(height: 8),
        Text(
          l10n.namesSharedKeyNote,
          style: STextStyles.smallMed12(context)
              .copyWith(color: colors.textSubtitle1),
        ),
      ],
    ];
  }

  Widget _bottom() {
    const key = Key('names-register-cta');
    final l10n = context.l10n;
    final name = _name;
    final state = _state;
    if (name == null || state == null) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: key,
        label: name == null
            ? l10n.namesGetANameCta
            : l10n.namesGetName(name.value),
        onPressed: null,
      );
    }
    if (_preparing) {
      return NamesPrimaryAction(
        deps: deps,
        buttonKey: key,
        label: l10n.namesPreparing,
        onPressed: null,
        reason: l10n.namesBuildingTx,
      );
    }
    switch (state) {
      case _Found.mine:
        return NamesPrimaryAction(
          deps: deps,
          buttonKey: key,
          label: l10n.namesManageName(name.value),
          onPressed: _manage,
        );
      case _Found.taken:
      case _Found.onHold:
        return NamesPrimaryAction(
          deps: deps,
          buttonKey: key,
          label: l10n.namesGetName(name.value),
          onPressed: null,
          reason: l10n.namesTakenTryAnother(name.value),
        );
      case _Found.forSale:
        final price = _found!.domain!.salePrice!;
        final label = l10n.namesBuyNameFor(name.value, _price(price));
        if (!deps.canSpend) {
          return NamesPrimaryAction(
            deps: deps,
            buttonKey: key,
            label: label,
            onPressed: null,
            reason: l10n.namesBuyingPaused,
          );
        }
        final need = price.assetId == 0
            ? price.amount + BeamContractFee.minimum
            : price.amount;
        final have = deps.available(price.assetId);
        if (have != null && have < need) {
          return _addFunds(
            key,
            label,
            l10n.namesYouHaveThisCosts(
              '${NamesFormat.readable(have, places: deps.decimals(price.assetId))} ${deps.symbol(price.assetId)}',
              _price(BansAmount(price.assetId, need)),
            ),
          );
        }
        return NamesPrimaryAction(
          deps: deps,
          buttonKey: key,
          label: label,
          onPressed: _buy,
        );
      case _Found.available:
      case _Found.availableAgain:
        final label = l10n.namesGetNameForYears(name.value, _years);
        if (!deps.canSpend) {
          return NamesPrimaryAction(
            deps: deps,
            buttonKey: key,
            label: label,
            onPressed: null,
            reason: l10n.namesRegisteringPaused,
          );
        }
        final est = _estimate;
        final have = deps.available(0);
        if (est != null && have != null) {
          final need = est.minGroth + BeamContractFee.minimum;
          if (have < need) {
            return _addFunds(
              key,
              label,
              l10n.namesYouHaveNameCosts(
                '${NamesFormat.readable(have)} BEAM',
                name.value,
                '${NamesFormat.whole(need)} BEAM',
                _years,
              ),
            );
          }
        }
        return NamesPrimaryAction(
          deps: deps,
          buttonKey: key,
          label: label,
          onPressed: _get,
        );
    }
  }

  Widget _addFunds(Key key, String label, String reason) {
    final add = deps.onAddFunds;
    return NamesPrimaryAction(
      deps: deps,
      buttonKey: key,
      label: add == null ? label : context.l10n.namesAddBeam,
      onPressed: add,
      reason: reason,
    );
  }
}

/// Names are lowercase on-chain; typing `Alice` shows `alice`.
class _LowerCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final lower = newValue.text.replaceAllMapped(
      RegExp('[A-Z]'),
      (m) => m[0]!.toLowerCase(),
    );
    return newValue.copyWith(text: lower);
  }
}
