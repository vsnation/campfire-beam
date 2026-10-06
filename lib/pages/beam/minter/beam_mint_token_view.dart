/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  create a new token of your own on BEAM.
//   CTA:  "Create <TICKER>" (the confirmation then says "Create <TICKER>
//         for <total>").
//   Taps: open wallet → Tokens → Create a token → name, ticker, supply →
//         Create (→ confirm → PIN): 3 + typing + confirm + PIN.
//
// Exit-intent (§1.7): "how much is this going to cost me?" → the cost is
// the first thing on the screen, split into what goes where, before any
// field; "what do these fields mean?" → three fields matter, the rest are
// optional or under "More details"; "I typed something wrong" → each field
// says what to fix, in plain words, as you type.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/minter/minter_text.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import 'beam_minter_confirm_view.dart';
import 'beam_my_tokens_view.dart';

/// Create a Confidential Asset with BEAM's Minter.
class BeamMintTokenView extends StatefulWidget {
  const BeamMintTokenView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.onOpenMyTokens,
  });

  static const routeName = '/beamMintToken';
  static const title = 'Create a token';

  final BeamMinterService service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// After creating, "Go to My tokens" calls this; when null this screen
  /// replaces itself with [BeamMyTokensView].
  final VoidCallback? onOpenMyTokens;

  @override
  State<BeamMintTokenView> createState() => _BeamMintTokenViewState();
}

class _UpperCase extends TextInputFormatter {
  const _UpperCase();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue v) =>
      v.copyWith(text: v.text.toUpperCase());
}

