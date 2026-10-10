/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec:
// 1. Job: use one dApp. Anything that would move money comes back to
//    Campfire's approval sheet first.
// 2. Primary CTA: the dApp's own page; Campfire adds one only when the dApp
//    asks for approval ("Review" on the banner, then the sheet's outcome
//    button).
// 3. Taps from app open: wallet → dApps → Open = 3.
//
// Exit-intent — what would make an impatient person close the app:
// * A wallet popup out of nowhere: every request first shows a banner. If
//   the user just tapped the page (the request is probably theirs) the
//   banner opens the review after a short visible delay; otherwise it waits
//   for "Review". The page never decides when the sheet appears.
// * A request Campfire refuses: says so, and that nothing was sent.
// * A blank page while it loads: "Opening <dApp>…" with progress.
// * A dApp that cannot load because the wallet is still connecting or
//   catching up: one plain line above it says so, what happens next ("goes
//   away by itself", how long), and it does go by itself, following the
//   wallet's own sync state. "Try again" only when waiting may not be
//   enough (no network, the wallet stopped updating).
// * A white or pink page behind the dApp: dApps are drawn for the BEAM
//   wallet's dark-blue page (white text on it), so the whole dApp area —
//   while it loads, behind the page, and the page itself (the server's host
//   stylesheet) — is that background, never Campfire's.
// * A platform without the dApp window: says so, and offers the way back.
// * A link that silently leaves the wallet: links to other sites ask first,
//   then open in the system browser.
// * A dApp from a file that silently can't load its data: when its page is
//   refused a server, Campfire asks once per server whether it may connect
//   (Allow reloads it), and More (⋯) lists the servers it may reach, each
//   with Remove access.

