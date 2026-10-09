/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: choose how much to move between your own BEAM wallet and
//    your own Ethereum wallet, and see what arrives, what it costs and
//    when, before anything is signed.
// 2. Primary CTA: the outcome, "Move 1,000 BEAM to Ethereum" / "Move 0.5
//    ETH to BEAM" ("Move" until an amount is typed); with a wallet
//    missing, "Add an Ethereum wallet" / "Add a BEAM wallet".
// 3. Taps from app open: phone, Ethereum wallet → Bridge (2), amount, the
//    button (3); BEAM wallet → More → Bridge (3), the button (4). Desktop:
//    the side menu's Bridge (1), the button (2). Then the review and PIN.
//
// No address is ever typed: the other side is always the user's own other
// wallet, named on its card (a picker when there are several).
//
// Exit-intent (§1.7):
// * "Where does it go?" — the To card names your own wallet and its
//   address.
// * "What does it cost?" — the bridge fee ("paid to the bridge
//   operator"), each network fee, all in the coin and in dollars, and the
//   limits before anything is typed.
// * "How long?" — about an hour to Ethereum (61 BEAM blocks, up to hours
//   when Ethereum gas is high), about 2 minutes to BEAM.
// * A greyed-out button with no reason — every blocked state says why
//   above it, and the next step (Get BEAM, Try again) is a button.
// * "Did my last one arrive?" — an open crossing is one tap away at the
//   top, with where it is.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_crossing.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../wallets/bridge/bridge_sides.dart';
import '../../widgets/beam/dex/dex_amount_field.dart';
import '../../widgets/beam/dex/dex_widgets.dart';
import '../../widgets/beam/stickers/beam_sticker.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import 'bridge_crossing_view.dart';
import 'bridge_crossings_view.dart';
import 'bridge_deps.dart';
import 'bridge_format.dart';
import 'bridge_review_view.dart';
import 'bridge_widgets.dart';

typedef _Cta = ({VoidCallback? onPressed, String? reason});

class BridgeMoveView extends StatefulWidget {
  const BridgeMoveView({
    super.key,
    required this.deps,
    this.initialRoute,
    this.initialDirection = BridgeDirection.toEthereum,
    this.embedded = false,
  });

  final BridgeDeps deps;

  /// The coin to start with (BEAM when null).
  final BridgeRoute? initialRoute;
  final BridgeDirection initialDirection;

  /// True inside the desktop view: the form without a page around it
  /// (its button pinned under it, so it needs a bounded height).
  final bool embedded;

  static Future<void> show(
    BuildContext context,
    BridgeDeps deps, {
    BridgeRoute? route,
    BridgeDirection direction = BridgeDirection.toEthereum,
  }) => showDexPage<void>(
    context,
    deps,
    (_) => BridgeMoveView(
      deps: deps,
      initialRoute: route,
      initialDirection: direction,
    ),
  );

  @override
  State<BridgeMoveView> createState() => _BridgeMoveViewState();
}

class _BridgeMoveViewState extends State<BridgeMoveView> {
  late BridgeRoute _route = widget.initialRoute ?? kBridgeRoutes.first;
  late BridgeDirection _direction = widget.initialDirection;
  final _amount = TextEditingController();
  BridgeAmountInput _input = BridgeAmountInput.empty;

  BridgeController? _controller;
  Object? _controllerError;
  BridgeConditions? _cond;
  BridgeBalances? _bal;
  BridgeQuote? _quote;
  bool _quoting = false;
  bool _busy = false;
  String? _error;
  Timer? _debounce;
  int _seq = 0;

  BridgeDeps get deps => widget.deps;
  bool get _toEth => _direction == BridgeDirection.toEthereum;
  int get _srcDec => _route.sourceDecimals(_direction);
  String get _srcSym => _route.sourceSymbol(_direction);