class _BeamMintTokenViewState extends State<BeamMintTokenView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);

  final _name = TextEditingController();
  final _ticker = TextEditingController();
  final _supply = TextEditingController();
  final _shortDesc = TextEditingController();
  final _color = TextEditingController();
  final _site = TextEditingController();
  final _unit = TextEditingController();
  final _nth = TextEditingController(text: 'groth');
  final _longDesc = TextEditingController();
  final _touched = <TokenMetadataField>{};
  bool _supplyTouched = false;
  bool _unitEdited = false;
  bool _more = false;

  MinterParams? _params;
  BigInt? _beam;
  BeamProblem? _loadProblem;
  BeamProblem? _problem;
  bool _preparing = false;
  String? _createdTicker;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _ticker,
      _supply,
      _shortDesc,
      _color,
      _site,
      _unit,
      _nth,
      _longDesc,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadProblem = null);
    try {
      final p = await widget.service.params();
      final b = await beamAvailableBalances(widget.service.api);
      if (!mounted) return;
      setState(() {
        _params = p;
        _beam = b[0];
      });
    } catch (e) {
      if (mounted) setState(() => _loadProblem = minterProblem(e));
    }
  }

  static String? _opt(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  String get _unitName => _unitEdited ? _unit.text : _ticker.text;

  /// The core's own rules ([BeamTokenMetadata]) for one field: the other
  /// fields get harmless placeholders so only [field] can fail.
  String? _check(TokenMetadataField field) {
    try {
      BeamTokenMetadata(
        name: field == TokenMetadataField.name ? _name.text : 'A',
        shortName: field == TokenMetadataField.shortName ? _ticker.text : 'A',
        unitName: field == TokenMetadataField.unitName ? _unitName : 'A',
        nthUnitName: field == TokenMetadataField.nthUnitName
            ? _nth.text
            : 'groth',
        shortDescription: field == TokenMetadataField.shortDescription
            ? _opt(_shortDesc)
            : null,
        longDescription: field == TokenMetadataField.longDescription
            ? _opt(_longDesc)
            : null,
        color: field == TokenMetadataField.color ? _opt(_color) : null,
        siteUrl: field == TokenMetadataField.siteUrl ? _opt(_site) : null,
      );
      return null;
    } on TokenMetadataException catch (e) {
      if (e.field != field) return null;
      return field == TokenMetadataField.shortName
          ? e.message.replaceFirst('Short name', 'Ticker')
          : e.message;
    }
  }

  /// Shown once the user has typed in the field (an untouched empty field
  /// is not an error yet).
  String? _error(TokenMetadataField field) =>
      _touched.contains(field) ? _check(field) : null;

  BigInt? get _wholeSupply {
    final t = _supply.text.replaceAll(RegExp(r'[\s,_]'), '');
    final v = BigInt.tryParse(t);
    if (v == null || v <= BigInt.zero) return null;
    if ((v * BeamTokenMetadata.nthRatio).bitLength > 128) return null;
    return v;
  }

  String? get _supplyProblem {
    if (!_supplyTouched || _supply.text.trim().isEmpty) return null;
    return _wholeSupply == null
        ? 'Enter a whole number above zero, like 1000000'
        : null;
  }

  BeamTokenMetadata? get _metadata {
    try {
      return BeamTokenMetadata(
        name: _name.text,
        shortName: _ticker.text,
        unitName: _unitName,
        nthUnitName: _nth.text,
        shortDescription: _opt(_shortDesc),
        longDescription: _opt(_longDesc),
        color: _opt(_color),
        siteUrl: _opt(_site),
      );
    } on TokenMetadataException {
      return null;
    }
  }

  BigInt? get _cost {
    final p = _params;
    return p == null ? null : p.issueFee + kMinterAssetDeposit;
  }

  bool get _tooPoor => _cost != null && _beam != null && _beam! < _cost!;

  Future<void> _create() async {
    if (_preparing) return;
    final m = _metadata;
    final whole = _wholeSupply;
    if (m == null || whole == null) return;
    setState(() {
      _preparing = true;
      _problem = null;
    });
    BeamPreparedMinterCall? p;
    try {
      p = await widget.service.prepareCreateToken(
        metadata: m,
        limit: m.supplyOf(whole),
      );
    } catch (e) {
      if (mounted) setState(() => _problem = minterProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (p == null) return;
    if (!mounted) {
      widget.service.discard(p);
      return;
    }
    final tx = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => BeamMinterConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (tx != null && mounted) setState(() => _createdTicker = m.shortName);
  }

  void _openMyTokens() {
    final open = widget.onOpenMyTokens;
    if (open != null) {
      open();
      return;
    }
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => BeamMyTokensView(
            service: widget.service,
            sync: widget.sync,
            assetNames: _names,
            authorize: widget.authorize,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_createdTicker != null) return _done(context);
    return BeamSyncGate(
      sync: widget.sync,
      builder: (context, sync) {
        final m = _metadata;
        final ready =
            m != null && _wholeSupply != null && _params != null && !_tooPoor;
        final ticker = _ticker.text.trim();
        return BeamPageScaffold(
          title: BeamMintTokenView.title,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _costCard(context),
              const BeamGap(16),
              ..._fields(context),
              if (_problem != null) ...[
                const BeamGap(),
                BeamNotice(
                  key: const ValueKey('mint-problem'),
                  kind: BeamNoticeKind.danger,
                  title: _problem!.title,
                  message: _problem!.message,
                ),
              ],
            ],
          ),
          bottom: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BeamSyncNotice(sync: sync, what: 'Creating a token'),
              BeamCtaBar(
                primaryKey: const ValueKey('mint-cta'),
                label: ticker.isEmpty || m == null
                    ? 'Create my token'
                    : 'Create $ticker',
                busy: _preparing,
                busyLabel: 'Preparing…',
                onPressed: ready && sync.canSpend ? _create : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _costCard(BuildContext context) {
    String beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');
    final p = _params;
    final cost = _cost;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loadProblem != null) ...[
          BeamNotice(
            kind: BeamNoticeKind.danger,
            title: _loadProblem!.title,
            message: _loadProblem!.message,
            actionLabel: 'Try again',
            onAction: _load,
          ),
          const BeamGap(),
        ],
        BeamDetailCard(
          key: const ValueKey('mint-cost'),
          children: [
            BeamDetailRow(
              label: 'To the BEAM DAO',
              value: p == null ? 'Reading…' : beam(p.issueFee),
              detail: 'Issuance fee',
            ),
            BeamDetailRow(
              label: 'Asset deposit',
              value: beam(kMinterAssetDeposit),
              detail: 'Never returned',
            ),
            const BeamDetailRow(
              label: 'Network fee',
              value: 'Shown before you confirm',
            ),
          ],
        ),
        const BeamGap(8),
        BeamTotalRow(
          label: 'Creating a token costs',
          value: cost == null ? '…' : '${beam(cost)} + network fee',
          valueKey: const ValueKey('mint-cost-total'),
          confirm: false,
        ),
        if (_tooPoor) ...[
          const BeamGap(),
          BeamNotice(
            key: const ValueKey('mint-too-poor'),
            kind: BeamNoticeKind.danger,
            title: 'Not enough BEAM',
            message:
                'Creating a token needs ${beam(cost!)} plus a network fee, '
                'and this wallet has ${beam(_beam!)}. Add BEAM to this '
                'wallet first.',
          ),
        ],
      ],
    );
  }

  List<Widget> _fields(BuildContext context) {
    void touch(TokenMetadataField f) => setState(() => _touched.add(f));
    final copied = _copiesVerified();
    return [
      BeamTextField(
        fieldKey: const ValueKey('mint-name'),
        controller: _name,
        label: 'Token name',
        hint: 'My Token',
        error: _error(TokenMetadataField.name),
        onChanged: (_) => touch(TokenMetadataField.name),
      ),
      const BeamGap(),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: BeamTextField(
              fieldKey: const ValueKey('mint-ticker'),
              controller: _ticker,
              label: 'Ticker',
              hint: 'MYT',
              helper:
                  'Up to ${BeamTokenMetadata.maxShortNameLength} '
                  'characters',
              error:
                  _error(TokenMetadataField.shortName) ??
                  (_unitEdited ? null : _error(TokenMetadataField.unitName)),
              inputFormatters: const [_UpperCase()],
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) {
                touch(TokenMetadataField.shortName);
                if (!_unitEdited) _touched.add(TokenMetadataField.unitName);
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BeamTextField(
              fieldKey: const ValueKey('mint-supply'),
              controller: _supply,
              label: 'Maximum supply',
              hint: '1000000',
              helper: 'Whole tokens, ever',
              error: _supplyProblem,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() => _supplyTouched = true),
            ),
          ),
        ],
      ),
      if (copied != null) ...[
        const BeamGap(8),
        BeamNotice(
          key: const ValueKey('mint-copies-verified'),
          kind: BeamNoticeKind.warning,
          message:
              'Wallets will mark your token "Not the verified '
              '${copied.symbol}", because ${copied.name} already exists. '
              'Pick a name and ticker of your own.',
        ),
      ],
      const BeamGap(),
      BeamTextField(
        fieldKey: const ValueKey('mint-short-desc'),
        controller: _shortDesc,
        label: 'Short description (optional)',
        hint: 'What the token is for',
        error: _error(TokenMetadataField.shortDescription),
        onChanged: (_) => touch(TokenMetadataField.shortDescription),
      ),
      const BeamGap(),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: BeamTextField(
              fieldKey: const ValueKey('mint-color'),
              controller: _color,
              label: 'Colour (optional)',
              hint: '#25C2A0',
              error: _error(TokenMetadataField.color),
              suffix: _swatch(),
              onChanged: (_) => touch(TokenMetadataField.color),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: BeamTextField(
              fieldKey: const ValueKey('mint-site'),
              controller: _site,
              label: 'Website (optional)',
              hint: 'https://',
              keyboardType: TextInputType.url,
              error: _error(TokenMetadataField.siteUrl),
              onChanged: (_) => touch(TokenMetadataField.siteUrl),
            ),
          ),
        ],
      ),
      const BeamGap(8),
      Align(
        alignment: Alignment.centerLeft,
        child: CustomTextButton(
          key: const ValueKey('mint-more'),
          text: _more ? 'Fewer details' : 'More details',
          onTap: () => setState(() => _more = !_more),
        ),
      ),
      if (_more) ...[
        const BeamGap(8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: BeamTextField(
                fieldKey: const ValueKey('mint-unit'),
                controller: _unit,
                label: 'Unit name',
                hint: _ticker.text.isEmpty ? 'MYT' : _ticker.text,
                helper: 'Same as the ticker unless you change it',
                error: _unitEdited ? _error(TokenMetadataField.unitName) : null,
                onChanged: (_) => setState(() {
                  _unitEdited = _unit.text.isNotEmpty;
                  _touched.add(TokenMetadataField.unitName);
                }),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: BeamTextField(
                fieldKey: const ValueKey('mint-nth'),
                controller: _nth,
                label: 'Smallest unit name',
                helper: '1 token = 100,000,000 of these',
                error: _error(TokenMetadataField.nthUnitName),
                onChanged: (_) => touch(TokenMetadataField.nthUnitName),
              ),
            ),
          ],
        ),
        const BeamGap(),
        BeamTextField(
          fieldKey: const ValueKey('mint-long-desc'),
          controller: _longDesc,
          label: 'Long description (optional)',
          maxLines: 4,
          error: _error(TokenMetadataField.longDescription),
          onChanged: (_) => touch(TokenMetadataField.longDescription),
        ),
      ],
    ];
  }

  Widget? _swatch() {
    final c = _opt(_color);
    if (c == null || _check(TokenMetadataField.color) != null) return null;
    var h = c.substring(1);
    if (h.length == 3) h = h.split('').map((x) => '$x$x').join();
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: Color(0xFF000000 | int.parse(h, radix: 16)),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }

  /// The verified asset this name or ticker copies, if any.
  BeamKnownAsset? _copiesVerified() {
    final name = _name.text.trim();
    final ticker = _ticker.text.trim();
    if (name.isEmpty && ticker.isEmpty) return null;
    final d = BeamAssetCatalog.display(
      0x7fffffff,
      BeamAssetMetadata.parse('STD:N=$name;SN=$ticker;UN=$ticker'),
    );
    final id = d.impersonates;
    return id == null ? null : BeamAssetCatalog.verified[id];
  }

  Widget _done(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    return BeamPageScaffold(
      title: BeamMintTokenView.title,
      body: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          children: [
            const BeamStickerImage(BeamSticker.success, size: 128),
            const BeamGap(16),
            Text(
              '$_createdTicker is being created',
              key: const ValueKey('mint-done'),
              textAlign: TextAlign.center,
              style: desktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            const BeamGap(8),
            Text(
              'It appears in My tokens once the network confirms it, usually '
              'within a few minutes. Mint your first tokens there.',
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
          ],
        ),
      ),
      bottom: BeamCtaBar(label: 'Go to My tokens', onPressed: _openMyTokens),
    );
  }
}
