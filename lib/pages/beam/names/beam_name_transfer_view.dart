/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. ONE job: give this name to another wallet, to exactly the key its
//    owner showed you.
// 2. Primary CTA: "Transfer alice" (then the confirmation, a tick that the
//    key was checked, and the PIN).
// 3. Taps from app open: Names (1) → alice (2) → Transfer (3) → paste (4)
//    → Transfer alice (5) → tick + Transfer alice (6) → PIN. Long on
//    purpose: it gives away a name worth $10–$320 a year and cannot be
//    undone (§1.2 allows a confirmation step for that).
//
// Exit-intent (§1.7) — what could make an impatient person leave:
// * "Where do I get the key?" — the first line says where the receiving
//   wallet shows it.
// * "Did I paste the right thing?" — the key's short fingerprint is shown
//   large, to read out and compare with the other wallet.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../widgets/beam/names/names_deps.dart';
import '../../../widgets/beam/names/names_format.dart';
import '../../../widgets/beam/names/names_widgets.dart';
import '../../../widgets/desktop/secondary_button.dart';
import 'beam_name_confirm_view.dart';

/// Transfers one of my names to another wallet's name key.
class BeamNameTransferView extends StatefulWidget {
  const BeamNameTransferView({
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
    (_) => BeamNameTransferView(deps: deps, domain: domain, clock: clock),
  );

  @override
  State<BeamNameTransferView> createState() => _BeamNameTransferViewState();
}

class _BeamNameTransferViewState extends State<BeamNameTransferView> {
  final _controller = TextEditingController();
  String? _key;
  String? _keyError;
  bool _preparing = false;
  String? _error;

  BeamNamesDeps get deps => widget.deps;
  String get _name => widget.domain.name;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String text) async {
    final t = text.trim();
    String? key;
    String? error;
    if (t.isNotEmpty) {
      try {
        key = BansKey.require(t);
      } on BansInvalidKey catch (e) {
        error = e.message;
      }
    }
    setState(() {
      _key = key;
      _keyError = error;
      _error = null;
    });
    if (key == null) return;
    try {
      final mine = await deps.bans.myKey();
      if (!mounted || _key != key) return;
      if (mine == key) {
        setState(() {
          _key = null;
          _keyError =
              "That is this wallet's own key. Paste the key of the wallet "
              'that should get $_name.';
        });
      }
    } catch (_) {
      // The core refuses a transfer to the current owner anyway.
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _controller.text = text;
    await _onChanged(text);
  }

  Future<void> _transfer() async {
    final name = BansName(_name);
    final key = _key!;
    Future<BansPrepared> build() => deps.bans.prepareSetOwner(name, key);
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
    final key = _key;
    final until = NamesFormat.date(
      widget.clock.dateOf(widget.domain.expireHeight),
    );
    return NamesPage(
      deps: deps,
      title: 'Transfer $_name',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NamesSyncBanner(deps: deps),
          Text(
            'Give $_name to another wallet. Ask its owner for their name key: '
            'in Campfire it is under Names → Receive a name.',
            style: STextStyles.smallMed12(context)
                .copyWith(color: colors.textDark3),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: colors.textFieldDefaultBG,
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
            ),
            child: TextField(
              key: const Key('names-transfer-key'),
              controller: _controller,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 2,
              maxLines: 3,
              onChanged: _onChanged,
              style: STextStyles.field(context),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.all(16),
                hintText: "Paste the receiving wallet's name key",
                hintStyle: STextStyles.fieldLabel(context),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
              label: 'Paste',
              width: 120,
              buttonHeight: deps.desktop ? ButtonHeight.s : ButtonHeight.l,
              onPressed: _paste,
            ),
          ),
          if (_keyError != null) ...[
            const SizedBox(height: 8),
            Text(
              _keyError!,
              key: const Key('names-transfer-key-error'),
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textError),
            ),
          ],
          if (key != null) ...[
            const SizedBox(height: 16),
            NamesCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'New owner',
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.infoItemLabel),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    BansKey.fingerprint(key),
                    key: const Key('names-transfer-fingerprint'),
                    style: STextStyles.pageTitleH1(context),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Read these characters to the receiving wallet\'s '
                    'owner. Their Names screen shows the same ones.',
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            NamesNotice(
              kind: NamesNoticeKind.warning,
              title: "This can't be undone",
              detail:
                  'Only the new owner can give $_name back. Its time left '
                  '(until $until) goes with it.',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            NamesNotice(
              key: const Key('names-transfer-error'),
              kind: NamesNoticeKind.error,
              title: "Couldn't prepare the transfer",
              detail: _error,
            ),
          ],
        ],
      ),
      bottom: NamesPrimaryAction(
        deps: deps,
        buttonKey: const Key('names-transfer-cta'),
        label: _preparing ? 'Preparing…' : 'Transfer $_name',
        onPressed: key == null || _preparing ? null : _transfer,
        reason: key == null && !_preparing
            ? 'Paste the key of the wallet that should get $_name.'
            : null,
      ),
    );
  }
}
