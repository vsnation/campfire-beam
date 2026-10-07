/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. Job: show exactly what this dApp will take from and give to the
//    wallet, before anything happens, and let the user decide.
// 2. Primary CTA: the outcome, "Approve swap" / "Approve payment" /
//    "Approve withdrawal" / "Approve request"; secondary "Reject".
// 3. Taps: 1 to approve + Campfire's PIN or password (2), from the moment
//    the sheet opens. Back, swipe-down, outside tap and the close button
//    all reject. Approve takes no taps for [DappApprovalSheet.armDelay]
//    after the sheet appears or its layout changes, so a tap aimed at the
//    dApp page cannot land on it; biometrics never start by themselves.
//
// Exit-intent (§1.7) — what would make an impatient person close the app:
// * A popup they did not expect. The dApp page shows a banner instead of
//   this sheet unless the user touched the page in the last seconds.
// * Not understanding what they sign: amounts are signed and coloured per
//   asset with their fiat value, the fee is its own row, the total is one
//   line, and the dApp's own text is quoted and labelled as the dApp's.
// * Finding out later that a swap was redone at another price: when the
//   core may rebuild what is approved, the sheet says so first, with the
//   worst it may sign; when the code that would rebuild it is not BEAM's
//   own DEX, the warning is in the warning colour and Approve needs an
//   explicit "I understand" tick (USER_PSYCHOLOGY §5: never surprise-sign).
// * A dead end when funds are short: the sheet says what is missing and
//   what to do, and Reject stays available.
// * Not knowing whether more prompts are coming: "2 more requests waiting".

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../pages/pinpad_views/lock_screen_view.dart';
import '../../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../../route_generator.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/dapps/host/dapp_approval_model.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../custom_buttons/simple_copy_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import 'dapp_asset_icon.dart';
import 'dapp_avatar.dart';
import 'dapp_manual_biometrics.dart';

/// Campfire's PIN (mobile) or password (desktop) check. True: passed;
/// false: wrong PIN or password; null: the user backed out.
typedef DappApprovalAuthenticator = Future<bool?> Function(
  BuildContext context,
);

/// Shows [model] as a bottom sheet (mobile) or dialog (desktop) and
/// completes with true only when the user approved and passed Campfire's
/// PIN or password check. Everything else, including dismissing the sheet
/// and the request being withdrawn, is false.
///
/// [pending]: requests waiting or on screen, for the "N more waiting" line.
/// [desktop] overrides `Util.isDesktop` (tests).
Future<bool> showDappApprovalSheet(
  BuildContext context,
  DappApprovalModel model, {
  ValueListenable<int>? pending,
  DappApprovalAuthenticator? authenticate,
  bool? desktop,
}) async {
  final isDesktop = desktop ?? Util.isDesktop;
  final sheet = DappApprovalSheet(
    model: model,
    pending: pending,
    authenticate: authenticate ?? dappCampfireAuthenticate,
    isDesktop: isDesktop,
  );
  final bool? result;
  if (isDesktop) {
    result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => DesktopDialog(
        maxWidth: 580,
        maxHeight: MediaQuery.of(context).size.height - 64,
        child: sheet,
      ),
    );
  } else {
    result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => sheet,
    );
  }
  return result == true && !model.request.isCancelled;
}

/// The check Campfire's own send screen uses before broadcasting
/// (`ConfirmTransactionView`): the password dialog on desktop, the PIN
/// screen (or biometrics) on mobile.
Future<bool?> dappCampfireAuthenticate(BuildContext context) async {
  if (Util.isDesktop) {
    return showDialog<bool?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
              child: DesktopAuthSend(coin: Beam(CryptoCurrencyNetwork.main)),
            ),
          ],
        ),
      ),
    );
  }
  return Navigator.push<bool>(
    context,
    RouteGenerator.getRoute<bool>(
      shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
      builder: (_) => LockscreenView(
        showBackButton: true,
        popOnSuccess: true,
        routeOnSuccessArguments: true,
        routeOnSuccess: "",
        biometricsCancelButtonString: "CANCEL",
        biometricsLocalizedReason: "Authenticate to approve this dApp request",
        biometricsAuthenticationTitle: "Approve dApp request",
        // Face ID / fingerprint only after the user taps "Use biometrics":
        // never a glance that approves what a page put under their finger.
        biometrics: DappManualBiometrics(),
      ),
      settings: const RouteSettings(name: "/dappApprovalLockscreen"),
    ),
  );
}

