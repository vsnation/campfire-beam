/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6):
// 1. Job: use one dApp. Anything that would move money comes back to
//    Campfire's approval sheet first.
// 2. Primary CTA: the dApp's own page; Campfire adds one only when the dApp
//    asks for approval ("Review" on the banner, then the sheet's outcome
//    button).
// 3. Taps from app open: wallet → dApps → Open = 3.
//
// Exit-intent (§1.7) — what would make an impatient person close the app:
// * A wallet popup out of nowhere: every request first shows a banner. If
//   the user just tapped the page (the request is probably theirs) the
//   banner opens the review after a short visible delay; otherwise it waits
//   for "Review". The page never decides when the sheet appears.
// * A request Campfire refuses: says so, and that nothing was sent.
// * A blank page while it loads: "Opening <dApp>…" with progress.
// * A white or pink page behind the dApp: dApps are drawn for the BEAM
//   wallet's dark-blue page (white text on it), so the whole dApp area —
//   while it loads, behind the page, and the page itself (the server's host
//   stylesheet) — is that background, never Campfire's.
// * A platform without the dApp window: says so, and offers the way back.
// * A link that silently leaves the wallet: links to other sites ask first,
//   then open in the system browser.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/prefs.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/dapps/dapp_installer.dart';
import '../../../wallets/beam/dapps/dapp_session.dart';
import '../../../wallets/beam/dapps/host/dapp_approval_model.dart';
import '../../../wallets/beam/dapps/host/dapp_host.dart';
import '../../../wallets/beam/dapps/host/dapp_host_session.dart';
import '../../../widgets/background.dart';
import '../../../widgets/beam/dapps/dapp_approval_banner.dart';
import '../../../widgets/beam/dapps/dapp_approval_sheet.dart';
import '../../../widgets/beam/dapps/dapp_surface.dart';
import '../../../widgets/beam/dapps/dapp_tap_tracker.dart';
import '../../../widgets/beam/dapps/dapp_webview.dart';
import '../../../widgets/conditional_parent.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/desktop/secondary_button.dart';
import '../../../widgets/rounded_white_container.dart';
import '../../../widgets/stack_dialog.dart';

class DappBrowserView extends ConsumerStatefulWidget {
  const DappBrowserView({
    super.key,
    required this.host,
    required this.installation,
    this.desktop,
    this.webviewAvailable,
    this.authenticate,
  });

  static const String routeName = "/beamDappBrowser";

  /// A request that arrives within this long of the user's last tap on the
  /// page opens its review after [DappApprovalBanner.openDelay]; a later one
  /// waits for "Review". Taps only: scrolls and drags do not count.
  static const gestureWindow = Duration(seconds: 10);

  final DappHost host;
  final DappInstallation installation;

  /// Overrides `Util.isDesktop` (tests).
  final bool? desktop;

  /// Overrides the platform check for the dApp window (tests).
  final bool? webviewAvailable;

  /// Overrides Campfire's PIN / password check (tests).
  final DappApprovalAuthenticator? authenticate;

  @override
  ConsumerState<DappBrowserView> createState() => _DappBrowserViewState();
}

class _PendingBanner {
  _PendingBanner(this.model, {this.autoOpenAfter});

  final DappApprovalModel model;
  final Duration? autoOpenAfter;
  final answer = Completer<bool>();
}

class _DappBrowserViewState extends ConsumerState<DappBrowserView> {
  DappHostSession? _session;
  DappWebviewGlue? _glue;
  bool _loading = true;
  String? _failure;
  final _taps = DappTapTracker();
  _PendingBanner? _banner;
  bool _disposed = false;
  DateTime? _lastRefusalNotice;

  /// Why the wallet cannot act yet ("Catching up with the network…"), shown
  /// above the dApp: its calls wait on a core that is not up to date, so
  /// the dApp may sit on its own spinner with no word from Campfire.
  String? _walletNotReady;
  Timer? _readyPoll;

  /// How often [_walletNotReady] is read again.
  static const _readyPollInterval = Duration(seconds: 3);

  /// The "Opening…" cover goes after this long even if the page never
  /// reports it has finished loading (a stalled image, say): by then it has
  /// painted, and hiding a working page would be worse.
  static const _coverAtMost = Duration(seconds: 12);
  Timer? _coverTimer;

  bool get _desktop => widget.desktop ?? Util.isDesktop;
  bool get _available => widget.webviewAvailable ?? dappWebviewAvailable();
  String get _name => widget.installation.manifest.name;

  void _readWalletReady() {
    final reason = widget.host.wallet.spendBlockedReason;
    if (reason != _walletNotReady && mounted) {
      setState(() => _walletNotReady = reason);
    }
  }

  @override
  void initState() {
    super.initState();
    _walletNotReady = widget.host.wallet.spendBlockedReason;
    _readyPoll = Timer.periodic(_readyPollInterval, (_) => _readWalletReady());
    if (_available) {
      widget.host.presenter.attach(_showApproval);
      unawaited(_start());
    }
  }

