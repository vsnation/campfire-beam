/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  see the tokens this wallet created, and mint more of them.
//   CTA:  "Create a token" (each token has its own "Mint more").
//   Taps: open wallet → Tokens → My tokens (2–3); Mint more is 2 more +
//         confirm + PIN.
//
// Exit-intent: "where is my token?" → a token still waiting for the
// network is explained in the empty state; "how much can I still mint?" →
// minted and maximum are on each card with a bar.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/minter/minter.dart';
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
import '../../../widgets/progress_bar.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_mint_more_view.dart';
import 'beam_mint_token_view.dart';

/// The tokens this wallet created with the Minter.
class BeamMyTokensView extends StatefulWidget {
  const BeamMyTokensView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.onCreateToken,
  });

  static const routeName = '/beamMyTokens';
  static String get title => appL10n.minterMyTokensTitle;

  final BeamMinterService service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Opens the create form; when null this screen pushes
  /// [BeamMintTokenView] itself.
  final VoidCallback? onCreateToken;

  @override
  State<BeamMyTokensView> createState() => _BeamMyTokensViewState();
}

class _BeamMyTokensViewState extends State<BeamMyTokensView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  List<MinterToken>? _tokens;
  BeamProblem? _problem;
  BeamProblem? _done;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    unawaited(_load());
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _names.removeListener(_rebuild);
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      final t = await widget.service.ownedTokens();
      for (final x in t) {
        _names.remember(x.assetId, x.metadata);
      }
      if (mounted) setState(() => _tokens = t);
    } catch (e) {
      if (mounted) setState(() => _problem = minterProblem(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openCreate() {
    final open = widget.onCreateToken;
    if (open != null) {
      open();
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BeamMintTokenView(
            service: widget.service,
            sync: widget.sync,
            assetNames: _names,
            authorize: widget.authorize,
            onOpenMyTokens: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
    );
  }

  Future<void> _mintMore(MinterToken t) async {
    final minted = await Navigator.of(context).push<BigInt>(
      MaterialPageRoute(
        builder: (_) => BeamMintMoreView(
          service: widget.service,
          token: t,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (minted == null || !mounted) return;
    setState(
      () => _done = BeamProblem(
        context.l10n.minterMyTokensMintSentTitle,
        context.l10n.minterMyTokensMintSentMessage(
          _names.amount(t.assetId, minted),
        ),
      ),
    );
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final tokens = _tokens;
      final empty = tokens != null && tokens.isEmpty && _problem == null;
      final l10n = context.l10n;
      return BeamPageScaffold(
        title: BeamMyTokensView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loading && tokens == null)
              BeamWorking(l10n.minterMyTokensLoading),
            if (_done != null) ...[
              Row(
                children: [
                  const BeamStickerImage(BeamSticker.success, size: 64),
                  const SizedBox(width: 8),
                  Expanded(
                    child: BeamNotice(
                      key: const ValueKey('tokens-done'),
                      kind: BeamNoticeKind.success,
                      title: _done!.title,
                      message: _done!.message,
                    ),
                  ),
                ],
              ),
              const BeamGap(),
            ],
            if (_problem != null) ...[
              BeamNotice(
                key: const ValueKey('tokens-problem'),
                kind: BeamNoticeKind.danger,
                title: _problem!.title,
                message: _problem!.message,
                actionLabel: l10n.commonTryAgain,
                onAction: _load,
              ),
              const BeamGap(),
            ],
            if (empty)
              BeamEmptyState(
                key: const ValueKey('tokens-empty'),
                art: const BeamStickerImage(BeamSticker.hi, size: 120),
                title: l10n.minterMyTokensEmptyTitle,
                message: l10n.minterMyTokensEmptyMessage,
              ),
            for (final t in tokens ?? const <MinterToken>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _card(context, t, sync.canSpend),
              ),
          ],
        ),
        bottom: BeamCtaBar(
          primaryKey: const ValueKey('tokens-create'),
          label: l10n.minterMyTokensCreate,
          onPressed: _openCreate,
        ),
      );
    },
  );

  Widget _card(BuildContext context, MinterToken t, bool canSpend) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final share = t.limit == BigInt.zero
        ? 0.0
        : (t.minted * BigInt.from(1000) ~/ t.limit).toInt() / 1000;
    final l10n = context.l10n;
    return RoundedWhiteContainer(
      key: ValueKey('token-${t.assetId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BeamAssetTitle(display: _names.display(t.assetId)),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) => ProgressBar(
              width: c.maxWidth,
              height: 6,
              fillColor: colors.accentColorGreen,
              backgroundColor: colors.textFieldDefaultBG,
              percent: share.clamp(0, 1),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.minterMyTokensMinted(
                    BeamUnits.format(
                      t.minted,
                      places: _names.decimals(t.assetId),
                    ),
                    BeamUnits.format(
                      t.limit,
                      places: _names.decimals(t.assetId),
                    ),
                  ),
                  style: STextStyles.label(context),
                ),
              ),
              if (t.mintable > BigInt.zero)
                CustomTextButton(
                  key: ValueKey('token-mint-${t.assetId}'),
                  text: l10n.minterMyTokensMintMore,
                  enabled: canSpend,
                  onTap: () => _mintMore(t),
                )
              else
                Text(
                  l10n.minterMyTokensAllMinted,
                  style: STextStyles.label(context),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