class DappApprovalSheet extends StatefulWidget {
  const DappApprovalSheet({
    super.key,
    required this.model,
    required this.authenticate,
    required this.isDesktop,
    this.pending,
  });

  final DappApprovalModel model;
  final DappApprovalAuthenticator authenticate;
  final bool isDesktop;
  final ValueListenable<int>? pending;

  static const approveKey = Key('dappApprovalApprove');
  static const rejectKey = Key('dappApprovalReject');

  /// The "worst case after approval" box of a request the core can
  /// rebuild, and its "I understand" tick.
  static const rebuildKey = Key('dappApprovalRebuild');
  static const acknowledgeKey = Key('dappApprovalRebuildAck');

  /// How long Approve ignores taps after the sheet appears, and again after
  /// its layout changes (another request joins the queue): a tap meant for
  /// the dApp page must not become an approval.
  static const armDelay = Duration(milliseconds: 700);

  @override
  State<DappApprovalSheet> createState() => _DappApprovalSheetState();
}

class _DappApprovalSheetState extends State<DappApprovalSheet> {
  bool _busy = false;
  bool _armed = false;

  /// The user ticked "I understand" (only asked for when
  /// [DappApprovalModel.needsAcknowledgement]).
  bool _acknowledged = false;

  bool get _approvable =>
      widget.model.canApprove &&
      (!widget.model.needsAcknowledgement || _acknowledged);
  Timer? _armTimer;
  int? _pendingSeen;
  ModalRoute<Object?>? _route;

