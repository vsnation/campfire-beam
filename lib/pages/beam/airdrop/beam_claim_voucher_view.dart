/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
//   Job:  turn a voucher code into tokens in this wallet.
//   CTA:  "Claim <amount> <ticker>" (or "Claim anyway" when the voucher is
//         worth less than its network fee).
//   Taps: open wallet → Claim a voucher → paste → Claim → PIN (3 + PIN).
//
// Exit-intent (§1.7), and what this screen does about each:
//   * "Is this a scam / what will it cost me?" → the value and the network
//     fee decoded from the prepared transaction are on screen before the
//     button is live; nothing is signed without the PIN.
//   * "It costs more than it gives" → said in plain numbers, with the loss.
//   * "The code doesn't work" → the error says why and what to check,
//     without blaming the user.
//   * "Nothing happens" → checking starts by itself once a full code is in
//     and says "Checking the code…" while it works.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../utilities/barcode_scanner_interface.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../widgets/beam/airdrop/airdrop_text.dart';
import '../../../widgets/beam/airdrop/beam_asset_names.dart';
import '../../../widgets/beam/airdrop/beam_blocks.dart';
import '../../../widgets/beam/airdrop/beam_layout.dart';
import '../../../widgets/beam/airdrop/beam_send_flow.dart';
import '../../../widgets/beam/airdrop/beam_spend_auth.dart';
import '../../../widgets/beam/airdrop/beam_sync_gate.dart';
import '../../../widgets/beam/airdrop/beam_units.dart';
import '../../../widgets/beam/airdrop/voucher_code_input.dart';
import '../../../widgets/beam/stickers/beam_sticker.dart';
import '../../../widgets/icon_widgets/clipboard_icon.dart';
import '../../../widgets/icon_widgets/qrcode_icon.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/textfield_icon_button.dart';

/// Claim an airdrop voucher with its code.
///
/// Typing or pasting a full code builds the claim right away (nothing is
/// signed or sent), so the screen can show what the voucher gives and the
/// network fee the core will charge, read back from that transaction. The
/// prepared claim is discarded whenever the code changes or the screen
/// closes, which releases [service] for the next airdrop action.
class BeamClaimVoucherView extends StatefulWidget {
  const BeamClaimVoucherView({
    super.key,
    required this.service,
    required this.sync,
    this.assetNames,
    this.authorize = campfireAuthorizeSpend,
    this.clipboard = const ClipboardWrapper(),
    this.scanner = const BarcodeScannerWrapper(),
    this.initialCode,
    this.onDone,
  });

  static const routeName = '/beamClaimVoucher';
  static const title = 'Claim a voucher';

  /// This wallet's airdrop service (one instance per wallet).
  final BeamAirdropService service;

  /// The wallet's sync verdict: claiming is off unless it can spend.
  final ValueListenable<BeamSyncAssessment> sync;

  /// Defaults to names read through [service]'s wallet core.
  final BeamAssetNames? assetNames;
  final BeamSpendAuthorizer authorize;
  final ClipboardInterface clipboard;

  /// Used on phones only (desktop has no camera flow in Campfire).
  final BarcodeScannerInterface scanner;

  /// A code from a link or a scan, checked on open.
  final String? initialCode;

  /// After a claim, "Done" calls this; it pops the route when null.
  final VoidCallback? onDone;

  @override
  State<BeamClaimVoucherView> createState() => _BeamClaimVoucherViewState();
}

