/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: put this name up for sale at a price, knowing that anyone can
//    then buy it at once.
// 2. Primary CTA: "List alice for 500 BEAM".
// 3. Taps from app open: Names (1) → alice (2) → Sell (3) → price →
//    List alice (4) → List alice for sale (5) → PIN.
//
// Exit-intent (§1.7) — what could make an impatient person leave:
// * "Will I have to approve each buyer?" — no; said before listing.
// * "Where does the money go?" — into the BEAM vault under this wallet's
//   key, claimed on the Names screen; said before listing.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import 'beam_name_confirm_view.dart';

/// Lists one of my names for sale.
class BeamNameSellView extends StatefulWidget {
  const BeamNameSellView({
    super.key,
    required this.deps,
    required this.domain,
    required this.clock,
  });

  final BeamNamesDeps deps;
  final BansDomain domain;
  final BansClock clock;

  static Future<BeamNameSent?> show(
    BuildContext context, {
    required BeamNamesDeps deps,
    required BansDomain domain,
    required BansClock clock,
  }) => showNamesPage<BeamNameSent>(
    context,
    deps,
    (_) => BeamNameSellView(deps: deps, domain: domain, clock: clock),
  );

  @override
  State<BeamNameSellView> createState() => _BeamNameSellViewState();
}

class _BeamNameSellViewState extends State<BeamNameSellView> {
  final _controller = TextEditingController();
  int _assetId = 0;
  BigInt? _amount;
  bool _preparing = false;
  String? _error;

  BeamNamesDeps get deps => widget.deps;
  String get _name => widget.domain.name;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<int> get _assets => [
    0,
    ...(deps.balances.value.keys.where((a) => a != 0).toList()..sort()),
  ];

  String get _priceText => _amount == null
      ? ''
      : '${NamesFormat.readable(_amount!)} ${deps.symbol(_assetId)}';

  Future<void> _list() async {
    final name = BansName(_name);
    final aid = _assetId;
    final amount = _amount!;
    Future<BansPrepared> build() =>
        deps.bans.prepareSetPrice(name, aid, amount);
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
      clock: widget.clock,
    );
    if (sent != null && mounted) Navigator.of(context).pop(sent);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final until = NamesFormat.date(
      widget.clock.dateOf(widget.domain.expireHeight),
    );
    final fieldDecoration = BoxDecoration(
      color: colors.textFieldDefaultBG,
      borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
    );
    return NamesPage(
      deps: deps,
      title: 'Sell $_name',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NamesSyncBanner(deps: deps),
          Text(
            'Anyone can buy $_name instantly at the price you set, without '
            'asking you. The payment waits for you on the Names screen, '
            'where you claim it.',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textDark3),
          ),
          const SizedBox(height: 16),
          const NamesSectionLabel('Price'),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 48,
                  decoration: fieldDecoration,
                  child: TextField(
                    key: const Key('names-sell-amount'),
                    controller: _controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [_AmountFormatter()],
                    textAlignVertical: TextAlignVertical.center,
                    onChanged: (t) => setState(() {
                      _amount = NamesFormat.parse(t);
                      _error = null;
                    }),
                    style: STextStyles.field(context),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      hintText: '0.00',
                      hintStyle: STextStyles.fieldLabel(context),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: fieldDecoration,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('names-sell-asset'),
                    value: _assetId,
                    items: [
                      for (final a in _assets)
                        DropdownMenuItem(
                          value: a,
                          child: Text(
                            deps.symbol(a),
                            style: STextStyles.w500_14(context),
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _assetId = v ?? 0),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          NamesCard(
            child: Column(
              children: [
                NamesDetailRow(
                  label: 'The buyer gets',
                  value: '$_name until ≈ $until',
                ),
                const NamesDetailRow(
                  label: 'To list it',
                  value: '≈ 0.011 BEAM network fee',
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You can stop selling at any time until someone buys it.',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NamesNotice(
              key: const Key('names-sell-error'),
              kind: NamesNoticeKind.error,
              title: "Couldn't prepare the listing",
              detail: _error,
            ),
          ],
        ],
      ),
      bottom: NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-sell-cta'),
        label: _preparing
            ? 'Preparing…'
            : _amount == null
            ? 'List $_name for sale'
            : 'List $_name for $_priceText',
        onPressed: _amount == null || _preparing ? null : _list,
        reason: _amount == null && !_preparing
            ? 'Enter the price you want for $_name.'
            : null,
      ),
    );
  }
}

/// Digits and one decimal point with at most eight decimals.
class _AmountFormatter extends TextInputFormatter {
  static final _ok = RegExp(r'^\d*\.?\d{0,8}$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => _ok.hasMatch(newValue.text) ? newValue : oldValue;
}