  /// Approve takes taps again only [DappApprovalSheet.armDelay] from now.
  /// [rebuild]: false when called where a build follows anyway
  /// (`didUpdateWidget`), which must not call `setState`.
  void _arm({bool rebuild = true}) {
    _armTimer?.cancel();
    if (_armed) {
      if (rebuild) {
        setState(() => _armed = false);
      } else {
        _armed = false;
      }
    }
    _armTimer = Timer(DappApprovalSheet.armDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  void _pendingChanged() {
    final now = widget.pending?.value;
    // The queue note above the buttons appears, changes or goes: the
    // layout moved, so wait again before Approve takes a tap.
    if (now != _pendingSeen) {
      _pendingSeen = now;
      _arm();
    }
  }

  @override
  void didUpdateWidget(DappApprovalSheet old) {
    super.didUpdateWidget(old);
    if (!identical(old.pending, widget.pending)) {
      old.pending?.removeListener(_pendingChanged);
      widget.pending?.addListener(_pendingChanged);
    }
    if (!identical(old.model, widget.model)) {
      _acknowledged = false;
      _arm(rebuild: false);
    }
  }

  @override
  void dispose() {
    _armTimer?.cancel();
    widget.pending?.removeListener(_pendingChanged);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _pendingSeen = widget.pending?.value;
    widget.pending?.addListener(_pendingChanged);
    _arm(rebuild: false);
    // The dApp was closed or reloaded: the request is gone, so is the
    // sheet, even if the PIN screen is on top of it.
    unawaited(
      widget.model.request.cancelled.then((_) {
        final route = _route;
        if (!mounted || route == null || !route.isActive) return;
        Navigator.of(context).removeRoute(route);
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  void _reject() {
    if (mounted) Navigator.of(context).pop(false);
  }

  Future<void> _approve() async {
    if (_busy || !_armed || !_approvable) return;
    setState(() => _busy = true);
    try {
      final ok = await widget.authenticate(context);
      if (!mounted || widget.model.request.isCancelled) return;
      if (ok == true) {
        Navigator.of(context).pop(true);
        return;
      }
      if (ok == false) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.warning,
            message: widget.isDesktop ? "Invalid passphrase" : "Invalid PIN",
            context: context,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final m = widget.model;
    final desktop = widget.isDesktop;

    final body = _SheetBody(model: m, isDesktop: desktop);
    // Next to Approve, so a disabled Approve never needs a scroll to
    // explain itself.
    final acknowledge = m.needsAcknowledgement
        ? _Acknowledge(
            text: m.rebuild!.acknowledgement,
            value: _acknowledged,
            onChanged: (v) => setState(() => _acknowledged = v),
          )
        : const SizedBox.shrink();

    final approve = PrimaryButton(
      key: DappApprovalSheet.approveKey,
      label: m.cta,
      enabled: _approvable && !_busy && _armed,
      buttonHeight: desktop ? ButtonHeight.l : null,
      height: desktop ? null : 46,
      onPressed: _approve,
    );
    final reject = SecondaryButton(
      key: DappApprovalSheet.rejectKey,
      label: "Reject",
      buttonHeight: desktop ? ButtonHeight.l : null,
      height: desktop ? null : 46,
      onPressed: _reject,
    );
    final waiting = widget.pending == null
        ? const SizedBox.shrink()
        : ValueListenableBuilder<int>(
            valueListenable: widget.pending!,
            builder: (context, pending, _) =>
                _QueueNote(waiting: pending - 1, isDesktop: desktop),
          );

    if (desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(
                  "Review request",
                  style: STextStyles.desktopH3(context),
                ),
              ),
              const Spacer(),
              DesktopDialogCloseButton(onPressedOverride: _reject),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: body,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                waiting,
                acknowledge,
                Row(
                  children: [
                    Expanded(child: reject),
                    const SizedBox(width: 16),
                    Expanded(child: approve),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.92,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: colors.popupBG,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 60,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.textFieldDefaultBG,
                  borderRadius: BorderRadius.circular(
                    Constants.size.circularBorderRadius,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: body,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  waiting,
                  acknowledge,
                  approve,
                  const SizedBox(height: 8),
                  reject,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBody extends StatelessWidget {
  const _SheetBody({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final m = model;
    if (m.isSignMessage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(model: m, isDesktop: isDesktop),
          const SizedBox(height: 16),
          _SignCard(model: m),
          const SizedBox(height: 8),
        ],
      );
    }
    final warnings = [
      if (m.blockedReason != null) m.blockedReason!,
      ...m.signingWarnings,
      ?m.passThroughWarning,
      ...m.lookalikeWarnings,
      for (final s in m.shortfallWarnings)
        '$s Add funds to this wallet, then try again in ${m.dappName}.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(model: m, isDesktop: isDesktop),
        const SizedBox(height: 16),
        m.showsCalls
            ? _CallsCard(model: m, isDesktop: isDesktop)
            : _MoneyCard(model: m, isDesktop: isDesktop),
        if (m.rebuild != null) ...[
          const SizedBox(height: 8),
          _RebuildCard(view: m.rebuild!),
        ],
        for (final w in warnings) ...[
          const SizedBox(height: 8),
          _Warning(text: w),
        ],
        const SizedBox(height: 12),
        _TotalBox(model: m, isDesktop: isDesktop),
        if (m.message != null) ...[
          const SizedBox(height: 16),
          _DappMessage(dappName: m.dappName, message: m.message!),
        ],
        const SizedBox(height: 16),
        m.isPayment
            ? _Recipient(model: m)
            : _Contracts(model: m, isDesktop: isDesktop),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DappAvatar(name: model.dappName, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.dappName,
                    style: isDesktop
                        ? STextStyles.desktopTextMedium(context)
                        : STextStyles.pageTitleH2(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    model.originLine,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (model.notCheckedByCampfire) ...[
                    const SizedBox(height: 4),
                    RoundedContainer(
                      color: colors.warningBackground,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      radiusMultiplier: 0.5,
                      child: Text(
                        "Installed from a file · not checked by Campfire",
                        style: STextStyles.w500_10(context)
                            .copyWith(color: colors.warningForeground),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          model.summary,
          style: STextStyles.smallMed14(context)
              .copyWith(color: colors.textDark),
        ),
      ],
    );
  }
}

class _MoneyCard extends StatelessWidget {
  const _MoneyCard({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget divider() => Container(height: 1, color: colors.background);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Text(text, style: STextStyles.smallMed12(context)),
    );
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      borderColor: colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (model.pays.isNotEmpty) ...[
            label("You pay"),
            for (final l in model.pays)
              _AssetRow(line: l, outgoing: true, isDesktop: isDesktop),
          ],
          if (model.receives.isNotEmpty) ...[
            if (model.pays.isNotEmpty) divider(),
            label("You receive"),
            for (final l in model.receives)
              _AssetRow(line: l, outgoing: false, isDesktop: isDesktop),
          ],
          if (model.isFeeOnly)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                "Nothing you hold moves. You pay only the network fee.",
                style: STextStyles.smallMed14(context)
                    .copyWith(color: colors.textDark),
              ),
            ),
          divider(),
          _FeeRow(fee: model.fee),
        ],
      ),
    );
  }
}

/// The worst the core may sign after approval, for data it can rebuild:
/// whose code would rebuild it, for how long, and the bounds the wallet
/// enforces. Neutral for BEAM's DEX; in the warning colour for any other
/// code (whose "I understand" tick sits next to Approve, [_Acknowledge]).
class _RebuildCard extends StatelessWidget {
  const _RebuildCard({required this.view});

  final DappRebuildView view;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final warn = !view.verified;
    final fg = warn ? colors.warningForeground : colors.textDark;
    final sub = warn ? colors.warningForeground : colors.textDark3;
    Widget bound(String label, DappAssetLine l, {required bool pay}) {
      final none = !pay && l.amount == BigInt.zero;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                none ? "You may get no ${l.unit}" : label,
                style: STextStyles.smallMed12(context).copyWith(color: fg),
              ),
            ),
            if (!none)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SelectableText(
                    "${pay ? "−" : "+"}${l.text}",
                    textAlign: TextAlign.right,
                    style: STextStyles.w600_14(context).copyWith(color: fg),
                  ),
                  if (l.fiat != null)
                    Text(
                      l.fiat!,
                      style: STextStyles.w500_12(context).copyWith(color: sub),
                    ),
                ],
              ),
          ],
        ),
      );
    }

    return RoundedContainer(
      key: DappApprovalSheet.rebuildKey,
      color: warn ? colors.warningBackground : colors.textFieldDefaultBG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                warn ? Icons.warning_amber_rounded : Icons.swap_vert_rounded,
                color: fg,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  view.title,
                  style: STextStyles.w600_14(context).copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            view.explanation,
            style: STextStyles.smallMed12(context).copyWith(color: sub),
          ),
          for (final l in view.maxPays) bound("You pay at most", l, pay: true),
          for (final l in view.minReceives)
            bound("You get at least", l, pay: false),
        ],
      ),
    );
  }
}

