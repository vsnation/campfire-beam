/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  see which codes were claimed, and take back what nobody claimed.
//   CTA:  "Create new codes" (each batch has its own "Show codes" and
//         "Take back <n> unclaimed" actions).
//   Taps: open wallet → Airdrop → My batches (2–3).
//
// Exit-intent: "where did my money go?" → every batch says how many
// codes were claimed and how many still wait; "can I get it back?" → the
// take-back action is on the batch, with its exact fee shown before
// confirming; "is the list stale?" → it shows the saved list at once and
// says while it checks the network.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_batch_status.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_dialog.dart';
import 'beam_airdrop_codes_view.dart';
import 'beam_airdrop_confirm_view.dart';
import 'beam_create_airdrop_view.dart';

/// This wallet's airdrop batches: the ones whose codes are saved here and
/// the ones the contract lists for this wallet, matched by code hash.
/// Never removes a batch on its own.
class BeamAirdropBatchesView extends StatefulWidget {
  const BeamAirdropBatchesView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.onCreateBatch,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
    this.clock = DateTime.now,
  });

  static const routeName = '/beamAirdropBatches';
  static const title = 'My airdrop batches';

  final BeamAirdropService service;
  final ValueListenable<BeamSyncAssessment> sync;
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;

  /// Opens the create form; when null this screen pushes
  /// [BeamCreateAirdropView] itself.
  final VoidCallback? onCreateBatch;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;
  final DateTime Function() clock;

  @override
  State<BeamAirdropBatchesView> createState() => _BeamAirdropBatchesViewState();
}

class _Row {
  const _Row({this.saved, this.chain});

  final AirdropSavedBatch? saved;
  final AirdropBatch? chain;
}

