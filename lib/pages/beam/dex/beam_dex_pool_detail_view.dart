/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: put coins into this pool, or take yours out.
// 2. Primary CTA: "Add liquidity" (or "Withdraw" when that tab is chosen);
//    only one is ever shown.
// 3. Taps from app open: wallet → Swap → Pools → pool (4), amount,
//    "Add liquidity" (5); then the confirmation and the PIN.
//
// Exit-intent — what could make an impatient person leave:
// * Having to work out the second amount — type one side, the pool's
//   shader computes the other (it is never guessed in the app).
// * Not knowing what the position is worth — "Your share of the pool" and
//   its value in BEAM (and the user's currency) are at the top; the pool's
//   size, every amount typed and what a withdrawal returns say what they
//   are worth too.
// * A first deposit into an empty pool silently setting a bad price — the
//   screen says so before anything is typed.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_quotes.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_service.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../../wallets/beam/contracts/dex/dex_constants.dart';
import '../../../widgets/beam/dex/dex_amount_field.dart';
import '../../../widgets/beam/dex/dex_asset_icon.dart';
import '../../../widgets/beam/dex/dex_deps.dart';
import '../../../widgets/beam/dex/dex_format.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import 'beam_dex_confirm_view.dart';

enum BeamDexLiquidityMode { add, withdraw }

/// One pool: its price and reserves, the user's position, and adding or
/// withdrawing liquidity.
class BeamDexPoolDetailView extends StatefulWidget {
  const BeamDexPoolDetailView({
    super.key,
    required this.deps,
    required this.pool,
    this.initialMode = BeamDexLiquidityMode.add,
  });

  final BeamDexDeps deps;
  final BeamPool pool;
  final BeamDexLiquidityMode initialMode;

  @override
  State<BeamDexPoolDetailView> createState() => _BeamDexPoolDetailViewState();
}

class _BeamDexPoolDetailViewState extends State<BeamDexPoolDetailView> {
  late BeamPool _pool = widget.pool;
  late BeamDexLiquidityMode _mode = widget.initialMode;

  // Add.
  final _c1 = TextEditingController();
  final _c2 = TextEditingController();
  DexAmountInput _in1 = DexAmountInput.empty;
  DexAmountInput _in2 = DexAmountInput.empty;
  int? _edited; // 1 or 2: the side the user typed; the other is computed
  BeamLiquidityQuote? _addQuote;

  // Withdraw.
  int _pct = 100;
  BeamWithdrawQuote? _withdrawQuote;

  bool _quoting = false;
  String? _problem;
  bool _preparing = false;
  int _seq = 0;
  Timer? _debounce;

  BeamDexDeps get deps => widget.deps;

  BigInt get _lpHeld => deps.available(_pool.lpToken);