import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../../../wallets/beam/dapps/dapp_remote_origins.dart';
import '../../../wallets/beam/dapps/dapp_session.dart';
import '../../../wallets/beam/dapps/host/dapp_approval_model.dart';
import '../../../wallets/beam/dapps/host/dapp_host.dart';
import '../../../wallets/beam/dapps/host/dapp_host_session.dart';
import '../../../wallets/beam/dapps/host/dapp_wallet_link.dart';
import '../../../wallets/beam/price/beam_fiat_price.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../widgets/background.dart';
import '../../../widgets/beam/dapps/dapp_approval_banner.dart';
import '../../../widgets/beam/dapps/dapp_approval_sheet.dart';
import '../../../widgets/beam/dapps/dapp_network_sheets.dart';
import '../../../widgets/beam/dapps/dapp_surface.dart';
import '../../../widgets/beam/dapps/dapp_tap_tracker.dart';
import '../../../widgets/beam/dapps/dapp_webview.dart';
import '../../../widgets/conditional_parent.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
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
    this.webviewFactory,
    this.torOn,
  });

  static const String routeName = "/beamDappBrowser";

  /// More (⋯) in the title bar of a dApp installed from a file.
  static const moreKey = Key('dappMore');

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

  /// Overrides the dApp window (tests); [DappWebviewGlue.create] otherwise.
  final DappWebviewFactory? webviewFactory;

  /// Overrides whether Tor is on (tests).
  final bool? torOn;

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
  DappWebview? _glue;
  bool _loading = true;
  String? _failure;
  final _taps = DappTapTracker();
  _PendingBanner? _banner;
  bool _disposed = false;
  DateTime? _lastRefusalNotice;

  /// Why the wallet core cannot serve the dApp yet (catching up, still
  /// connecting…), said in one line above it: its calls wait on that core,
  /// so the dApp may sit on its own spinner with no word from Campfire.
  /// Follows the wallet's own sync and connection changes, so the line goes
  /// by itself once the wallet can answer.
  DappWalletWait? _walletWait;
  StreamSubscription<void>? _walletChanges;

  /// The "Opening…" cover goes after this long even if the page never
  /// reports it has finished loading (a stalled image, say): by then it has
  /// painted, and hiding a working page would be worse.
  static const _coverAtMost = Duration(seconds: 12);
  Timer? _coverTimer;

  /// Servers the page was refused, waiting to be asked about one at a
  /// time; the one on screen; and those answered "Not now", which stay
  /// unasked until the dApp is closed.
  final _asks = <String>[];
  String? _asking;
  final _declined = <String>{};

  bool get _desktop => widget.desktop ?? Util.isDesktop;
  bool get _available => widget.webviewAvailable ?? dappWebviewAvailable();
  String get _name => widget.installation.manifest.name;

  /// Installed from a file: it asks before reaching a server, and has More.
  bool get _fromFile =>
      DappHostSession.bundledEntryFor(widget.installation) == null;

  void _readWalletWait() {
    final wait = widget.host.wallet.walletWait;
    if (wait != _walletWait && mounted) setState(() => _walletWait = wait);
  }

  @override
  void initState() {
    super.initState();
    _walletWait = widget.host.wallet.walletWait;
    _walletChanges = widget.host.wallet.walletChanges.listen(
      (_) => _readWalletWait(),
    );
    if (_available) {
      widget.host.presenter.attach(_showApproval, fiat: _fiatPrice);
      unawaited(_start());
    }
  }

  @override
  void dispose() {
    unawaited(_walletChanges?.cancel());
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

  /// BEAM's price in the user's currency, for the approval's fiat values.
  BeamFiatPrice? _fiatPrice() {
    final id = widget.host.walletId;
    if (id == null || !mounted) return null;
    return ref.read(pBeamFiatPrice(id));
  }

  bool get _torOn {
    final forced = widget.torOn;
    if (forced != null) return forced;
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
        onAskToReach: _askToReach,
      );
      if (_disposed) {
        await session.close();
        return;
      }
      _session = session;
      if (!mounted) return;
      final glue = await (widget.webviewFactory ?? DappWebviewGlue.create)(
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
      _coverUntilLoaded();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = "Campfire couldn't start $_name.";
        });
      }
    }
  }

  void _coverUntilLoaded() {
    _coverTimer?.cancel();
    _coverTimer = Timer(_coverAtMost, () {
      if (mounted && _loading) setState(() => _loading = false);
    });
  }

  /// Loads the page again, behind the "Opening…" cover, with the server's
  /// current CSP; starts over when there is no page.
  Future<void> _reload() async {
    if (!_available || !mounted) return;
    final glue = _glue;
    if (glue == null) return _restart();
    setState(() => _loading = true);
    _coverUntilLoaded();
    try {
      await glue.reload();
    } catch (_) {
      if (mounted) await _restart();
    }
  }

  // ------------------------------------------------------ servers it reaches

  void _askToReach(String origin) {
    if (!mounted || _declined.contains(origin) || _asks.contains(origin)) {
      return;
    }
    _asks.add(origin);
    unawaited(_askNext());
  }

  /// One prompt at a time, in the order the page was refused.
  Future<void> _askNext() async {
    if (_asking != null || _asks.isEmpty || !mounted) return;
    final origin = _asks.removeAt(0);
    _asking = origin;
    final host = dappOriginHost(origin);
    final bool allow;
    try {
      allow = await showDappReachPrompt(
        context,
        name: _name,
        origin: origin,
        desktop: _desktop,
        torOn: _torOn,
      );
    } finally {
      _asking = null;
    }
    if (!mounted) return;
    if (!allow) {
      _declined.add(origin);
      return _askNext();
    }
    final session = _session;
    try {
      if (session == null || session.isClosed) throw StateError('closed');
      await session.allowOrigin(origin);
    } catch (_) {
      if (mounted) {
        _notice(
          DappNetworkText.allowFailed(_name, host),
          type: FlushBarType.warning,
        );
      }
      return _askNext();
    }
    if (!mounted || !identical(session, _session)) return;
    _notice(DappNetworkText.allowed(_name, host), type: FlushBarType.success);
    await _reload();
    return _askNext();
  }

  Future<void> _showServers() async {
    final session = _session;
    List<String> origins;
    try {
      origins = session != null && !session.isClosed
          ? session.allowedOrigins
          : await (await widget.host.installer()).allowedOrigins(
              widget.installation.guid,
            );
    } catch (_) {
      origins = const [];
    }
    if (!mounted) return;
    final m = widget.installation.manifest;
    final choice = await showDappServersSheet(
      context,
      name: _name,
      meta: DappNetworkText.meta(version: m.version, publisher: m.publisher),
      origins: origins,
      desktop: _desktop,
    );
    if (choice == null || !mounted) return;
    final origin = choice.origin;
    if (origin == null) return _reload();
    try {
      final now = _session;
      if (now != null && !now.isClosed) {
        await now.revokeOrigin(origin);
      } else {
        await (await widget.host.installer()).revokeOrigin(
          widget.installation.guid,
          origin,
        );
      }
    } catch (_) {
      if (mounted) {
        _notice(
          DappNetworkText.revokeFailed(_name),
          type: FlushBarType.warning,
        );
      }
      return;
    }
    if (!mounted) return;
    _declined.remove(origin);
    _notice(DappNetworkText.revoked(_name, dappOriginHost(origin)));
    await _reload();
  }

  void _notice(String message, {FlushBarType type = FlushBarType.info}) =>
      unawaited(
        showFloatingFlushBar(
          type: type,
          message: message,
          context: context,
          duration: Duration(seconds: type == FlushBarType.warning ? 5 : 4),
        ),
      );

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
                Expanded(
                  child: Text(
                    _name,
                    style: STextStyles.desktopH3(context),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_fromFile) ...[
                  AppBarIconButton(
                    key: DappBrowserView.moreKey,
                    size: 32,
                    color: colors.textFieldDefaultBG,
                    shadows: const [],
                    semanticsLabel: DappNetworkText.more,
                    tooltip: DappNetworkText.more,
                    icon: Icon(
                      Icons.more_horiz,
                      size: 20,
                      color: colors.topNavIconPrimary,
                    ),
                    onPressed: () => unawaited(_showServers()),
                  ),
                  const SizedBox(width: 24),
                ],
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
              actions: [
                if (_fromFile)
                  IconButton(
                    key: DappBrowserView.moreKey,
                    tooltip: DappNetworkText.more,
                    icon: Icon(
                      Icons.more_horiz,
                      color: colors.topNavIconPrimary,
                    ),
                    onPressed: () => unawaited(_showServers()),
                  ),
              ],
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
        if (_session case final session?)
          _WalletBusyLine(calls: session.callsInFlight, name: _name),
        if (_walletWait case final wait?)
          _WalletWaitStrip(
            wait: wait,
            name: _name,
            desktop: desktop,
            onRetry: () => unawaited(widget.host.wallet.retryConnection()),
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

/// What the strip above a dApp says while the wallet core cannot serve it:
/// what is happening, what it means for the dApp, and what happens next.
abstract final class DappWalletWaitText {
  static String title(DappWalletWait wait, String name) => switch (wait.kind) {
    DappWalletWaitKind.connecting =>
      "Your wallet is still connecting — $name may not load until "
          "it's connected.",
    DappWalletWaitKind.catchingUp =>
      "Your wallet is catching up — $name may not load until it's done.",
    DappWalletWaitKind.unreachable =>
      "Your wallet can't reach the network — $name can't load until it "
          "does.",
    DappWalletWaitKind.stuck =>
      "Your wallet has stopped updating — $name may show old numbers.",
  };

  static String next(DappWalletWait wait) => switch (wait.kind) {
    DappWalletWaitKind.connecting =>
      'This goes away by itself, usually within a few seconds.',
    DappWalletWaitKind.catchingUp => switch (wait.timeLeft) {
      final left? =>
        '${_capitalized(BeamSyncMessages.approxDuration(left))} left. '
            "This goes away by itself when it's done.",
      null => "This goes away by itself when it's done.",
    },
    DappWalletWaitKind.unreachable =>
      'It keeps trying on its own, and this goes away once it connects.',
    DappWalletWaitKind.stuck =>
      "Your wallet's page says why and what to do. This goes away once it "
          'updates again.',
  };

  static const retry = 'Try again';

  static String _capitalized(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

/// The line above a dApp while the wallet core cannot serve it
/// ([DappWalletWaitText]). "Try again" only where waiting alone may not
/// fix it.
class _WalletWaitStrip extends StatelessWidget {
  const _WalletWaitStrip({
    required this.wait,
    required this.name,
    required this.desktop,
    required this.onRetry,
  });

  final DappWalletWait wait;
  final String name;
  final bool desktop;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final retry =
        wait.kind == DappWalletWaitKind.unreachable ||
        wait.kind == DappWalletWaitKind.stuck;
    final ink = colors.warningForeground;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('dappWalletNotReady'),
        color: colors.warningBackground,
        padding: EdgeInsets.fromLTRB(desktop ? 24 : 16, 10, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DappWalletWaitText.title(wait, name),
                    style: STextStyles.w600_14(context).copyWith(color: ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    DappWalletWaitText.next(wait),
                    style: STextStyles.w500_12(context).copyWith(color: ink),
                  ),
                ],
              ),
            ),
            if (retry) ...[
              const SizedBox(width: 12),
              CustomTextButton(
                key: const Key('dappWalletRetry'),
                text: DappWalletWaitText.retry,
                onTap: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A slim line under the header while the dApp has waited on the wallet for
/// more than [_after] (a contract read can take tens of seconds, the dApp's
/// page blank meanwhile). Short calls never show it, so it does not flicker
/// as the dApp polls.
class _WalletBusyLine extends StatefulWidget {
  const _WalletBusyLine({required this.calls, required this.name});

  final ValueListenable<int> calls;
  final String name;

  @override
  State<_WalletBusyLine> createState() => _WalletBusyLineState();
}

class _WalletBusyLineState extends State<_WalletBusyLine> {
  static const _after = Duration(milliseconds: 700);

  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    widget.calls.addListener(_changed);
    _changed();
  }

  void _changed() {
    final busy = widget.calls.value > 0;
    if (!busy) {
      _timer?.cancel();
      _timer = null;
      if (_shown && mounted) setState(() => _shown = false);
    } else if (!_shown && _timer == null) {
      _timer = Timer(_after, () {
        _timer = null;
        if (mounted && widget.calls.value > 0) setState(() => _shown = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.calls.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox(height: 2);
    return Semantics(
      label: '${widget.name} is waiting for your wallet',
      child: const SizedBox(
        key: Key('dappWalletBusy'),
        height: 2,
        child: LinearProgressIndicator(minHeight: 2),
      ),
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
