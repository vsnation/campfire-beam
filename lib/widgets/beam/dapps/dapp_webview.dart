/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../wallets/beam/dapps/dapp_bridge_js.dart';
import '../../../wallets/beam/dapps/host/dapp_host_session.dart';

/// Whether this platform has the dApp window: `webview_flutter` implements
/// Android, iOS and macOS; on Linux and Windows (and in widget tests) no
/// implementation is registered.
bool dappWebviewAvailable() => WebViewPlatform.instance != null;

/// Where dApps open, for every "not on this computer" message.
const String dappWindowPlatformsSentence =
    "Campfire opens dApps on macOS, Android and iOS.";

/// What the dApp page needs of the window a dApp is shown in.
abstract interface class DappWebview {
  Widget widget();

  /// Loads the page again (a new page session, and the server's current
  /// CSP).
  Future<void> reload();
}

/// Makes the window for [session] and loads the dApp in it
/// ([DappWebviewGlue.create]; tests give their own).
typedef DappWebviewFactory = Future<DappWebview> Function({
  required DappHostSession session,
  required Color background,
  required void Function(Uri url) onExternalLink,
  void Function()? onLoaded,
  void Function(String description)? onLoadFailed,
});

/// Wires one [WebViewController] to a [DappHostSession]:
///
/// * the [dappBridgeChannelName] JavaScript channel → [DappHostSession]
///   (`DappBridge` → `DappSession`), and results back with `runJavaScript`;
/// * a user agent that selects the Qt bridge shape on desktop and iPad and
///   keeps the mobile shape on phones ([dappUserAgentFor]);
/// * navigation locked to the dApp's origin: anything else is refused, and
///   a main-frame link elsewhere is handed to [onExternalLink] (the page
///   asks before opening the system browser);
/// * camera, microphone and other permission requests denied;
/// * every main-frame load starting a fresh session ([onPageStarted]);
/// * the webview's own background before the page paints: `background`,
///   the dApp's page colour (`dappBackgroundColour`). macOS WKWebView does
///   not take it (webview_flutter_wkwebview leaves it unimplemented and
///   draws white), so the browser view keeps the webview covered until the
///   page has loaded; the page itself is painted by the server's host
///   stylesheet.
class DappWebviewGlue implements DappWebview {
  DappWebviewGlue._(this.controller, this.session);

  /// Creates the controller and loads the dApp. Only call when
  /// [dappWebviewAvailable].
  static Future<DappWebviewGlue> create({
    required DappHostSession session,
    required Color background,
    required void Function(Uri url) onExternalLink,
    void Function()? onLoaded,
    void Function(String description)? onLoadFailed,
  }) async {
    final controller = WebViewController(
      onPermissionRequest: (request) => unawaited(request.deny()),
    );
    final glue = DappWebviewGlue._(controller, session);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    try {
      // Not supported on every platform implementation; cosmetic only.
      await controller.setBackgroundColor(background);
    } catch (_) {}
    String? base;
    try {
      base = await controller.getUserAgent();
    } catch (_) {
      base = null;
    }
    await controller.setUserAgent(dappUserAgentFor(base).userAgent);
    await controller.addJavaScriptChannel(
      dappBridgeChannelName,
      onMessageReceived: (m) => unawaited(session.onMessage(m.message)),
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (session.isOwnUrl(request.url)) {
            return NavigationDecision.navigate;
          }
          final uri = Uri.tryParse(request.url);
          if (request.isMainFrame &&
              uri != null &&
              (uri.scheme == 'https' || uri.scheme == 'http')) {
            onExternalLink(uri);
          }
          return NavigationDecision.prevent;
        },
        onPageStarted: (url) =>
            session.pageStarted(url, controller.runJavaScript),
        onPageFinished: (_) => onLoaded?.call(),
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? false) {
            onLoadFailed?.call(error.description);
          }
        },
      ),
    );
    await controller.loadRequest(session.startUri);
    return glue;
  }

  final WebViewController controller;
  final DappHostSession session;

  @override
  Widget widget() => WebViewWidget(controller: controller);

  @override
  Future<void> reload() => controller.reload();
}
