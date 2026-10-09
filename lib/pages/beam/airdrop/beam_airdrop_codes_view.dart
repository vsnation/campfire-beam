/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
//   Job:  hand out a batch's codes, and keep a copy of them.
//   CTA:  "Copy all codes".
//   Taps: right after creating a batch (0 taps), or My batches → Show
//         codes (2 from the airdrop menu).
//
// Exit-intent: "where are my codes / are they safe?" → they are on
// screen at once, with a plain warning that they are the only key to the
// funds and are not in the wallet backup; "how do I send them?" → copy one,
// copy all, share, or export a file; "did the batch work?" → the status
// line says whether the network has it yet.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../widgets/beam/airdrop/airdrop_batch_status.dart';
import '../../../widgets/beam/airdrop/airdrop_codes_export.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/airdrop/voucher_code_input.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/icon_widgets/copy_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/textfield_icon_button.dart';

/// The codes of one saved batch, read from the wallet's code store.
class BeamAirdropCodesView extends StatefulWidget {
  const BeamAirdropCodesView({
    super.key,
    required this.service,
    required this.localId,
    this.assetNames,
    this.justCreated = false,
    this.notice,
    this.clipboard = const ClipboardWrapper(),
    this.exporter = const CampfireAirdropCodesExporter(),
  });

  static const routeName = '/beamAirdropCodes';

  final BeamAirdropService service;

  /// [AirdropSavedBatch.localId] of the batch to show.
  final String localId;
  final BeamAssetNames? assetNames;

  /// Opened right after the batch was sent.
  final bool justCreated;

  /// Shown above the codes, e.g. when sending could not be confirmed.
  final BeamProblem? notice;
  final ClipboardInterface clipboard;
  final AirdropCodesExporter exporter;

  @override
  State<BeamAirdropCodesView> createState() => _BeamAirdropCodesViewState();
}

class _BeamAirdropCodesViewState extends State<BeamAirdropCodesView> {
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);
  AirdropSavedBatch? _batch;
  BeamProblem? _problem;
  bool _loading = true;

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
    try {
      final all = await widget.service.savedBatches();
      final found = all.where((b) => b.localId == widget.localId);
      if (!mounted) return;
      setState(() {
        _batch = found.isEmpty ? null : found.single;
        _loading = false;
        if (found.isEmpty) {
          _problem = const BeamProblem(
            "These codes aren't on this device",
            'They may have been saved by another device or app. Open My '
                'batches to see what this wallet has.',
          );
        }
      });
      if (found.isNotEmpty) unawaited(_names.preload([found.single.assetId]));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _problem = const BeamProblem(
          "Couldn't open the saved codes",
          'The secure storage on this device did not answer. Close this '
              'screen and open it again; the codes are not lost.',
        );
      });
    }
  }

  Future<void> _copy(String text, String what) async {
    await widget.clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.info,
        message: '$what copied',
        context: context,
      ),
    );
  }

  String get _allCodes => _batch!.codes.map((c) => c.code).join('\n');

  Future<void> _export() async {
    final b = _batch!;
    final csv = AirdropCsv.export(
      b,
      formatValue: BeamUnits.format,
      assetLabel: _names.symbol(b.assetId),
    );
    final day = b.createdAt.toIso8601String().substring(0, 10);
    try {
      final where = await widget.exporter.saveCsv(
        context,
        fileName: 'airdrop-codes-$day-${b.count}.csv',
        csv: csv,
      );
      if (where == null || !mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.success,
          message: 'Codes exported',
          context: context,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: "Couldn't export the file. Try Copy all codes instead.",
          context: context,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _batch;
    return BeamPageScaffold(
      title: widget.justCreated ? 'Your airdrop codes' : 'Airdrop codes',
      body: _loading
          ? const BeamWorking('Opening your saved codes…')
          : b == null
          ? BeamNotice(
              kind: BeamNoticeKind.danger,
              title: _problem!.title,
              message: _problem!.message,
            )
          : _codes(context, b),
      bottom: b == null
          ? BeamCtaBar(
              label: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : BeamCtaBar(
              primaryKey: const ValueKey('codes-copy-all'),
              label: 'Copy all codes',
              onPressed: () => _copy(_allCodes, 'All ${b.count} codes'),
            ),
    );
  }

  Widget _codes(BuildContext context, AirdropSavedBatch b) {
    final same = b.codes.every((c) => c.value == b.codes.first.value);
    final status = airdropBatchStatus(b, null);
    final desktop = BeamLayoutScope.isDesktop(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.justCreated && widget.notice == null) ...[
          const Row(
            children: [
              BeamAnimatedStickerView(BeamMoments.walletCreated, size: 72),
              SizedBox(width: 8),
              Expanded(
                child: BeamNotice(
                  key: ValueKey('codes-sent'),
                  kind: BeamNoticeKind.success,
                  title: 'Batch sent',
                  message:
                      'The codes start working once the network confirms it, '
                      'usually within a few minutes.',
                ),
              ),
            ],
          ),
          const BeamGap(),
        ],
        if (widget.notice != null) ...[
          BeamNotice(
            key: const ValueKey('codes-notice'),
            kind: BeamNoticeKind.warning,
            title: widget.notice!.title,
            message: widget.notice!.message,
          ),
          const BeamGap(),
        ],
        RoundedWhiteContainer(
          child: BeamAssetTitle(
            display: _names.display(b.assetId),
            subtitle: same
                ? '${b.count} codes · '
                      '${_names.amount(b.assetId, b.codes.first.value)} each'
                : '${b.count} codes · '
                      '${_names.amount(b.assetId, b.total)} in total',
            trailing: widget.justCreated
                ? null
                : BeamPill(text: status.text, kind: status.kind),
          ),
        ),
        const BeamGap(),
        const BeamNotice(
          key: ValueKey('codes-key-warning'),
          kind: BeamNoticeKind.warning,
          title: 'These codes are the only key to the locked funds',
          message:
              'Anyone who has a code can claim it, so send each one only to '
              'its recipient. They are saved on this device but not in your '
              'wallet backup: export a copy to keep them safe.',
        ),
        const BeamGap(8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            CustomTextButton(
              key: const ValueKey('codes-export'),
              text: 'Export file',
              onTap: _export,
            ),
            if (!desktop) ...[
              const SizedBox(width: 16),
              CustomTextButton(
                key: const ValueKey('codes-share'),
                text: 'Share',
                onTap: () => widget.exporter.shareText(context, _allCodes),
              ),
            ],
          ],
        ),
        const BeamGap(8),
        for (var i = 0; i < b.codes.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _codeRow(context, b, i),
          ),
      ],
    );
  }

  Widget _codeRow(BuildContext context, AirdropSavedBatch b, int i) {
    final c = b.codes[i];
    final st = airdropCodeStatus(c, b.txStatus);
    return RoundedWhiteContainer(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${i + 1}', style: STextStyles.label(context)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  c.code,
                  key: ValueKey('code-$i'),
                  style: voucherCodeStyle(context, size: 15),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _names.amount(b.assetId, c.value),
                        style: STextStyles.label(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!widget.justCreated) ...[
                      const SizedBox(width: 8),
                      BeamPill(text: st.text, kind: st.kind),
                    ],
                  ],
                ),
              ],
            ),
          ),
          TextFieldIconButton(
            key: ValueKey('code-copy-$i'),
            semanticsLabel: 'Copy code',
            onTap: () => _copy(c.code, 'Code'),
            child: const CopyIcon(),
          ),
        ],
      ),
    );
  }
}
