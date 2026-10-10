/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../rpc/beam_transport.dart';
import '../dapp_bridge.dart';
import '../dapp_bridge_js.dart';
import '../dapp_catalogue.dart';
import '../dapp_consent.dart';
import '../dapp_identity.dart';
import '../dapp_installer.dart';
import '../dapp_remote_origins.dart';
import '../dapp_scope.dart';
import '../dapp_server.dart';
import '../dapp_session.dart';
import 'dapp_wallet_link.dart';

/// One open dApp: its loopback server, and the session + bridge of the page
/// currently loaded in the webview.
///
/// The webview glue calls [pageStarted] for every main-frame load and hands
/// every channel message to [onMessage]. Each page load gets a new
/// [DappSession] (so a reload drops the previous page's pending approvals,
/// which answer -32021, as the Qt wallet does) on a new transport from the
/// wallet.
///
/// A dApp installed from a file starts with no servers to reach (its CSP
/// allows eval and inline scripts, [DappCsp.fromFile]). When its page
/// reports a request the CSP refused, [onAskToReach] is told the origin,
/// once per open dApp; the person's answer comes back as [allowOrigin],
/// which saves it with the dApp and gives the server the wider policy for
/// the next page load. Bundled dApps are never asked about: their servers
/// are the catalogue's.
///
/// The bridge token is per open dApp, not per page load: the server bakes
/// it into the bridge script it serves for its whole life, and a webview
/// cannot be stopped before a reload's HTML request on every platform, so
/// a fresh token could not reach the reloaded page. The token still keeps
/// out any page from another origin (navigation is locked to [origin], and
/// only this origin serves the script).
class DappHostSession {
  DappHostSession._({
    required this.installation,
    required this.installer,
    required this.wallet,
    required this.consent,
    required this.server,
    required this.identity,
    required this.bundled,
    required this._token,
    required this._allowed,
    required this._reachable,
    required this._savedReachable,
    this.onActivity,
    this.onAskToReach,
    this.scopeStore,
  });

  /// Starts the dApp's server on its saved port (so its origin, and with it
  /// its browser storage, stays the same between visits).
  ///
  /// [allowRemoteOrigins]: let a bundled dApp fetch from the https origins
  /// the catalogue lists for it (price and bridge-fee APIs). The webview's
  /// own traffic does not go through Campfire's Tor proxy, so callers pass
  /// false while Tor is on: those hosts would see the user's IP address.
  /// A dApp from a file reaches the servers the person allowed for it,
  /// each asked by name. With [allowRemoteOrigins] false (Tor on) it starts
  /// with none of them: a server allowed while Tor was off is reached only
  /// after the person allows it again, asked with the Tor warning.
  static Future<DappHostSession> start({
    required DappInstallation installation,
    required DappInstaller installer,
    required DappWalletLink wallet,
    required DappConsentQueue consent,
    bool allowRemoteOrigins = false,
    Map<String, Object> style = dappDefaultStyle,
    void Function(DappActivity activity)? onActivity,
    void Function(String origin)? onAskToReach,
    DappScopeStore? scopeStore,
    @visibleForTesting
    List<DappCatalogueEntry> catalogue = dappBundledCatalogue,
  }) async {
    final token = DappBridge.newToken();
    final bundled = bundledEntryFor(installation, catalogue: catalogue);
    final allowed = bundled == null
        ? await installer.allowedOrigins(installation.guid)
        : const <String>[];
    final reachable = bundled != null || allowRemoteOrigins
        ? allowed
        : const <String>[];
    final csp = bundled == null
        ? DappCsp.fromFile(reachable)
        : DappCsp(
            allowEval: bundled.needsEval,
            remoteOrigins: allowRemoteOrigins
                ? bundled.remoteOrigins
                : const [],
          );
    final server = await DappServer.start(
      installation,
      bridgeToken: token,
      style: style,
      csp: csp,
      preferredPort: await installer.savedPort(installation.guid),
      // Another dApp's origin would give this one its browser storage.
      avoidPorts: await installer.portsOfOtherDapps(installation.guid),
    );
    try {
      await installer.savePort(installation.guid, server.port);
    } catch (_) {
      // The next visit gets a new origin; nothing else depends on it.
    }
    return DappHostSession._(
      installation: installation,
      installer: installer,
      wallet: wallet,
      consent: consent,
      server: server,
      identity: DappIdentity.fromManifest(
        installation.manifest,
        server.origin,
        checkedByCampfire: bundled != null,
      ),
      bundled: bundled,
      token: token,
      allowed: allowed,
      reachable: reachable,
      savedReachable: allowRemoteOrigins,
      onActivity: onActivity,
      onAskToReach: onAskToReach,
      scopeStore: scopeStore,
    );
  }

  /// The catalogue entry [installation] was installed from, byte for byte;
  /// null for any other package (including a modified bundled one).
  static DappCatalogueEntry? bundledEntryFor(
    DappInstallation installation, {
    List<DappCatalogueEntry> catalogue = dappBundledCatalogue,
  }) {
    for (final e in catalogue) {
      if (e.guid == installation.guid &&
          e.sha256 == installation.packageSha256) {
        return e;
      }
    }
    return null;
  }

  final DappInstallation installation;
  final DappInstaller installer;
  final DappWalletLink wallet;
  final DappConsentQueue consent;
  final DappServer server;
  final DappIdentity identity;
  final DappCatalogueEntry? bundled;
  final void Function(DappActivity activity)? onActivity;

  /// A dApp from a file tried to reach [origin] (an https origin
  /// [dappRemoteOriginFor] accepts, not allowed yet): ask the person.
  final void Function(String origin)? onAskToReach;