  @override
  void dispose() {
    _readyPoll?.cancel();
    _coverTimer?.cancel();
    _disposed = true;
    widget.host.presenter.detach(_showApproval);
    final banner = _banner;
    if (banner != null && !banner.answer.isCompleted) {
      banner.answer.complete(false);
    }
    // Pending approvals of this dApp answer -32021.
    unawaited(_session?.close());
    super.dispose();
  }

  bool get _torOn {
    try {
      return Prefs.instance.useTor;
    } catch (_) {
      return true; // unknown: keep the dApp's traffic to itself
    }
  }

  Future<void> _start() async {
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final installer = await widget.host.installer();
      final session = await DappHostSession.start(
        installation: widget.installation,
        installer: installer,
        wallet: widget.host.wallet,
        consent: widget.host.consent,
        allowRemoteOrigins: !_torOn,
        onActivity: _onActivity,
      );
      if (_disposed) {
        await session.close();
        return;
      }
      _session = session;
      if (!mounted) return;
      final glue = await DappWebviewGlue.create(
        session: session,
        // What the page is drawn on, for platforms that honour it until
        // the page paints (Android, iOS); the cover below hides the rest.
        background: dappBackgroundColour(),
        onExternalLink: (uri) => unawaited(_offerExternal(uri)),
        onLoaded: () {
          if (mounted) setState(() => _loading = false);
        },
        onLoadFailed: (_) {
          if (mounted) {
            setState(() {
              _loading = false;
              _failure = "$_name didn't load.";
            });
          }
        },
      );
      if (mounted) setState(() => _glue = glue);
      _coverTimer?.cancel();
      _coverTimer = Timer(_coverAtMost, () {
        if (mounted && _loading) setState(() => _loading = false);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = "Campfire couldn't start $_name.";
        });
      }
    }
  }

  Future<void> _restart() async {
    final old = _session;
    _session = null;
    setState(() => _glue = null);
    await old?.close();
    if (mounted) await _start();
  }

  void _onActivity(DappActivity activity) {
    if (!mounted) return;
    if (activity.kind == DappActivityKind.refused) {
      // One notice every few seconds: a page must not be able to bury the
      // screen in them.
      final now = DateTime.now();
      final last = _lastRefusalNotice;
      if (last != null && now.difference(last) < const Duration(seconds: 4)) {
        return;
      }
      _lastRefusalNotice = now;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message:
              "${activity.dapp.name}: ${activity.detail ?? "Campfire "
                  "refused a request. Nothing was sent."}",
          context: context,
        ),
      );
      return;
    }
    final what = switch (activity.kind) {
      DappActivityKind.signedMessage =>
        "signed a message with a key from this wallet",
      DappActivityKind.sentMessage => "sent a message from this wallet",
      DappActivityKind.refused => "had a request refused",
    };
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.info,
        message: "${activity.dapp.name} $what",
        context: context,
      ),
    );
  }

  /// The presenter's UI: always the banner first, then the sheet. The
  /// banner opens the review by itself, after a visible delay, only when
  /// the user just tapped the page.
  Future<bool> _showApproval(DappApprovalModel model) async {
    if (!mounted || model.request.isCancelled) return false;
    final recent = _taps.tappedWithin(
      DappBrowserView.gestureWindow,
      DateTime.now(),
    );
    final banner = _PendingBanner(
      model,
      autoOpenAfter: recent ? DappApprovalBanner.openDelay : null,
    );
    setState(() => _banner = banner);
    unawaited(
      model.request.cancelled.then((_) {
        if (!banner.answer.isCompleted) banner.answer.complete(false);
      }),
    );
    final review = await banner.answer.future;
    if (mounted && identical(_banner, banner)) {
      setState(() => _banner = null);
    }
    if (!review || !mounted || model.request.isCancelled) return false;
    final ok = await showDappApprovalSheet(
      context,
      model,
      pending: widget.host.consent.pending,
      authenticate: widget.authenticate,
      desktop: _desktop,
    );
    if (ok && mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.success,
          message: model.isSignMessage
              ? "Approved. Campfire signed the message."
              : "Approved. Campfire is sending it to the network.",
          context: context,
        ),
      );
    }
    return ok;
  }

  Future<void> _offerExternal(Uri uri) async {
    if (!mounted) return;
    final ok = await _confirm(
      title: "Open this link in your browser?",
      message:
          "$_name wants to open ${uri.host}. It opens in your browser, "
          "outside Campfire.\n\n$uri",
      confirm: "Open in browser",
    );
    if (ok != true) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        unawaited(
          showFloatingFlushBar(
            type: FlushBarType.warning,
            message: "Campfire couldn't open your browser.",
            context: context,
          ),
        );
      }
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirm,
  }) {
    if (_desktop) {
      return showDialog<bool>(
        context: context,
        builder: (context) => DesktopDialog(
          maxWidth: 520,
          maxHeight: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: STextStyles.desktopH3(context)),
                const SizedBox(height: 16),
                SelectableText(
                  message,
                  style: STextStyles.desktopTextSmall(context),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryButton(
                        label: "Cancel",
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(false),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: PrimaryButton(
                        label: confirm,
                        buttonHeight: ButtonHeight.l,
                        onPressed: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    final colors = Theme.of(context).extension<StackColors>()!;
    return showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        title: title,
        message: message,
        leftButton: TextButton(
          style: colors.getSecondaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            "Cancel",
            style: STextStyles.button(context)
                .copyWith(color: colors.accentColorDark),
          ),
        ),
        rightButton: TextButton(
          style: colors.getPrimaryEnabledButtonStyle(context),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirm, style: STextStyles.button(context)),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop;
    final colors = Theme.of(context).extension<StackColors>()!;
    return ConditionalParent(
      condition: desktop,
      builder: (child) => DesktopScaffold(
        appBar: DesktopAppBar(
          isCompactHeight: true,
          useSpacers: false,
          background: colors.popupBG,
          leading: Expanded(
            child: Row(
              children: [
                const SizedBox(width: 32),
                AppBarIconButton(
                  size: 32,
                  color: colors.textFieldDefaultBG,
                  shadows: const [],
                  icon: SvgPicture.asset(
                    Assets.svg.arrowLeft,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      colors.topNavIconPrimary,
                      BlendMode.srcIn,
                    ),
                  ),
                  onPressed: Navigator.of(context).pop,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _name,
                    style: STextStyles.desktopH3(context),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        body: child,
      ),
      child: ConditionalParent(
        condition: !desktop,
        builder: (child) => Background(
          child: Scaffold(
            backgroundColor: colors.background,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              leading: AppBarBackButton(
                onPressed: () => Navigator.of(context).pop(),
              ),
              title: Text(
                _name,
                style: STextStyles.navBarTitle(context),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // The dApp's background reaches into the safe-area margins.
            body: ColoredBox(
              color: _showsDapp ? dappBackgroundColour() : colors.background,
              child: SafeArea(child: child),
            ),
          ),
        ),
        child: _body(context, desktop),
      ),
    );
  }

  /// True while the dApp area (not a Campfire message) fills the page.
  bool get _showsDapp => _available && _failure == null;

  Widget _body(BuildContext context, bool desktop) {
    final colors = Theme.of(context).extension<StackColors>()!;
    if (!_available) {
      return _Unavailable(name: _name, desktop: desktop);
    }
    final failure = _failure;
    if (failure != null) {
      return Padding(
        padding: EdgeInsets.all(desktop ? 24 : 16),
        child: _Message(
          title: failure,
          body:
              "Nothing was sent and nothing was changed. Try again; if it "
              "keeps happening, remove $_name and install it again.",
          action: PrimaryButton(
            label: "Try again",
            buttonHeight: desktop ? ButtonHeight.l : null,
            height: desktop ? null : 46,
            onPressed: () => unawaited(_restart()),
          ),
        ),
      );
    }
    final glue = _glue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_banner != null)
          DappApprovalBanner(
            // A new request gets a new banner (and a new countdown).
            key: ObjectKey(_banner),
            dappName: _banner!.model.dappName,
            isDesktop: desktop,
            autoOpenAfter: _banner!.autoOpenAfter,
            onAnswer: (v) {
              final b = _banner;
              if (b != null && !b.answer.isCompleted) b.answer.complete(v);
            },
          ),
        if (_walletNotReady != null)
          Container(
            key: const Key('dappWalletNotReady'),
            color: colors.warningBackground,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Text(
              'This app may not load or may show old numbers until your '
              'wallet is up to date. $_walletNotReady',
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.warningForeground),
            ),
          ),
        Expanded(
          child: DappSurface(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (glue != null)
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) =>
                        _taps.down(e.pointer, e.position, DateTime.now()),
                    onPointerUp: (e) =>
                        _taps.up(e.pointer, e.position, DateTime.now()),
                    onPointerCancel: (e) => _taps.cancel(e.pointer),
                    child: glue.widget(),
                  ),
                // Over the webview until the page has loaded: a webview
                // that has not painted yet is white on macOS whatever
                // colour it is given.
                if (_loading)
                  DappOpening(key: const Key('dappOpening'), name: _name),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.name, required this.desktop});

  final String name;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: EdgeInsets.all(desktop ? 24 : 16),
          child: _Message(
            title: "$name can't open on this computer yet",
            body:
                "$dappWindowPlatformsSentence On Linux and Windows the dApp "
                "window isn't available yet. $name stays installed for when "
                "it is, and your funds are not affected.",
            action: PrimaryButton(
              key: const Key("dappUnavailableBack"),
              label: "Back to dApps",
              buttonHeight: desktop ? ButtonHeight.l : null,
              height: desktop ? null : 46,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body, this.action});

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: STextStyles.pageTitleH2(context)
                .copyWith(color: colors.textDark),
          ),
          const SizedBox(height: 8),
          Text(body, style: STextStyles.smallMed14(context)),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
  }
}