  @override
  void initState() {
    super.initState();
    deps.changes.addListener(_pairChanged);
    deps.beamCanSpend?.addListener(_rebuild);
    unawaited(_loadController());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    deps.changes.removeListener(_pairChanged);
    deps.beamCanSpend?.removeListener(_rebuild);
    _controller?.removeListener(_rebuild);
    _amount.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _pairChanged() {
    _controller?.removeListener(_rebuild);
    setState(() {
      _controller = null;
      _cond = null;
      _bal = null;
      _quote = null;
    });
    unawaited(_loadController());
  }

  Future<void> _loadController() async {
    final f = deps.controller;
    if (f == null) return;
    try {
      final c = await f;
      if (!mounted) return;
      c.addListener(_rebuild);
      setState(() {
        _controller = c;
        _controllerError = null;
      });
      await _refresh();
    } catch (e) {
      if (mounted) setState(() => _controllerError = e);
    }
  }

  /// Fee, freezes and balances for the coin and direction now chosen.
  Future<void> _refresh({bool force = false}) async {
    final c = _controller;
    if (c == null) return;
    final route = _route;
    final dir = _direction;
    final seq = ++_seq;
    try {
      final r = await Future.wait<Object>([
        c.conditions(route, dir, refresh: force),
        c.balances(route, dir),
      ]);
      if (!mounted || seq != _seq) return;
      setState(() {
        _cond = r[0] as BridgeConditions;
        _bal = r[1] as BridgeBalances;
      });
    } catch (_) {
      // The quote says what is wrong once an amount is typed.
    }
    if (mounted && seq == _seq && _input.isPositive) await _requote();
  }

  // ------------------------------------------------------------------ input

  void _pick(BridgeRoute r) {
    if (r == _route) return;
    setState(() => _route = r);
    _clear();
  }

  void _flip() {
    setState(
      () => _direction = _toEth
          ? BridgeDirection.toBeam
          : BridgeDirection.toEthereum,
    );
    _clear();
  }

  void _clear() {
    _amount.clear();
    _debounce?.cancel();
    setState(() {
      _input = BridgeAmountInput.empty;
      _quote = null;
      _cond = null;
      _bal = null;
      _error = null;
    });
    unawaited(_refresh());
  }

  void _onAmountChanged(String text) {
    _debounce?.cancel();
    _seq++;
    setState(() {
      _input = BridgeFormat.parse(text, _route, _direction);
      _quote = null;
      _error = null;
      _quoting = _input.isPositive;
    });
    if (_input.isPositive) {
      _debounce = Timer(const Duration(milliseconds: 450), _requote);
    }
  }

  Future<void> _useMax() async {
    final c = _controller;
    if (c == null) return;
    final BigInt max;
    try {
      max = await c.maxAmount(_route, _direction);
    } catch (_) {
      // Nothing typed: the quote says what is wrong once there is.
      return;
    }
    if (!mounted) return;
    _amount.text = BridgeFormat.plain(max, _srcDec);
    _onAmountChanged(_amount.text);
  }

  Future<void> _requote() async {
    final c = _controller;
    final amount = _input.value;
    if (c == null || amount == null || amount <= BigInt.zero) return;
    final seq = ++_seq;
    setState(() => _quoting = true);
    final q = await c.quote(_route, _direction, amount);
    if (!mounted || seq != _seq) return;
    setState(() {
      _quote = q;
      _quoting = false;
    });
  }

  // ------------------------------------------------------------------ move

  Future<void> _review() async {
    final c = _controller;
    final q = _quote;
    if (c == null || q == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    BridgePrepared prepared;
    try {
      prepared = await c.prepare(q);
    } on BridgeException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            "Couldn't get the transaction ready: one of your wallets did "
            'not answer. Nothing was sent.';
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final crossing = await BridgeReviewView.show(
      context,
      deps: deps,
      controller: c,
      prepared: prepared,
    );
    if (!mounted) return;
    if (crossing == null) {
      // Back without moving: the fee may have moved meanwhile.
      unawaited(_refresh(force: true));
      return;
    }
    _amount.clear();
    _onAmountChanged('');
    unawaited(_refresh());
    await _openCrossing(crossing);
  }

  Future<void> _openCrossing(String id) async {
    final c = _controller;
    if (c == null) return;
    await BridgeCrossingView.show(context, deps: deps, controller: c, id: id);
  }

  Future<void> _openHistory() async {
    final c = _controller;
    if (c == null) return;
    await BridgeCrossingsView.show(context, deps: deps, controller: c);
  }

  // ------------------------------------------------------------------ state

  _Cta _cta() {
    if (_busy) return _off('Getting the transaction ready…');
    if (_controller == null) return _off(null);
    if (_toEth && !(deps.beamCanSpend?.value ?? true)) {
      return _off(
        'Your BEAM wallet is catching up with the network. Moving works '
        'once it is up to date.',
      );
    }
    if (_input.error != null) return _off(_input.error);
    final amount = _input.value;
    if (amount == null || amount == BigInt.zero) {
      return _off('Enter how much $_srcSym to move.');
    }
    final q = _quote;
    if (_quoting || q == null) return _off('Working out the fees…');
    final block = q.block;
    if (block != null) return _off(block.title);
    return (onPressed: _review, reason: null);
  }

  static _Cta _off(String? reason) => (onPressed: null, reason: reason);

  String get _ctaLabel {
    final amount = _input.value;
    final where = _toEth ? 'Ethereum' : 'BEAM';
    if (amount == null || amount <= BigInt.zero) return 'Move to $where';
    return 'Move ${BridgeFormat.coin(amount, _srcDec, _srcSym)} to $where';
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final missing = _missingWallet();
    if (missing != null) {
      return _page(context, missing.$1, missing.$2, fill: false);
    }
    final cta = _cta();
    final bottom = DexPrimaryAction(
      deps: deps,
      buttonKey: const Key('bridge-cta'),
      label: _ctaLabel,
      reason: cta.reason,
      onPressed: cta.onPressed,
    );
    return _page(context, _form(context), bottom);
  }

  Widget _page(
    BuildContext context,
    Widget body,
    Widget bottom, {
    bool fill = true,
  }) {
    if (widget.embedded && !fill) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [body, const SizedBox(height: 16), bottom],
      );
    }
    if (widget.embedded) {
      // The button stays in sight in an 800 px window (USER_PSYCHOLOGY
      // §1.3); the form scrolls above it.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: SingleChildScrollView(child: body)),
          const SizedBox(height: 16),
          bottom,
        ],
      );
    }
    final open = _controller?.crossings.where((c) => c.isOpen).length ?? 0;
    return DexPage(
      deps: deps,
      title: 'Bridge',
      body: body,
      bottom: bottom,
      actions: [
        if (_controller != null)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: CustomTextButton(
                key: const Key('bridge-history'),
                text: open == 0 ? 'History' : 'History ($open)',
                onTap: () => unawaited(_openHistory()),
              ),
            ),
          ),
      ],
    );
  }

  /// With a wallet missing: what to do instead, and its button.
  (Widget, Widget)? _missingWallet() {
    final noEth = deps.ethWallets.isEmpty;
    final noBeam = deps.beamWallets.isEmpty;
    if (!noEth && !noBeam) return null;
    final add = noBeam ? deps.onAddBeamWallet : deps.onAddEthereumWallet;
    final label = noBeam ? 'Add a BEAM wallet' : 'Add an Ethereum wallet';
    return (
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.embedded) ...[
            _intro(context),
            const SizedBox(height: 12),
          ],
          DexNotice(
            key: const Key('bridge-no-wallet'),
            sticker: BeamMoments.trading,
            title: '$label to use the bridge',
            detail:
                'The bridge moves coins between your own BEAM wallet and '
                'your own Ethereum wallet, so you need one of each. '
                '${noBeam ? 'A BEAM wallet' : 'An Ethereum wallet'} takes a '
                'minute to add; then come back here.',
          ),
        ],
      ),
      DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('bridge-add-wallet'),
        label: label,
        reason: add == null ? 'Add it from My Campfire.' : null,
        onPressed: add,
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Text(
      "Move coins between your own BEAM and Ethereum wallets, through "
      "BEAM's official bridge.",
      style: STextStyles.label(context).copyWith(color: colors.textSubtitle1),
    );
  }

  Widget _form(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final c = _controller;
    final q = _quote;
    final bal = _bal;
    final limits = bridgeLimitsText(_route, _direction, _cond);
    final open = c?.crossings.where((x) => x.isOpen).toList() ?? const [];
    final from = BridgeWalletCard(
      key: const Key('bridge-from'),
      label: 'From',
      chain: _toEth ? 'BEAM' : 'Ethereum',
      wallet: _toEth ? deps.beamWallet : deps.ethWallet,
      onTap: _pickerFor(beam: _toEth),
      trailing: Text(
        bal == null
            ? 'Balance …'
            : 'Balance ${BridgeFormat.coinShort(bal.source, _srcDec, _srcSym)}',
        key: const Key('bridge-balance'),
        style: STextStyles.label(context),
      ),
    );
    final to = BridgeWalletCard(
      key: const Key('bridge-to'),
      label: 'To',
      chain: _toEth ? 'Ethereum' : 'BEAM',
      wallet: _toEth ? deps.ethWallet : deps.beamWallet,
      onTap: _pickerFor(beam: !_toEth),
      note: _receives(context, q),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // On desktop the page's own header says it.
        if (!widget.embedded) _intro(context),
        if (open.isNotEmpty && !widget.embedded) ...[
          const SizedBox(height: 10),
          _openCrossingCard(context, c!, open.first),
        ],
        if (!widget.embedded) const SizedBox(height: 12),
        DexChoiceChips<BridgeRoute>(
          values: kBridgeRoutes,
          labelOf: (r) => r.isBeam ? 'BEAM' : r.ethSymbol,
          selected: _route,
          onSelected: _pick,
          keyOf: (r) => Key('bridge-route-${r.id}'),
        ),
        const SizedBox(height: 12),
        if (_controllerError != null) ...[
          DexNotice(
            key: const Key('bridge-unavailable'),
            kind: DexNoticeKind.error,
            sticker: BeamMoments.somethingWentWrong,
            title: "Couldn't open the bridge for these wallets",
            detail:
                'One of your wallets did not start. This is not something '
                'you did, and nothing was sent.',
            actionLabel: 'Try again',
            onAction: () {
              setState(() => _controllerError = null);
              unawaited(_loadController());
            },
          ),
          const SizedBox(height: 12),
        ],
        from,
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Amount',
                style: STextStyles.itemSubtitle(context)
                    .copyWith(color: colors.textDark3),
              ),
            ),
            CustomTextButton(
              key: const Key('bridge-max'),
              text: 'Max',
              onTap: () => unawaited(_useMax()),
            ),
          ],
        ),
        const SizedBox(height: 6),
        DexAmountField(
          fieldKey: const Key('bridge-amount'),
          controller: _amount,
          asset: null,
          assetLabel: BridgeCoinLabel(route: _route, onBeam: _toEth),
          error: _input.error != null,
          onChanged: _onAmountChanged,
        ),
        DexWorth(
          _input.isPositive
              ? BridgeFormat.usd(
                  _cond?.prices,
                  _route.coingeckoId,
                  _input.value!,
                  _srcDec,
                )
              : null,
          textKey: const Key('bridge-amount-worth'),
        ),
        // Once priced, the costs under "You receive" say it with numbers.
        if (limits != null && q?.fee == null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              limits,
              key: const Key('bridge-limits'),
              style: STextStyles.label(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ),
        const SizedBox(height: 8),
        Center(child: DexFlipButton(onTap: _flip)),
        const SizedBox(height: 8),
        to,
        const SizedBox(height: 12),
        ..._notices(context, q),
        _details(context, q),
      ],
    );
  }

  VoidCallback? _pickerFor({required bool beam}) {
    final options = beam ? deps.beamWallets : deps.ethWallets;
    if (options.length < 2) return null;
    return () async {
      final id = await showBridgeWalletPicker(
        context,
        deps: deps,
        title: beam ? 'Your BEAM wallet' : 'Your Ethereum wallet',
        options: options,
        selected: beam ? deps.beamWalletId : deps.ethWalletId,
      );
      if (id == null || !mounted) return;
      beam ? deps.chooseBeam(id) : deps.chooseEth(id);
    };
  }

  Widget _receives(BuildContext context, BridgeQuote? q) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final dec = _route.destinationDecimals(_direction);
    final sym = _route.destinationSymbol(_direction);
    final worth = q == null
        ? null
        : BridgeFormat.usd(q.prices, _route.coingeckoId, q.receives, dec);
    final costs = q == null ? null : _costs(q);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        BridgeAssetIcon(route: _route, onBeam: !_toEth, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You receive',
                style: STextStyles.label(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
              Text(
                q == null
                    ? (_quoting ? '…' : '0 $sym')
                    : BridgeFormat.coin(q.receives, dec, sym),
                key: const Key('bridge-receive'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: STextStyles.titleBold12(context)
                    .copyWith(color: colors.textDark, fontSize: 18),
              ),
            ],
          ),
        ),
        if (worth != null)
          Text(
            worth,
            key: const Key('bridge-receive-worth'),
            style: STextStyles.label(context),
          ),
      ],
    );
    if (costs == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        const SizedBox(height: 6),
        Text(
          costs,
          key: const Key('bridge-costs'),
          style: STextStyles.label(context)
              .copyWith(color: colors.textSubtitle1),
        ),
      ],
    );
  }

  /// Every cost on top of the amount, and the time, in one line.
  String? _costs(BridgeQuote q) {
    final fee = q.fee;
    if (fee == null) return null;
    final bridge = BridgeFormat.coinShort(fee, _srcDec, _srcSym);
    final beamFee = BridgeFormat.coin(q.beamNetworkFee, 8, 'BEAM');
    if (_toEth) {
      return 'Plus $bridge bridge fee and $beamFee network fee. '
          '${BridgeFormat.about(BridgeTiming.toEthereum)}.';
    }
    final gas = q.plan?.maxGasCost;
    final eth = gas == null
        ? ''
        : ', up to ${BridgeFormat.coinShort(gas, 18, 'ETH')} network fee';
    return 'Plus $bridge bridge fee$eth, and $beamFee to collect it. '
        '${BridgeFormat.about(BridgeTiming.toBeam)}.';
  }

  List<Widget> _notices(BuildContext context, BridgeQuote? q) {
    final out = <Widget>[];
    void add(Widget w) => out.addAll([w, const SizedBox(height: 12)]);
    if (_error != null) {
      add(
        DexNotice(
          key: const Key('bridge-error'),
          kind: DexNoticeKind.warning,
          title: 'Nothing was sent',
          detail: _error,
        ),
      );
    }
    final block = q?.block ?? (_input.isPositive ? null : _cond?.block);
    if (block != null && block.code != BridgeBlockCode.noAmount) {
      final (label, action) = switch (block.code) {
        BridgeBlockCode.noClaimFee ||
        BridgeBlockCode.noBeamForFee => ('Get BEAM', deps.onGetBeam),
        BridgeBlockCode.network || BridgeBlockCode.noPrice => (
          'Try again',
          () => unawaited(_refresh(force: true)),
        ),
        _ => (null, null),
      };
      add(
        DexNotice(
          key: const Key('bridge-block'),
          kind: block.code == BridgeBlockCode.frozen
              ? DexNoticeKind.error
              : DexNoticeKind.warning,
          title: block.title,
          detail: block.detail,
          actionLabel: action == null ? null : label,
          onAction: action,
        ),
      );
    }
    for (final w in q?.warnings ?? const <BridgeWarning>[]) {
      add(
        DexNotice(
          key: Key('bridge-warning-${w.code.name}'),
          kind: DexNoticeKind.warning,
          title: w.title,
          detail: w.detail,
        ),
      );
    }
    return out;
  }

  Widget _details(BuildContext context, BridgeQuote? q) {
    final fee = q?.fee ?? _cond?.fee;
    final prices = q?.prices ?? _cond?.prices;
    final plan = q?.plan;
    return DexCard(
      child: Column(
        children: [
          DexDetailRow(
            label: 'Bridge fee, paid to the bridge operator',
            valueKey: const Key('bridge-fee'),
            value: fee == null
                ? (_cond == null ? '…' : 'Unknown')
                : BridgeFormat.coinShort(fee, _srcDec, _srcSym),
            note: fee == null
                ? null
                : BridgeFormat.usd(prices, _route.coingeckoId, fee, _srcDec),
          ),
          DexDetailRow(
            label: _toEth
                ? 'BEAM network fee'
                : 'BEAM network fee, when you collect it',
            valueKey: const Key('bridge-beam-fee'),
            value: BridgeFormat.coin(
              _toEth ? kBridgeSendFeeGroth : kBridgeClaimFeeGroth,
              8,
              'BEAM',
            ),
            note: BridgeFormat.usd(
              prices,
              'beam',
              _toEth ? kBridgeSendFeeGroth : kBridgeClaimFeeGroth,
              8,
            ),
          ),
          if (!_toEth)
            DexDetailRow(
              label: 'Ethereum network fee',
              valueKey: const Key('bridge-eth-fee'),
              value: plan == null
                  ? 'Priced once you type an amount'
                  : 'up to '
                        '${BridgeFormat.coinShort(plan.maxGasCost, 18, 'ETH')}',
              note: plan == null
                  ? null
                  : BridgeFormat.usd(prices, 'ethereum', plan.maxGasCost, 18),
            ),
          DexDetailRow(
            label: 'Arrives',
            valueKey: const Key('bridge-time'),
            value: _toEth
                ? BridgeFormat.about(BridgeTiming.toEthereum)
                : '${BridgeFormat.about(BridgeTiming.toBeam)}, then you '
                      'collect it',
            note: _toEth
                ? '${BridgeFormat.upTo(BridgeTiming.toEthereumSlowest(_route))}'
                      ' when Ethereum is busy'
                : null,
          ),
        ],
      ),
    );
  }

  Widget _openCrossingCard(
    BuildContext context,
    BridgeController c,
    BridgeCrossing x,
  ) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final words = BridgeWords.of(x, blocksLeft: c.blocksLeft(x));
    return DexCard(
      key: const Key('bridge-open-crossing'),
      onTap: () => unawaited(_openCrossing(x.id)),
      child: Row(
        children: [
          Icon(
            Icons.hourglass_top_rounded,
            size: 18,
            color: colors.accentColorOrange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              bridgeHeadline(x),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textDark),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            words.short,
            style: STextStyles.label(context)
                .copyWith(color: words.color(colors)),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: colors.textSubtitle1,
          ),
        ],
      ),
    );
  }
}