class _BeamClaimVoucherViewState extends State<BeamClaimVoucherView>
    with BeamSendFlow {
  /// Codes this module generates have 16 symbols; codes made elsewhere may
  /// differ, so shorter text is checked too, after a pause in typing.
  static const _minAutoCheck = 8;

  final _code = TextEditingController();
  late final BeamAssetNames _names =
      widget.assetNames ?? BeamAssetNames.fromApi(widget.service.api);

  BeamPreparedAirdropCall? _prepared;
  BigInt? _beamAvailable;
  Timer? _debounce;
  bool _checking = false;
  bool _inFlight = false;
  bool _again = false;
  String? _claimedText;

  @override
  void initState() {
    super.initState();
    _names.addListener(_rebuild);
    final initial = widget.initialCode;
    if (initial != null && initial.isNotEmpty) {
      _code.text = AirdropVoucherCode.format(initial);
      _debounce = Timer(Duration.zero, _check);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _dropPrepared();
    _names.removeListener(_rebuild);
    _code.dispose();
    super.dispose();
  }

  String get _normalised => AirdropVoucherCode.normalise(_code.text);

  void _dropPrepared() {
    final p = _prepared;
    if (p != null && !p.isExecuted) widget.service.discard(p);
    _prepared = null;
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _dropPrepared();
    setState(() => problem = null);
    final n = _normalised.length;
    if (n >= _minAutoCheck) {
      _debounce = Timer(
        n >= AirdropVoucherCode.length
            ? Duration.zero
            : const Duration(milliseconds: 700),
        _check,
      );
    }
  }

  Future<void> _paste() async {
    final data = await widget.clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    _code.text = AirdropVoucherCode.format(text);
    _onChanged(_code.text);
  }

  Future<void> _scan() async {
    final r = await widget.scanner.scan(context: context);
    final text = r.rawContent;
    if (text == null || !mounted) return;
    _code.text = AirdropVoucherCode.format(text);
    _onChanged(_code.text);
  }

  /// Builds the claim for the code in the field. Runs one at a time; a
  /// change while it runs re-checks once it returns, and a stale result is
  /// discarded, never shown.
  Future<void> _check() async {
    _debounce?.cancel();
    if (_inFlight) {
      _again = true;
      return;
    }
    _inFlight = true;
    try {
      do {
        _again = false;
        final code = _code.text;
        if (AirdropVoucherCode.normalise(code).isEmpty) break;
        _dropPrepared();
        if (mounted) {
          setState(() {
            _checking = true;
            problem = null;
          });
        }
        try {
          final p = await widget.service.prepareRedeem(code);
          if (!mounted ||
              _again ||
              AirdropVoucherCode.normalise(code) != _normalised) {
            widget.service.discard(p);
            continue;
          }
          _prepared = p;
          unawaited(_names.preload([p.summary.assetId]));
          _beamAvailable = await _beamBalance();
        } catch (e) {
          if (!mounted || _again) continue;
          problem = airdropProblem(e);
        }
      } while (_again && mounted);
    } finally {
      _inFlight = false;
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<BigInt?> _beamBalance() async {
    try {
      return (await beamAvailableBalances(widget.service.api))[0];
    } catch (_) {
      return null; // Not known; the core checks again when sending.
    }
  }

  /// BEAM this claim takes from the wallet beyond what it returns.
  BigInt _beamNeeded(AirdropSummary s) {
    final net = s.beamOut - (s.receives[0] ?? BigInt.zero);
    return net.isNegative ? BigInt.zero : net;
  }

  Future<void> _claim() async {
    final p = _prepared;
    if (p == null) return;
    final s = p.summary;
    final gets = _names.amount(s.assetId, s.receives[s.assetId]!);
    final tx = await runSend(
      authorize: widget.authorize,
      reason: 'Claim $gets',
      send: () => widget.service.execute(p),
      explain: airdropProblem,
    );
    if (!mounted) return;
    if (p.isExecuted) _prepared = null;
    if (tx != null) setState(() => _claimedText = gets);
  }

  void _another() {
    setState(() {
      _claimedText = null;
      problem = null;
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) => BeamSyncGate(
    sync: widget.sync,
    builder: (context, sync) {
      if (_claimedText != null) return _done(context);
      final p = _prepared;
      final s = p?.summary;
      final shortOfBeam =
          s != null &&
          _beamAvailable != null &&
          _beamAvailable! < _beamNeeded(s);
      final String label;
      VoidCallback? action;
      if (s != null) {
        label = s.claimCostsMoreThanItPays
            ? 'Claim anyway'
            : 'Claim ${_names.amount(s.assetId, s.receives[s.assetId]!)}';
        action = sync.canSpend && !shortOfBeam ? _claim : null;
      } else if (problem != null && _normalised.isNotEmpty) {
        label = 'Check again';
        action = _check;
      } else if (_normalised.length >= _minAutoCheck) {
        label = 'Check code';
        action = _check;
      } else {
        label = 'Claim voucher';
      }
      return BeamPageScaffold(
        title: BeamClaimVoucherView.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste the code you were given. You see what it is worth '
              'before anything is sent.',
              style: STextStyles.itemSubtitle(context),
            ),
            const BeamGap(16),
            _codeField(context),
            const BeamGap(16),
            if (_checking) const BeamWorking('Checking the code…'),
            if (problem != null && !_checking)
              BeamNotice(
                key: const ValueKey('claim-problem'),
                kind: BeamNoticeKind.danger,
                title: problem!.title,
                message: problem!.message,
              ),
            if (s != null && !_checking) ...[
              _summary(context, s),
              if (s.claimCostsMoreThanItPays) ...[
                const BeamGap(),
                _lossWarning(s),
              ],
              if (shortOfBeam) ...[
                const BeamGap(),
                BeamNotice(
                  key: const ValueKey('claim-short-of-beam'),
                  kind: BeamNoticeKind.danger,
                  title: 'Not enough BEAM for the network fee',
                  message:
                      'Claiming needs '
                      '${BeamUnits.withSymbol(_beamNeeded(s), 'BEAM')} and '
                      'this wallet has '
                      '${BeamUnits.withSymbol(_beamAvailable!, 'BEAM')}. Add '
                      'BEAM to this wallet, then claim.',
                ),
              ],
            ],
          ],
        ),
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (s != null) BeamSyncNotice(sync: sync, what: 'Claiming'),
            BeamCtaBar(
              primaryKey: const ValueKey('claim-cta'),
              label: label,
              busy: _checking || sending,
              busyLabel: sending ? 'Claiming…' : 'Checking…',
              onPressed: action,
            ),
          ],
        ),
      );
    },
  );

  Widget _codeField(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    return BeamTextField(
      fieldKey: const ValueKey('claim-code-field'),
      controller: _code,
      label: 'Voucher code',
      hint: 'XXXX-XXXX-XXXX-XXXX',
      style: voucherCodeStyle(context),
      textCapitalization: TextCapitalization.characters,
      inputFormatters: const [VoucherCodeFormatter()],
      onChanged: _onChanged,
      helper:
          _normalised.isNotEmpty &&
              _normalised.length < AirdropVoucherCode.length &&
              _prepared == null &&
              !_checking &&
              problem == null
          ? '${_normalised.length} of ${AirdropVoucherCode.length} '
                'characters'
          : null,
      suffix: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFieldIconButton(
            key: const ValueKey('claim-paste'),
            semanticsLabel: 'Paste the code',
            onTap: _paste,
            child: const ClipboardIcon(),
          ),
          if (!desktop)
            TextFieldIconButton(
              key: const ValueKey('claim-scan'),
              semanticsLabel: 'Scan a QR code',
              onTap: _scan,
              child: const QrCodeIcon(),
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _lossWarning(AirdropSummary s) {
    String beam(BigInt g) => BeamUnits.withSymbol(g, 'BEAM');
    final gives = s.receives[0]!;
    return BeamNotice(
      key: const ValueKey('claim-loss-warning'),
      kind: BeamNoticeKind.warning,
      title: 'This voucher is worth less than the fee',
      message:
          'It gives ${beam(gives)} and the network fee to claim it is '
          '${beam(s.networkFee)}, so your balance goes down by '
          '${beam(s.networkFee - gives)}. Claim only if you want it anyway.',
    );
  }

  Widget _summary(BuildContext context, AirdropSummary s) {
    final gets = s.receives[s.assetId]!;
    final isBeam = s.assetId == 0;
    final net = (s.receives[0] ?? BigInt.zero) - s.beamOut;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RoundedWhiteContainer(
          child: BeamAssetTitle(
            display: _names.display(s.assetId),
            subtitle: 'Voucher found — not claimed yet',
          ),
        ),
        const BeamGap(8),
        BeamDetailCard(
          children: [
            BeamDetailRow(
              label: 'You get',
              value: _names.amount(s.assetId, gets),
              valueKey: const ValueKey('claim-gets'),
            ),
            BeamDetailRow(
              label: 'Network fee',
              value: BeamUnits.withSymbol(s.networkFee, 'BEAM'),
              detail: isBeam ? null : 'Paid from your BEAM',
              valueKey: const ValueKey('claim-fee'),
            ),
          ],
        ),
        const BeamGap(8),
        BeamTotalRow(
          label: isBeam ? 'Your balance changes by' : 'In total',
          value: isBeam
              ? '${net.isNegative ? '−' : '+'}'
                    '${BeamUnits.withSymbol(net.abs(), 'BEAM')}'
              : '+${_names.amount(s.assetId, gets)}, '
                    '−${BeamUnits.withSymbol(s.beamOut, 'BEAM')}',
          valueKey: const ValueKey('claim-total'),
        ),
      ],
    );
  }

  Widget _done(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    return BeamPageScaffold(
      title: BeamClaimVoucherView.title,
      body: Padding(
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          children: [
            const BeamAnimatedStickerView(BeamMoments.claimDone, size: 140),
            const BeamGap(16),
            Text(
              '$_claimedText is on its way',
              key: const ValueKey('claim-done'),
              textAlign: TextAlign.center,
              style: desktop
                  ? STextStyles.desktopH3(context)
                  : STextStyles.pageTitleH2(context),
            ),
            const BeamGap(8),
            Text(
              'It shows in your balance once the network confirms the '
              'claim, usually within a few minutes.',
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle(context),
            ),
          ],
        ),
      ),
      bottom: BeamCtaBar(
        label: 'Done',
        onPressed: widget.onDone ?? () => Navigator.of(context).maybePop(),
        secondaryLabel: 'Claim another code',
        onSecondary: _another,
      ),
    );
  }
}