  /// Calls the open page has made to the wallet that have not answered yet.
  final ValueNotifier<int> callsInFlight = ValueNotifier(0);
  final DappScopeStore? scopeStore;
  final String _token;

  _Page? _page;
  bool _closed = false;
  List<String> _allowed;

  /// What the page may reach now: [_allowed], or with Tor on only what the
  /// person allowed while this dApp is open (see [start]).
  List<String> _reachable;

  /// False while Tor is on: saved servers are not reached until allowed again.
  final bool _savedReachable;

  /// Origins offered to [onAskToReach] while this dApp is open: each is
  /// asked about once ("Not now" lasts until the dApp is closed).
  final _offered = <String>{};

  /// Installed from a file (not a bundled package byte for byte).
  bool get fromFile => bundled == null;

  /// The servers saved for this dApp from a file (what More lists, and may
  /// take back); empty for a bundled one. With Tor on, the page reaches only
  /// those allowed again while it is open.
  List<String> get allowedOrigins => List.unmodifiable(_allowed);

  String get origin => server.origin;
  Uri get startUri => server.startUri;
  bool get isClosed => _closed;

  /// The session of the page loaded now, if any.
  DappSession? get currentSession => _page?.session;

  /// True for a URL on the dApp's own origin.
  bool isOwnUrl(String url) {
    final u = Uri.tryParse(url);
    return u != null &&
        u.scheme == 'http' &&
        u.host == '127.0.0.1' &&
        u.port == server.port;
  }

  /// A main-frame load of [url] started. [evaluate] runs JavaScript in the
  /// webview's main frame.
  ///
  /// Synchronous on purpose: the new page's messages may arrive right after
  /// this returns, and must find its session.
  void pageStarted(String url, Future<void> Function(String js) evaluate) {
    final old = _page;
    _page = null;
    if (old != null) unawaited(old.close());
    if (_closed || !isOwnUrl(url)) return;
    final transport = wallet.dappTransport(identity);
    final session = DappSession(
      identity: identity,
      apiVersion: installation.apiVersion,
      transport: transport,
      consent: consent,
      scopeStore:
          scopeStore ??
          FileDappScopeStore(installer.dataDirectory(installation.guid)),
      onActivity: onActivity,
      onCallBusy: (d) =>
          callsInFlight.value = (callsInFlight.value + d).clamp(0, 1 << 20),
    );
    _page = _Page(
      transport,
      session,
      DappBridge(
        session: session,
        token: _token,
        evaluate: evaluate,
        onBlocked: _blocked,
      ),
    );
  }

  void _blocked(String origin) {
    if (_closed || !fromFile || dappRemoteOriginFor(origin) != origin) return;
    if (_reachable.contains(origin) || _offered.contains(origin)) return;
    if (_offered.length >= dappMaxFileOrigins) return;
    _offered.add(origin);
    onAskToReach?.call(origin);
  }

  /// The person let this dApp reach [origin]: it is saved with the dApp,
  /// and the next page load has it. Reload the page. Throws when it could
  /// not be saved (the dApp may then ask about it again).
  Future<void> allowOrigin(String origin) async {
    if (!fromFile) throw StateError('a bundled dApp keeps its servers');
    try {
      _allowed = await installer.allowOrigin(installation.guid, origin);
      _reachable = _savedReachable
          ? _allowed
          : [..._reachable.where((o) => o != origin), origin];
      server.csp = DappCsp.fromFile(_reachable);
    } catch (_) {
      _offered.remove(origin);
      rethrow;
    }
  }

  /// This dApp may no longer reach [origin], from its next page load on
  /// (reload the page). It may ask about it again.
  Future<void> revokeOrigin(String origin) async {
    if (!fromFile) throw StateError('a bundled dApp keeps its servers');
    _allowed = await installer.revokeOrigin(installation.guid, origin);
    _reachable = [..._reachable.where((o) => o != origin)];
    server.csp = DappCsp.fromFile(_reachable);
    _offered.remove(origin);
  }

  /// One message from the webview's [dappBridgeChannelName] channel.
  Future<void> onMessage(String raw) async {
    final page = _page;
    if (page == null || _closed) return;
    await page.bridge.onMessage(raw);
  }

  /// Ends the page and the server. Pending approvals answer -32021.
  Future<void> close() async {
    callsInFlight.value = 0;
    if (_closed) return;
    _closed = true;
    final page = _page;
    _page = null;
    await page?.close();
    await server.close();
  }
}

class _Page {
  _Page(this.transport, this.session, this.bridge);

  final BeamTransport transport;
  final DappSession session;
  final DappBridge bridge;

  Future<void> close() async {
    await bridge.close();
    await session.close();
    await transport.close();
  }
}

/// The user agent to load a dApp with, and the bridge shape it selects
/// (`dapp_bridge_js.dart`): a mobile user agent (`Android`, `iPhone`) keeps
/// the mobile shape; anything else (macOS, and iPad, whose WKWebView sends a
/// desktop "Macintosh" agent) gets the Qt token, which all 9 bundled dApps
/// connect through (ARCHITECTURE §5a).
({String userAgent, DappBridgeShape shape}) dappUserAgentFor(String? base) {
  final ua = (base ?? '').trim();
  if (RegExp('android|iphone', caseSensitive: false).hasMatch(ua)) {
    return (userAgent: ua, shape: DappBridgeShape.mobile);
  }
  if (RegExp('qtwebengine', caseSensitive: false).hasMatch(ua)) {
    return (userAgent: ua, shape: DappBridgeShape.qt);
  }
  final start = ua.isEmpty ? 'Mozilla/5.0' : ua;
  return (
    userAgent: '$start ${DappBridgeShape.qtUserAgentToken}',
    shape: DappBridgeShape.qt,
  );
}