/// The "I understand" tick Approve waits for when unverified app code may
/// rebuild what is approved.
class _Acknowledge extends StatelessWidget {
  const _Acknowledge({
    required this.text,
    required this.value,
    required this.onChanged,
  });

  final String text;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: DappApprovalSheet.acknowledgeKey,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: colors.checkboxBGChecked,
              checkColor: colors.checkboxIconChecked,
            ),
            Expanded(
              child: Text(
                text,
                style: STextStyles.smallMed12(context)
                    .copyWith(color: colors.warningForeground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Network fee · 0.011 BEAM", its fiat value under it when known.
class _FeeRow extends StatelessWidget {
  const _FeeRow({required this.fee});

  final DappAssetLine fee;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final amount = SelectableText(
      fee.text,
      key: const Key('dappApprovalFee'),
      style: STextStyles.itemSubtitle12(context),
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: fee.fiat == null
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text("Network fee", style: STextStyles.smallMed12(context)),
          const Spacer(),
          if (fee.fiat == null)
            amount
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                amount,
                Text(
                  fee.fiat!,
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AssetRow extends StatelessWidget {
  const _AssetRow({
    required this.line,
    required this.outgoing,
    required this.isDesktop,
  });

  final DappAssetLine line;
  final bool outgoing;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final a = line.asset;
    final color = outgoing ? colors.accentColorRed : colors.accentColorGreen;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          DappAssetIcon(asset: a, size: 32),
          const SizedBox(width: 10),
          // The amount gets the wider share: it must never wrap or hide.
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.symbol,
                  style: STextStyles.w600_14(context)
                      .copyWith(color: colors.textDark),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                a.verified
                    ? Text(
                        a.name,
                        style: STextStyles.w500_12(context)
                            .copyWith(color: colors.textSubtitle1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : _UnverifiedTag(idLabel: a.idLabel),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SelectableText(
                  "${outgoing ? "−" : "+"}${line.text}",
                  textAlign: TextAlign.right,
                  style: STextStyles.w600_14(context).copyWith(color: color),
                ),
                if (line.fiat != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    line.fiat!,
                    textAlign: TextAlign.right,
                    style: STextStyles.w500_12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UnverifiedTag extends StatelessWidget {
  const _UnverifiedTag({required this.idLabel});

  final String idLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      color: colors.warningBackground,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      radiusMultiplier: 0.5,
      child: Text(
        "Unverified asset $idLabel",
        style: STextStyles.w500_10(context)
            .copyWith(color: colors.warningForeground),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      color: colors.warningBackground,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colors.warningForeground,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.warningForeground),
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalBox extends StatelessWidget {
  const _TotalBox({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.titleBold12(context)
        .copyWith(color: colors.textConfirmTotalAmount);
    return RoundedContainer(
      color: colors.snackBarBackSuccess,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Total leaving your wallet", style: style),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final l in model.totalOut)
                  SelectableText(
                    l.fiat == null ? l.text : "${l.text} (${l.fiat})",
                    textAlign: TextAlign.right,
                    style: STextStyles.itemSubtitle12(context)
                        .copyWith(color: colors.textConfirmTotalAmount),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The dApp's own words, never styled as Campfire's: quoted, in italics, in
/// a box with a side bar, under a label naming who wrote it.
class _DappMessage extends StatelessWidget {
  const _DappMessage({
    required this.dappName,
    required this.message,
    this.label,
  });

  final String dappName;
  final String message;

  /// Overrides "Message from <dApp>".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label ?? "Message from $dappName",
          style: STextStyles.smallMed12(context),
        ),
        const SizedBox(height: 2),
        Text(
          "Written by the dApp. Campfire did not write or check it.",
          style: STextStyles.w500_10(context)
              .copyWith(color: colors.textSubtitle2),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: colors.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(
              Constants.size.circularBorderRadius,
            ),
            border: Border(
              left: BorderSide(color: colors.textSubtitle3, width: 3),
            ),
          ),
          child: SelectableText(
            "“$message”",
            style: STextStyles.w400_14(context)
                .copyWith(color: colors.textDark3, fontStyle: FontStyle.italic),
          ),
        ),
      ],
    );
  }
}

class _Contracts extends StatefulWidget {
  const _Contracts({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  State<_Contracts> createState() => _ContractsState();
}

class _ContractsState extends State<_Contracts> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final m = widget.model;
    final ids = m.contractIds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          ids.length > 1 ? "Contracts" : "Contract",
          style: STextStyles.smallMed12(context),
        ),
        const SizedBox(height: 4),
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    m.contractNameOf(id) == null
                        ? "Unknown contract · ${dappShortHex(id)}"
                        : "${m.contractNameOf(id)} · ${dappShortHex(id)}",
                    style: STextStyles.itemSubtitle12(context),
                  ),
                ),
                SimpleCopyButton(data: id),
              ],
            ),
          ),
        if (m.deploys)
          Text(
            "Creates a new contract",
            style: STextStyles.itemSubtitle12(context),
          ),
        if (m.rebuild != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              "App code: ${m.rebuild!.appCodeLabel} · "
              "${m.rebuild!.appCodeFingerprint}",
              key: const Key('dappApprovalAppCode'),
              style: STextStyles.itemSubtitle12(context).copyWith(
                color: m.rebuild!.verified ? null : colors.warningForeground,
              ),
            ),
          ),
        GestureDetector(
          onTap: () => setState(() => _details = !_details),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              _details ? "Hide details" : "Show details",
              style: STextStyles.link2(context),
            ),
          ),
        ),
        if (_details)
          SelectableText(
            [
              for (final c in m.request.calls)
                "${c.contractId ?? "new contract"} · method ${c.method}",
              if (m.rebuild != null)
                "App code SHA-256 ${m.rebuild!.terms.appCodeSha256}",
              "Approval fingerprint ${m.request.digest}",
            ].join("\n"),
            style: STextStyles.w500_10(context)
                .copyWith(color: colors.textSubtitle1),
          ),
      ],
    );
  }
}