class _BeamAirdropBatchesViewState extends State<BeamAirdropBatchesView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);

  List<AirdropSavedBatch>? _saved;
  List<AirdropBatch> _chain = const [];
  final _chainHashes = <BigInt, Set<String>>{};
  bool _refreshing = false;
  bool _checkedNetwork = false;
  bool _preparing = false;
  BeamProblem? _problem;
  BeamProblem? _done;

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

  /// The saved list first (instant, from this device), then the network.
  Future<void> _load() async {
    try {
      final saved = await widget.service.savedBatches();
      if (!mounted) return;
      setState(() => _saved = saved);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saved = const []);
    }
    await _refresh();
  }

  static bool _needsCheck(AirdropSavedBatch b) =>
      b.txStatus == AirdropBatchTxStatus.unconfirmed ||
      b.txStatus == AirdropBatchTxStatus.broadcast ||
      b.codes.any(
        (c) =>
            c.status == AirdropCodeStatus.available ||
            c.status == AirdropCodeStatus.unknown,
      );

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _problem = null;
    });
    try {
      final chain = await widget.service.myBatches();
      final hashes = <BigInt, Set<String>>{};
      for (final c in chain) {
        hashes[c.id] = {
          for (final v in await widget.service.batchVouchers(c.id)) v.hashHex,
        };
      }
      for (final s in _saved ?? const <AirdropSavedBatch>[]) {
        if (_needsCheck(s)) await widget.service.refreshSavedBatch(s);
      }
      final saved = await widget.service.savedBatches();
      if (!mounted) return;
      setState(() {
        _chain = chain;
        _chainHashes
          ..clear()
          ..addAll(hashes);
        _saved = saved;
        _checkedNetwork = true;
      });
      unawaited(
        _names.preload({
          for (final c in chain) c.assetId,
          for (final s in saved) s.assetId,
        }),
      );
    } catch (e) {
      if (!mounted) return;
      final t = airdropProblem(e);
      setState(
        () => _problem = BeamProblem(
          t.title,
          '${t.message} Your saved codes are safe on this device.',
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  List<_Row> get _rows {
    final saved = _saved ?? const <AirdropSavedBatch>[];
    final used = <String>{};
    final rows = <_Row>[];
    for (final c in _chain) {
      final hashes = _chainHashes[c.id] ?? const <String>{};
      final match = saved.where(
        (s) =>
            !used.contains(s.localId) &&
            s.codes.any((code) => hashes.contains(code.hashHex)),
      );
      final s = match.isEmpty ? null : match.first;
      if (s != null) used.add(s.localId);
      rows.add(_Row(chain: c, saved: s));
    }
    for (final s in saved) {
      if (!used.contains(s.localId)) rows.add(_Row(saved: s));
    }
    rows.sort((a, b) {
      final ta = a.saved?.createdAt;
      final tb = b.saved?.createdAt;
      if (ta != null && tb != null) return tb.compareTo(ta);
      if (ta != null) return -1;
      if (tb != null) return 1;
      return b.chain!.createdAtHeight.compareTo(a.chain!.createdAtHeight);
    });
    return rows;
  }

  void _openCreate() {
    final open = widget.onCreateBatch;
    if (open != null) {
      open();
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BeamCreateAirdropView(
            service: widget.service,
            sync: widget.sync,
            assetNames: _names,
            authorize: widget.authorize,
            clipboard: widget.clipboard,
            exporter: widget.exporter,
          ),
        ),
      ),
    );
  }

  Future<void> _showCodes(AirdropSavedBatch s) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BeamAirdropCodesView(
          service: widget.service,
          localId: s.localId,
          assetNames: _names,
          clipboard: widget.clipboard,
          exporter: widget.exporter,
        ),
      ),
    );
  }

  Future<void> _cancel(AirdropBatch c) async {
    if (_preparing) return;
    setState(() {
      _preparing = true;
      _problem = null;
      _done = null;
    });
    BeamPreparedAirdropCall? p;
    try {
      p = await widget.service.prepareCancelBatch(c.id);
    } catch (e) {
      if (mounted) setState(() => _problem = airdropProblem(e));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (p == null) return;
    if (!mounted) {
      widget.service.discard(p);
      return;
    }
    final sent = await Navigator.of(context).push<BeamAirdropSent>(
      MaterialPageRoute(
        builder: (_) => BeamAirdropConfirmView(
          service: widget.service,
          prepared: p!,
          sync: widget.sync,
          assetNames: _names,
          authorize: widget.authorize,
        ),
      ),
    );
    if (sent?.txId == null || !mounted) return;
    final back = p.summary.receives[p.summary.assetId]!;
    setState(
      () => _done = BeamProblem(
        'Cancel sent',
        'The unclaimed codes stop working and '
            '${_names.amount(p!.summary.assetId, back)} comes back once the '
            'network confirms it, usually within a few minutes.',
      ),
    );
    unawaited(_refresh());
  }

  Future<void> _forget(AirdropSavedBatch s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: 'Remove this batch from the list?',
        message:
            'Every code is claimed or cancelled, so none of them holds funds '
            'any more. This removes them from this device only.',
        leftButton: SecondaryButton(
          label: 'Keep',
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          label: 'Remove',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.service.forgetSavedBatch(s.localId);
      final saved = await widget.service.savedBatches();
      if (mounted) setState(() => _saved = saved);
    } catch (e) {
      if (mounted) setState(() => _problem = airdropProblem(e));
    }
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      final rows = _rows;
      final loaded = _saved != null;
      final empty = loaded && rows.isEmpty && !_refreshing && _problem == null;
      return BeamPageScaffold(
        title: BeamAirdropBatchesView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_refreshing)
              const BeamWorking('Checking your codes on the network…')
            else if (_checkedNetwork && rows.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Up to date with the network',
                      style: STextStyles.label(context),
                    ),
                  ),
                  CustomTextButton(text: 'Check again', onTap: _refresh),
                ],
              ),
            if (_done != null) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-done'),
                kind: BeamNoticeKind.success,
                title: _done!.title,
                message: _done!.message,
              ),
            ],
            if (_problem != null) ...[
              const BeamGap(8),
              BeamNotice(
                key: const ValueKey('batches-problem'),
                kind: BeamNoticeKind.danger,
                title: _problem!.title,
                message: _problem!.message,
                actionLabel: 'Try again',
                onAction: _refresh,
              ),
            ],
            if (_preparing) const BeamWorking('Preparing the cancel…'),
            if (empty)
              const BeamEmptyState(
                key: ValueKey('batches-empty'),
                art: BeamStickerImage(BeamSticker.hi, size: 120),
                title: 'No airdrop codes yet',
                message:
                    'Create codes to give tokens to people. Each code can be '
                    'claimed once, by whoever has it.',
              ),
            const BeamGap(8),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _card(context, r, sync.canSpend),
              ),
          ],
        ),
        bottom: BeamCtaBar(
          primaryKey: const ValueKey('batches-create'),
          label: empty ? 'Create airdrop codes' : 'Create new codes',
          onPressed: _openCreate,
        ),
      );
    },
  );

  Widget _card(BuildContext context, _Row r, bool canSpend) {
    final s = r.saved;
    final c = r.chain;
    final assetId = s?.assetId ?? c!.assetId;
    final count = s?.count ?? c!.totalCount;
    final value = s?.codes.first.value ?? c!.valuePerVoucher;
    final status = airdropBatchStatus(s, c);
    final colors = Theme.of(context).extension<StackColors>()!;
    final unclaimed = c?.unclaimedCount ?? 0;
    final settled =
        s != null && c == null && airdropBatchLooksSettled(s, widget.clock());
    final created = s == null
        ? 'Created at block ${c!.createdAtHeight}'
        : 'Created ${_date(s.createdAt.toLocal())}';
    return RoundedWhiteContainer(
      key: ValueKey('batch-${s?.localId ?? c!.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BeamAssetTitle(
            display: _names.display(assetId),
            subtitle: '$count codes × ${_names.amount(assetId, value)}',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              BeamPill(text: status.text, kind: status.kind),
              Text(created, style: STextStyles.label(context)),
            ],
          ),
          if (s == null) ...[
            const SizedBox(height: 4),
            Text(
              'Its codes are not on this device, but you can still take '
              'back what nobody claimed.',
              style: STextStyles.label(context),
            ),
          ],
          if (s != null || unclaimed > 0 || settled) ...[
            const SizedBox(height: 4),
            Divider(color: colors.background, height: 12),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                if (s != null)
                  CustomTextButton(
                    key: ValueKey('batch-codes-${s.localId}'),
                    text: 'Show codes',
                    onTap: () => _showCodes(s),
                  ),
                if (unclaimed > 0)
                  CustomTextButton(
                    key: ValueKey('batch-cancel-${c!.id}'),
                    text: 'Take back $unclaimed unclaimed',
                    enabled: canSpend && !_preparing,
                    onTap: () => _cancel(c),
                  ),
                if (settled)
                  CustomTextButton(
                    key: ValueKey('batch-forget-${s.localId}'),
                    text: 'Remove from this list',
                    onTap: () => _forget(s),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _date(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
