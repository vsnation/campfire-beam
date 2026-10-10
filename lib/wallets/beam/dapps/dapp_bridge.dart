/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'dapp_bridge_js.dart';
import 'dapp_session.dart';

/// The native end of [dappBridgeChannelName] for one page load.
///
/// The webview host (B-DAPP-4) registers a JavaScript channel or handler
/// named [dappBridgeChannelName] on the dApp's webview, passes every
/// message it receives to [onMessage], and provides [evaluate] to run
/// JavaScript in the page's main frame. Reloading or leaving the page
/// ends the bridge: [close] it, close its session, and make a new pair
/// with a new token.
class DappBridge {
  DappBridge({
    required this.session,
    required this.token,
    required this.evaluate,
    this.onBlocked,
  }) {
    _notifications = session.notifications.listen(
      (n) => unawaited(_run(deliverScript(n))),
    );
  }

  final DappSession session;

  /// The page's bridge token, also given to the server for the script.
  final String token;

  /// Runs JavaScript in the dApp page.
  final Future<void> Function(String javascript) evaluate;

  /// The page reported a request its CSP refused: [origin] is what the
  /// page says, checked only for shape here (the host session decides
  /// whether to ask about it).
  final void Function(String origin)? onBlocked;

  late final StreamSubscription<String> _notifications;
  bool _closed = false;

  /// Larger messages are dropped (the session's own request limit is
  /// smaller; this bounds JSON parsing of the envelope).
  static const maxMessageLength = 16 * 1024 * 1024;

  static final _rng = Random.secure();

  /// A fresh 128-bit hex token.
  static String newToken() => [
    for (var i = 0; i < 16; i++)
      _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// The script that hands a result or event JSON string to the page.
  static String deliverScript(String json) =>
      'window.__campfireBeam&&window.__campfireBeam.deliver('
      '${dappJsString(json)});';

  /// The script that completes (or refuses) a web-extension handshake.
  static String handshakeScript(bool ok) =>
      'window.__campfireBeam&&window.__campfireBeam.handshake($ok);';

  /// Handles one message the page posted. Messages that are malformed or
  /// carry the wrong token are dropped without an answer.
  Future<void> onMessage(String raw) async {
    if (_closed || raw.length > maxMessageLength) return;
    final Object? msg;
    try {
      msg = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (msg is! Map<String, Object?> ||
        msg['v'] != 1 ||
        !_sameToken(msg['token'])) {
      return;
    }
    switch (msg['type']) {
      case 'rpc':
        final payload = msg['payload'];
        if (payload is! String) return;
        final response = await session.handle(payload);
        await _run(deliverScript(response));
      case 'hello':
        final h = msg['payload'];
        if (h is! Map<String, Object?>) return;
        final ok = session.handshake(
          apiver: h['apiver'] is String ? h['apiver']! as String : null,
          apivermin: h['apivermin'] is String
              ? h['apivermin']! as String
              : null,
        );
        await _run(handshakeScript(ok));
      case 'blocked':
        final b = msg['payload'];
        if (b is! Map<String, Object?>) return;
        final origin = b['origin'];
        final directive = b['directive'];
        if (origin is! String ||
            origin.length > 300 ||
            (directive != 'connect-src' && directive != 'img-src')) {
          return;
        }
        onBlocked?.call(origin);
    }
  }

  Future<void> _run(String js) async {
    if (_closed) return;
    try {
      await evaluate(js);
    } catch (_) {
      // The page is gone or navigating; nothing to deliver to.
    }
  }

  bool _sameToken(Object? given) {
    if (given is! String || given.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= given.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> close() async {
    _closed = true;
    await _notifications.cancel();
  }
}
