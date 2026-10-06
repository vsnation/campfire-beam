/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: show this wallet's name key so another wallet can transfer a
//    name to it.
// 2. Primary CTA: "Copy my name key".
// 3. Taps from app open: Names (1) → Receive a name (2) → Copy (3).
//
// Exit-intent (§1.7): "Is it safe to share?" — yes, and the one thing it
// reveals (which names this wallet owns) is said plainly.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import '../../../widgets/qr.dart';

/// This wallet's name key, to receive a name from another wallet.
class BeamNameKeyView extends StatefulWidget {
  const BeamNameKeyView({super.key, required this.deps});

  final BeamNamesDeps deps;

  static Future<void> show(BuildContext context, BeamNamesDeps deps) =>
      showNamesPage<void>(context, deps, (_) => BeamNameKeyView(deps: deps));

  @override
  State<BeamNameKeyView> createState() => _BeamNameKeyViewState();
}

class _BeamNameKeyViewState extends State<BeamNameKeyView> {
  String? _key;
  Object? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final k = await widget.deps.bans.myKey();
      if (mounted) setState(() => _key = k);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _key!));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final key = _key;
    return NamesPage(
      deps: widget.deps,
      title: 'Receive a name',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'To move a name into this wallet, give its current owner this '
            'key. They paste it under Transfer.',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textDark3),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            NamesNotice(
              kind: NamesNoticeKind.error,
              title: "Can't read your name key right now",
              detail: namesErrorText(_error!),
              actionLabel: 'Try again',
              onAction: _load,
            )
          else if (key == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            NamesCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  QR(data: key, size: 180),
                  const SizedBox(height: 12),
                  Text(
                    BansKey.fingerprint(key),
                    key: const Key('names-key-fingerprint'),
                    style: STextStyles.pageTitleH1(context),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    key,
                    textAlign: TextAlign.center,
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            'Sharing it is safe: it cannot move money. Anyone who has it can '
            'see which names belong to this wallet.',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ],
      ),
      bottom: NamesPrimaryAction(
        deps: widget.deps,
        buttonKey: const Key('names-key-copy'),
        label: _copied ? 'Copied' : 'Copy my name key',
        onPressed: key == null ? null : _copy,
      ),
    );
  }
}