  @override
  void initState() {
    super.initState();
    deps.pools.addListener(_onPools);
    deps.changes.addListener(_rebuild);
    // For the position's value and LP-token names; usually already here.
    unawaited(deps.pools.ensureLoaded());
    if (_mode == BeamDexLiquidityMode.withdraw) _requoteWithdraw();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    deps.pools.removeListener(_onPools);
    deps.changes.removeListener(_rebuild);
    _c1.dispose();
    _c2.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) return;
    // A side typed while its decimals were unknown is read now they are known.
    final unknown = appL10n.dexAmountDecimalsUnknown;
    if (_in1.error == unknown && deps.decimals(_pool.aid1) != null) {
      _onChanged(1, _c1.text);
    }
    if (_in2.error == unknown && deps.decimals(_pool.aid2) != null) {
      _onChanged(2, _c2.text);
    }
    setState(() {});
  }

  void _onPools() {
    for (final p in deps.pools.all ?? const <BeamPool>[]) {
      final same =
          p.aid1 == _pool.aid1 && p.aid2 == _pool.aid2 && p.kind == _pool.kind;
      if (same) _pool = p;
    }
    _rebuild();
  }

  String _sym(int a) => deps.display(a).symbol;

  // -------------------------------------------------------------------- add

  void _onChanged(int side, String text) {
    _debounce?.cancel();
    _seq++;
    setState(() {
      _problem = null;
      _addQuote = null;
      if (side == 1) {
        _in1 = DexFormat.parse(text, places: deps.decimals(_pool.aid1));
      } else {
        _in2 = DexFormat.parse(text, places: deps.decimals(_pool.aid2));
      }
      if (!_pool.isEmpty) {
        // One side drives; the other is computed by the shader.
        _edited = side;
        if (side == 1) {
          _c2.text = '';
          _in2 = DexAmountInput.empty;
        } else {
          _c1.text = '';
          _in1 = DexAmountInput.empty;
        }
      }
      _quoting = _wantsAddQuote;
    });
    if (_wantsAddQuote) {
      _debounce = Timer(const Duration(milliseconds: 500), _requoteAdd);
    }
  }

  bool get _wantsAddQuote => _pool.isEmpty
      ? _in1.isPositive && _in2.isPositive
      : (_edited == 1 ? _in1.isPositive : _in2.isPositive);

  BigInt? get _given1 => _pool.isEmpty || _edited == 1 ? _in1.value : null;
  BigInt? get _given2 => _pool.isEmpty || _edited == 2 ? _in2.value : null;

  Future<void> _requoteAdd() async {
    if (!_wantsAddQuote) return;
    final seq = ++_seq;
    setState(() => _quoting = true);
    try {
      final q = await deps.dex.quoteAddLiquidity(
        pool: _pool,
        amount1: _given1,
        amount2: _given2,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _addQuote = q;
        _quoting = false;
        if (!_pool.isEmpty) {
          if (_edited == 1) {
            _c2.text = DexFormat.plain(
              q.amount2,
              places: deps.decimals(_pool.aid2),
            );
          } else {
            _c1.text = DexFormat.plain(
              q.amount1,
              places: deps.decimals(_pool.aid1),
            );
          }
        }
      });
    } on BeamDexException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = e.code == BeamDexErrorCode.ratioMismatch
            ? context.l10n.dexRatioMismatch
            : context.l10n.dexDepositRefused(e.message);
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _quoting = false;
        _problem = context.l10n.dexOtherAmountFailed;
      });
    }
  }

  // --------------------------------------------------------------- withdraw

  BigInt get _lpToBurn {
    final held = _lpHeld;
    if (_pct >= 100) return held;
    return held * BigInt.from(_pct) ~/ BigInt.from(100);
  }

  void _setPct(int pct) {
    setState(() {
      _pct = pct;
      _withdrawQuote = null;
      _problem = null;
    });
    _requoteWithdraw();
  }

  void _requoteWithdraw() {
    final lp = _lpToBurn;
    if (lp <= BigInt.zero) return;
    final seq = ++_seq;
    _quoting = true;
    unawaited(() async {
      try {
        final q = await deps.dex.quoteWithdraw(pool: _pool, lpAmount: lp);
        if (!mounted || seq != _seq) return;
        setState(() {
          _withdrawQuote = q;
          _quoting = false;
        });
      } catch (_) {
        if (!mounted || seq != _seq) return;
        setState(() {
          _quoting = false;
          _problem = context.l10n.dexWithdrawQuoteFailed;
        });
      }
    }());
  }

  void _setMode(BeamDexLiquidityMode m) {
    if (m == _mode) return;
    _debounce?.cancel();
    _seq++;
    setState(() {
      _mode = m;
      _problem = null;
      _quoting = false;
    });
    if (m == BeamDexLiquidityMode.withdraw) _requoteWithdraw();
  }

  // ---------------------------------------------------------------- prepare

  Future<void> _prepare() async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    final BeamPreparedDexCall prepared;
    try {
      prepared = _mode == BeamDexLiquidityMode.add
          ? await deps.dex.prepareAddLiquidity(
              pool: _pool,
              amount1: _given1,
              amount2: _given2,
              quote: _addQuote,
            )
          : await deps.dex.prepareWithdraw(
              pool: _pool,
              lpAmount: _lpToBurn,
              quote: _withdrawQuote,
            );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _problem = context.l10n.dexLiquidityBuildFailed;
      });
      return;
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    final txId = await BeamDexConfirmView.show(
      context,
      deps: deps,
      prepared: prepared,
    );
    if (!mounted || txId == null) return;
    setState(() {
      _c1.clear();
      _c2.clear();
      _in1 = DexAmountInput.empty;
      _in2 = DexAmountInput.empty;
      _addQuote = null;
      _withdrawQuote = null;
    });
  }

  // ------------------------------------------------------------------ state

  ({VoidCallback? onPressed, String? reason}) _cta() {
    final l10n = context.l10n;
    if (_preparing) return (onPressed: null, reason: l10n.dexBuildingTx);
    if (!deps.canSpend) {
      return (onPressed: null, reason: l10n.dexPausedUntilSynced);
    }
    final fee = kDexCallFee;
    final beam = deps.available(0);
    if (_mode == BeamDexLiquidityMode.withdraw) {
      if (_lpHeld <= BigInt.zero) {
        return (onPressed: null, reason: l10n.dexNoCoinsInPool);
      }
      final q = _withdrawQuote;
      if (_problem != null) return (onPressed: null, reason: null);
      if (q == null || _quoting) {
        return (onPressed: null, reason: l10n.dexWorkingOutBack);
      }
      final beamBack = _pool.aid1 == 0 ? q.amount1 : BigInt.zero;
      if (fee - beamBack > beam) {
        return (
          onPressed: null,
          reason: l10n.dexNeedBeamForFee(
            '${DexFormat.exact(fee)} BEAM',
            '${DexFormat.exact(beam)} BEAM',
          ),
        );
      }
      return (onPressed: _prepare, reason: null);
    }
    // Both sides are paid: each is typed, computed and confirmed in its own
    // decimals, so neither may be unknown.
    for (final aid in [_pool.aid1, _pool.aid2]) {
      if (deps.decimals(aid) == null) {
        return (
          onPressed: null,
          reason: l10n.sendAssetDecimalsUnknown(_sym(aid)),
        );
      }
    }
    final err = _in1.error ?? _in2.error;
    if (err != null) return (onPressed: null, reason: err);
    if (!_wantsAddQuote) {
      return (
        onPressed: null,
        reason: _pool.isEmpty
            ? l10n.dexEnterBothAmounts
            : l10n.dexEnterAddAmount(_sym(_pool.aid1), _sym(_pool.aid2)),
      );
    }
    if (_problem != null) return (onPressed: null, reason: null);
    final q = _addQuote;
    if (q == null || _quoting) {
      return (onPressed: null, reason: l10n.dexWorkingOutOther);
    }
    for (final (aid, amount) in [
      (_pool.aid1, q.amount1),
      (_pool.aid2, q.amount2),
    ]) {
      final have = deps.available(aid);
      if (amount > have) {
        return (
          onPressed: null,
          reason: l10n.dexNotEnoughForDeposit(
            _sym(aid),
            DexFormat.exact(amount, places: deps.decimals(aid)),
            DexFormat.exact(have, places: deps.decimals(aid)),
          ),
        );
      }
    }
    final beamOut = (_pool.aid1 == 0 ? q.amount1 : BigInt.zero) + fee;
    if (beamOut > beam) {
      return (
        onPressed: null,
        reason: l10n.dexNotEnoughBeamWithFee(
          '${DexFormat.exact(beamOut)} BEAM',
          '${DexFormat.exact(fee)} BEAM',
        ),
      );
    }
    return (onPressed: _prepare, reason: null);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final cta = _cta();
    return DexPage(
      deps: deps,
      title: context.l10n.dexPoolTitle(
        '${_sym(_pool.aid1)}/${_sym(_pool.aid2)}',
      ),
      body: _body(context),
      bottom: DexPrimaryAction(
        deps: deps,
        buttonKey: const Key('dex-liquidity-cta'),
        label: _mode == BeamDexLiquidityMode.add
            ? context.l10n.dexAddLiquidityCta
            : context.l10n.dexWithdrawCta,
        reason: cta.reason,
        onPressed: cta.onPressed,
      ),
    );
  }

  Widget _body(BuildContext context) {
    final held = _lpHeld;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DexSyncBanner(deps: deps),
        _header(context),
        const SizedBox(height: 12),
        if (held > BigInt.zero) ...[
          _position(context, held),
          const SizedBox(height: 12),
          DexChoiceChips<BeamDexLiquidityMode>(
            values: BeamDexLiquidityMode.values,
            selected: _mode,
            labelOf: (m) => m == BeamDexLiquidityMode.add
                ? context.l10n.dexModeAdd
                : context.l10n.dexModeWithdraw,
            keyOf: (m) => Key('dex-mode-${m.name}'),
            onSelected: _setMode,
          ),
          const SizedBox(height: 12),
        ],
        if (_mode == BeamDexLiquidityMode.add)
          _addForm(context)
        else
          _withdrawForm(context),
        if (_problem != null) ...[
          const SizedBox(height: 12),
          DexNotice(
            key: const Key('dex-liquidity-problem'),
            sticker: BeamMoments.somethingWentWrong,
            kind: DexNoticeKind.error,
            title: _problem!,
          ),
        ],
      ],
    );
  }

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final a1 = deps.display(_pool.aid1);
    final a2 = deps.display(_pool.aid2);
    return DexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              DexPairIcon(first: a1, second: a2, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // "BEAM / FOMO", "BEAM / PEPE #777", "BEAM / (BEAM/NPH LP)".
                  [a1, a2]
                      .map((a) => a.isPoolShare ? '(${a.label})' : a.label)
                      .join(' / '),
                  style: STextStyles.pageTitleH2(context),
                ),
              ),
              Text(
                DexFormat.feeTier(_pool.kind),
                style: STextStyles.label(context)
                    .copyWith(color: colors.textDark3),
              ),
            ],
          ),
          if (a1.impersonates != null) DexImpersonationWarning(asset: a1),
          if (a2.impersonates != null) DexImpersonationWarning(asset: a2),
          const SizedBox(height: 8),
          if (_pool.isEmpty)
            DexNotice(
              key: const Key('dex-pool-is-empty'),
              kind: DexNoticeKind.warning,
              title: context.l10n.dexPoolIsEmptyTitle,
              detail: context.l10n.dexPoolIsEmptyDetail,
            )
          else ...[
            DexDetailRow(
              label: context.l10n.dexPriceLabel,
              valueKey: const Key('dex-pool-price'),
              value:
                  '1 ${a1.symbol} = '
                  '${DexFormat.number(deps.wholeRate(_pool.spotPriceOf(_pool.aid1), _pool.aid1, _pool.aid2))} '
                  '${a2.symbol}',
            ),
            DexDetailRow(
              label: context.l10n.dexInPoolLabel,
              valueKey: const Key('dex-pool-reserves'),
              value:
                  '${DexFormat.compact(_pool.tok1, places: deps.decimals(_pool.aid1))} ${a1.symbol} · '
                  '${DexFormat.compact(_pool.tok2, places: deps.decimals(_pool.aid2))} ${a2.symbol}',
              note: switch (deps.poolSize(_pool)) {
                null => context.l10n.dexNoPrice,
                final size => deps.worthOfBeam(size, inBeam: true),
              },
              noteKey: const Key('dex-pool-size'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _position(BuildContext context, BigInt held) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final pos = _pool.position(held);
    final value = deps.valueInBeam(_pool.lpToken, held);
    final String worth;
    if (value == null) {
      worth = context.l10n.dexPositionNotPriced;
    } else {
      // "12.34 BEAM · 0.11 USD": the label already says "about".
      final money = deps.fiat?.value?.approx(value)?.replaceFirst('≈ ', '');
      worth =
          '${DexFormat.compact(value)} BEAM'
          '${money == null ? '' : ' · $money'}';
    }
    return DexCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DexDetailRow(
            label: context.l10n.dexYourShareLabel,
            valueKey: const Key('dex-position-share'),
            value: DexFormat.percent(pos.share),
            valueColor: colors.accentColorGreen,
          ),
          DexDetailRow(
            label: context.l10n.dexWorthAboutLabel,
            valueKey: const Key('dex-position-value'),
            value: worth,
          ),
        ],
      ),
    );
  }

  Widget _addForm(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final labelStyle = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    final q = _addQuote;
    Widget side(int n) {
      final aid = n == 1 ? _pool.aid1 : _pool.aid2;
      final computed = !_pool.isEmpty && _edited != null && _edited != n;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  computed
                      ? context.l10n.dexMatchingAmount
                      : context.l10n.dexYouAdd,
                  style: labelStyle,
                ),
              ),
              Text(
                context.l10n.dexBalance(
                  '${DexFormat.compact(deps.available(aid), places: deps.decimals(aid))} ${_sym(aid)}',
                ),
                style: STextStyles.label(context),
              ),
              const SizedBox(width: 8),
              CustomTextButton(
                key: Key('dex-add-max-$n'),
                text: context.l10n.dexMax,
                onTap: () => _addMax(n),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DexAmountField(
            fieldKey: Key('dex-add-amount-$n'),
            controller: n == 1 ? _c1 : _c2,
            asset: deps.display(aid),
            hint: computed && _quoting ? '…' : '0',
            error: (n == 1 ? _in1 : _in2).error != null,
            onChanged: (t) => _onChanged(n, t),
          ),
          DexWorth(
            deps.worth(
              aid,
              DexFormat.parse(
                    (n == 1 ? _c1 : _c2).text,
                    places: deps.decimals(aid),
                  ).value ??
                  BigInt.zero,
            ),
            textKey: Key('dex-add-worth-$n'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        side(1),
        const SizedBox(height: 10),
        side(2),
        if (q != null) ...[
          const SizedBox(height: 12),
          DexCard(
            child: Column(
              children: [
                DexDetailRow(
                  label: context.l10n.dexShareAfterLabel,
                  valueKey: const Key('dex-add-share'),
                  value: DexFormat.percent(q.shareOfPoolAfter),
                ),
                DexDetailRow(
                  label: context.l10n.beamNetworkFee,
                  value: '≈ ${DexFormat.exact(q.networkFee)} BEAM',
                  note: deps.worthOfBeam(q.networkFee),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// What a withdrawal returns, both sides together: "≈ 4.10 USD", or
  /// "No price" when a side has none.
  String? _backWorth(BeamWithdrawQuote q) {
    final v1 = deps.valueInBeam(_pool.aid1, q.amount1);
    final v2 = deps.valueInBeam(_pool.aid2, q.amount2);
    if (v1 == null || v2 == null) return context.l10n.dexNoPrice;
    return deps.worthOfBeam(v1 + v2, inBeam: true);
  }

  void _addMax(int n) {
    final aid = n == 1 ? _pool.aid1 : _pool.aid2;
    var max = deps.available(aid);
    if (aid == 0) max -= kDexCallFee;
    if (max < BigInt.zero) max = BigInt.zero;
    final c = n == 1 ? _c1 : _c2;
    c.text = DexFormat.plain(max, places: deps.decimals(aid));
    _onChanged(n, c.text);
  }

  Widget _withdrawForm(BuildContext context) {
    final q = _withdrawQuote;
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.dexWithdrawHowMuch,
          style: STextStyles.itemSubtitle(context)
              .copyWith(color: colors.textDark3),
        ),
        const SizedBox(height: 6),
        DexChoiceChips<int>(
          values: const [25, 50, 75, 100],
          selected: _pct,
          labelOf: (p) => '$p%',
          keyOf: (p) => Key('dex-withdraw-$p'),
          onSelected: _setPct,
        ),
        const SizedBox(height: 12),
        DexCard(
          child: Column(
            children: [
              DexDetailRow(
                label: context.l10n.dexYouGetBack,
                valueKey: const Key('dex-withdraw-back'),
                value: q == null
                    ? (_quoting ? '…' : '—')
                    : '${DexFormat.exact(q.amount1, places: deps.decimals(_pool.aid1))} ${_sym(_pool.aid1)} + '
                          '${DexFormat.exact(q.amount2, places: deps.decimals(_pool.aid2))} ${_sym(_pool.aid2)}',
                note: q == null ? null : _backWorth(q),
                noteKey: const Key('dex-withdraw-worth'),
              ),
              DexDetailRow(
                label: context.l10n.beamNetworkFee,
                value: '≈ ${DexFormat.exact(kDexCallFee)} BEAM',
                note: deps.worthOfBeam(kDexCallFee),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
