/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. ONE job: pick the token to pay with or to receive.
// 2. Primary action: tap a token.
// 3. One tap from the swap form's token button.
//
// Lists the wallet's own tokens first, then every token that has a live
// Uniswap pool with the token on the other side (for WBEAM: KAS, wXTM,
// WZANO, HOPR, LINK, UNI…), found from Uniswap's own records through the
// wallet's node. Any token can be pasted by address. A token Campfire does
// not vouch for carries its address and a warning; a copy of a known
// ticker says "Not the real …".

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/ethereum/uniswap/abi.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_quoter.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';
import 'uniswap_deps.dart';
import 'uniswap_format.dart';
import 'uniswap_widgets.dart';

Future<UniToken?> showUniTokenPicker(
  BuildContext context, {
  required UniswapDeps deps,
  required String title,
  required UniToken selected,
  required UniToken other,
}) => showDexPage<UniToken>(
  context,
  deps,
  (_) => UniTokenPicker(
    deps: deps,
    title: title,
    selected: selected,
    other: other,
  ),
);

class UniTokenPicker extends StatefulWidget {
  const UniTokenPicker({
    super.key,
    required this.deps,
    required this.title,
    required this.selected,
    required this.other,
  });

  final UniswapDeps deps;
  final String title;
  final UniToken selected;

  /// The token on the other side of the swap: the picker lists what trades
  /// with it.
  final UniToken other;

  @override
  State<UniTokenPicker> createState() => _UniTokenPickerState();
}

class _UniTokenPickerState extends State<UniTokenPicker> {
  final _search = TextEditingController();
  List<UniToken>? _partners;
  bool _loadingPartners = false;
  UniToken? _pasted;
  bool _lookingUp = false;
  String? _lookupError;

  UniswapDeps get deps => widget.deps;

  /// Tokens with so many pools that "everything that trades with it" is
  /// most of Ethereum; their partners are not listed.
  bool get _otherIsBase =>
      widget.other.poolCurrencies.any(kUniRouteBases.contains) &&
      widget.other.address != kWbeamToken.address;

  @override
  void initState() {
    super.initState();
    unawaited(deps.refreshBalances(deps.myTokens));
    if (!_otherIsBase) unawaited(_loadPartners());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadPartners() async {
    setState(() => _loadingPartners = true);
    try {
      final addresses = await deps.service.partnersOf(widget.other);
      final known = <UniToken>[];
      final unknown = <String>[];
      for (final a in addresses) {
        final t = a == UniToken.eth.address ? UniToken.eth : deps.token(a);
        if (t != null) {
          known.add(t);
        } else {
          unknown.add(a);
        }
      }
      final infos = unknown.isEmpty
          ? <UniToken>[]
          : await deps.service.tokenInfo(unknown);
      for (final t in infos) {
        deps.remember(t);
      }
      final all = [...known, ...infos]
        ..sort(
          (a, b) => a.symbol.toLowerCase().compareTo(b.symbol.toLowerCase()),
        );
      if (mounted) setState(() => _partners = all);
    } catch (_) {
      if (mounted) setState(() => _partners = const []);
    } finally {
      if (mounted) setState(() => _loadingPartners = false);
    }
  }

  Future<void> _onSearch(String text) async {
    setState(() {
      _pasted = null;
      _lookupError = null;
    });
    final t = text.trim();
    if (!RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(t)) return;
    final address = normAddress(t);
    final known = deps.token(address);
    if (known != null) {
      setState(() => _pasted = known);
      return;
    }
    setState(() => _lookingUp = true);
    try {
      final r = await deps.service.tokenInfo([address]);
      if (!mounted) return;
      setState(() {
        if (r.isEmpty) {
          _lookupError = 'No token answers at that address on Ethereum.';
        } else {
          deps.remember(r.first);
          _pasted = r.first;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _lookupError =
              "Couldn't ask your Ethereum node about it. Try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  bool _matches(UniToken t) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty || q.startsWith('0x')) return true;
    return t.symbol.toLowerCase().contains(q) ||
        (t.name?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final mine = deps.myTokens.where(_matches).toList();
    final mineSet = mine.map((t) => t.address).toSet();
    final partners = (_partners ?? const <UniToken>[])
        .where((t) => !mineSet.contains(t.address) && _matches(t))
        .toList();
    final heading = STextStyles.itemSubtitle(context)
        .copyWith(color: colors.textDark3);
    return DexPage(
      deps: deps,
      title: widget.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('uni-token-search'),
            controller: _search,
            onChanged: _onSearch,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: 'Name, ticker or paste a token address',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              filled: true,
              fillColor: colors.textFieldDefaultBG,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          if (_lookingUp) ...[
            const SizedBox(height: 12),
            Text('Looking it up…', style: STextStyles.label(context)),
          ],
          if (_lookupError != null) ...[
            const SizedBox(height: 12),
            DexNotice(
              key: const Key('uni-token-lookup-error'),
              kind: DexNoticeKind.warning,
              title: _lookupError!,
            ),
          ],
          if (_pasted != null) ...[
            const SizedBox(height: 12),
            _row(context, _pasted!),
          ],
          const SizedBox(height: 12),
          Text('Your tokens', style: heading),
          for (final t in mine) _row(context, t),
          if (!_otherIsBase) ...[
            const SizedBox(height: 16),
            Text(
              'Trades with ${widget.other.symbol} on Uniswap',
              style: heading,
            ),
            if (_loadingPartners)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Looking at every Uniswap pool with ${widget.other.symbol}…',
                  key: const Key('uni-partners-loading'),
                  style: STextStyles.label(context),
                ),
              )
            else if (partners.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Nothing else trades with ${widget.other.symbol} right now.',
                  style: STextStyles.label(context),
                ),
              )
            else
              for (final t in partners) _row(context, t),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, UniToken t) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final selected = t.address == widget.selected.address;
    final verified = deps.isVerified(t);
    return InkWell(
      key: Key('uni-token-${t.address}'),
      onTap: () {
        deps.remember(t);
        Navigator.of(context).pop(t);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            UniTokenIcon(token: t, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.symbol,
                          overflow: TextOverflow.ellipsis,
                          style: STextStyles.titleBold12(context),
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: colors.accentColorGreen,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    verified
                        ? (t.name ?? t.symbol)
                        : '${deps.impersonates(t) != null ? 'Not the real ${deps.impersonates(t)!.symbol} · ' : 'Not on Campfire\'s list · '}'
                              '${UniFormat.short(t.address)}',
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.label(context).copyWith(
                      fontFeatures: kAddressFontFeatures,
                      color: verified
                          ? colors.textSubtitle1
                          : colors.accentColorRed,
                    ),
                  ),
                ],
              ),
            ),
            if (deps.hasBalance(t) && deps.balance(t) > BigInt.zero)
              Text(
                UniFormat.compact(deps.balance(t), t.decimals),
                style: STextStyles.itemSubtitle12(context),
              ),
          ],
        ),
      ),
    );
  }
}