/// Each contract call on its own, when there is more than one: what it
/// alone takes from or gives the wallet, and whether the wallet signs it.
class _CallsCard extends StatelessWidget {
  const _CallsCard({required this.model, required this.isDesktop});

  final DappApprovalModel model;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget divider() => Container(height: 1, color: colors.background);
    Widget note(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Text(
        text,
        style: STextStyles.w500_12(context)
            .copyWith(color: colors.textSubtitle1),
      ),
    );
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      borderColor: colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in model.calls) ...[
            if (c.number > 1) divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(c.title, style: STextStyles.smallMed12(context)),
            ),
            for (final l in c.pays)
              _AssetRow(line: l, outgoing: true, isDesktop: isDesktop),
            for (final l in c.receives)
              _AssetRow(line: l, outgoing: false, isDesktop: isDesktop),
            if (!c.movesFunds) note("Moves no funds"),
            if (c.signs) note("Signs with your wallet's key"),
          ],
          divider(),
          _FeeRow(fee: model.fee),
        ],
      ),
    );
  }
}

/// A `sign_message` request: the message, the key, and what a signature
/// can and cannot do.
class _SignCard extends StatelessWidget {
  const _SignCard({required this.model});

  final DappApprovalModel model;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final key = model.request.sign?.keyMaterial ?? "";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DappMessage(
          dappName: model.dappName,
          message: model.message ?? "",
          label: "Message to sign, from ${model.dappName}",
        ),
        const SizedBox(height: 16),
        Text("Signing key", style: STextStyles.smallMed12(context)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                "Key id ${model.signKeyText}, chosen by ${model.dappName}",
                style: STextStyles.itemSubtitle12(context),
              ),
            ),
            SimpleCopyButton(data: key),
          ],
        ),
        const SizedBox(height: 12),
        RoundedContainer(
          color: colors.textFieldDefaultBG,
          child: Text(
            "A signature proves this wallet holds that key, for example to "
            "log in. It moves no funds and costs no fee. Sign only if you "
            "trust ${model.dappName} with that proof.",
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textDark3),
          ),
        ),
      ],
    );
  }
}

class _Recipient extends StatelessWidget {
  const _Recipient({required this.model});

  final DappApprovalModel model;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final send = model.request.send!;
    final notes = [
      model.recipientType!,
      if (send.isOnline)
        "Their wallet must come online within 12 hours, or the payment "
            "is cancelled",
    ].join(" · ");
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("Recipient", style: STextStyles.smallMed12(context)),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(
                dappShortHex(send.address, head: 10, tail: 8),
                style: STextStyles.itemSubtitle12(context),
              ),
            ),
            SimpleCopyButton(data: send.address),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          notes,
          style: STextStyles.w500_12(context)
              .copyWith(color: colors.textSubtitle1),
        ),
        if (send.isMine) ...[
          const SizedBox(height: 4),
          Text(
            "This is one of your own addresses.",
            style: STextStyles.w500_12(context)
                .copyWith(color: colors.textSubtitle1),
          ),
        ],
      ],
    );
  }
}

class _QueueNote extends StatelessWidget {
  const _QueueNote({required this.waiting, required this.isDesktop});

  final int waiting;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    if (waiting <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RoundedContainer(
        color: colors.textFieldDefaultBG,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          waiting == 1
              ? "1 more request waiting after this one"
              : "$waiting more requests waiting after this one",
          textAlign: TextAlign.center,
          style: STextStyles.w500_12(context).copyWith(color: colors.textDark3),
        ),
      ),
    );
  }
}
