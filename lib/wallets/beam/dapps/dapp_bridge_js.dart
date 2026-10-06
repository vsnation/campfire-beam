/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

/// The script every dApp page gets before its own scripts run: the three
/// wallet shapes BEAM dApps look for (research/04 §3.5, §7.3), all talking
/// to one native channel.
///
/// A dApp picks its shape from the user agent alone (`utils.js`,
/// `BeamDappConnector.js`):
///
/// * **mobile** (`Android`, `iPhone` in the UA): `window.BEAM` with
///   `callWalletApi(json)`; results come back through the callback given to
///   `callWalletApiResult(fn)` (iOS) or, when none was given, as a
///   `document` `onCallWalletApiResult` event with the JSON in `detail`
///   (Android).
/// * **Qt** (`QtWebEngine` in the UA): a `QWebChannel` stand-in whose
///   `objects.BEAM.api` has `callWalletApi(json)` and a
///   `callWalletApiResult` signal with `connect`/`disconnect`. Pages load
///   `qrc:///qtwebchannel/qwebchannel.js` first; a script `src` set to it
///   is pointed at a same-origin empty file instead (the server rewrites
///   static tags).
/// * **web extension** (anything else): the page posts
///   `{type: 'create_beam_api', apiver, apivermin, appname}`; the wallet
///   negotiates the version, then this script defines `window.BeamApi`
///   (`callWalletApi(id, method, params)`, `callWalletApiResult(fn)`) and
///   posts `'apiInjected'`, or posts `'rejected'`.
///
/// Every request leaves through `post()` as `{v, token, type, payload}`:
/// `type` `rpc` with the JSON-RPC request string, or `hello` with the
/// handshake. The wallet answers by evaluating
/// `window.__campfireBeam.deliver(json)` or `.handshake(ok)`. The token is
/// per page load; a message without it is dropped, so a page from another
/// origin that ends up in the same webview cannot speak for the dApp.
///
/// The page can overwrite anything defined here; that only breaks the page
/// itself. Nothing here can execute a wallet call: every request is gated
/// in Dart (`DappSession`).
///
/// Which shape to give a page is the webview host's choice, made with the
/// user agent ([DappBridgeShape]). Measured 2026-10-06 by loading each of
/// the 9 bundled packages, unmodified, from `DappServer` in headless
/// Chrome 154 with this script and a native channel wired to `DappBridge`
/// (`test/beam/dapps/bundled_dapps_chrome_test.dart`):
///
/// * Qt shape: 9 of 9 connect and call `invoke_contract`.
/// * Mobile shape (Android UA): 9 of 9.
/// * Web-extension shape: 6 of 9. `dex-app`, `accum-dapp` and
///   `nft-marketplace` treat a top-level page (not in an iframe) as
///   "headless" and start their own wasm wallet instead, which needs
///   `SharedArrayBuffer` and a remote node; they never post
///   `create_beam_api`.
///
/// So desktop hosts should use [DappBridgeShape.qt], not the web-extension
/// default research/04 §7.3 proposed.
const String dappBridgeChannelName = 'CampfireBeam';

/// The wallet shape a page is offered, chosen by its user agent.
enum DappBridgeShape {
  /// Append [qtUserAgentToken] to the webview's user agent.
  qt,

  /// Keep a mobile user agent (`Android`, `iPhone`).
  mobile,

  /// Any other user agent: the `create_beam_api` handshake.
  web;

  /// What a dApp looks for to pick the Qt shape (`/QtWebEngine/i`).
  static const qtUserAgentToken = 'QtWebEngine/6.11.1';
}

/// Where a static `<script src="qrc:///qtwebchannel/qwebchannel.js">` is
/// pointed by the server. Served empty: the bridge already defines
/// `QWebChannel`.
const String dappQwebchannelShimPath = '/__campfire/qwebchannel.js';

const String _template = r'''
(function () {
  'use strict';
  if (window.__campfireBeam) return;
  var TOKEN = __CAMPFIRE_TOKEN__;
  var STYLE = __CAMPFIRE_STYLE__;
  var CHANNEL = __CAMPFIRE_CHANNEL__;
  var QRC = 'qrc:///qtwebchannel/qwebchannel.js';
  var QRC_SHIM = __CAMPFIRE_QRC_SHIM__;

  function post(type, payload) {
    var msg = JSON.stringify(
        {v: 1, token: TOKEN, type: type, payload: payload});
    var w = window;
    if (w.flutter_inappwebview &&
        typeof w.flutter_inappwebview.callHandler === 'function') {
      w.flutter_inappwebview.callHandler(CHANNEL, msg);
    } else if (w[CHANNEL] && typeof w[CHANNEL].postMessage === 'function') {
      w[CHANNEL].postMessage(msg);
    } else if (w.webkit && w.webkit.messageHandlers &&
        w.webkit.messageHandlers[CHANNEL]) {
      w.webkit.messageHandlers[CHANNEL].postMessage(msg);
    } else if (w.chrome && w.chrome.webview &&
        typeof w.chrome.webview.postMessage === 'function') {
      w.chrome.webview.postMessage(msg);
    }
  }

  function request(json) {
    post('rpc', typeof json === 'string' ? json : JSON.stringify(json));
  }

  // Results: one channel per page, never two.
  var callback = null;
  var qtListeners = [];
  function deliver(json) {
    if (qtListeners.length) {
      qtListeners.slice().forEach(function (f) { f(json); });
    } else if (callback) {
      callback(json);
    } else {
      document.dispatchEvent(
          new CustomEvent('onCallWalletApiResult', {detail: json}));
    }
  }

  // Mobile shape.
  window.BEAM = {
    style: STYLE,
    callWalletApi: request,
    callWalletApiResult: function (f) { callback = f; }
  };

  // Qt shape.
  var qtApi = {
    callWalletApi: request,
    callWalletApiResult: {
      connect: function (f) {
        if (qtListeners.indexOf(f) < 0) qtListeners.push(f);
      },
      disconnect: function (f) {
        var i = qtListeners.indexOf(f);
        if (i >= 0) qtListeners.splice(i, 1);
      }
    }
  };
  if (!window.qt) window.qt = {webChannelTransport: {}};
  window.QWebChannel = function (transport, init) {
    var channel = this;
    channel.objects = {BEAM: {style: STYLE, api: qtApi}};
    setTimeout(function () {
      if (typeof init === 'function') init(channel);
    }, 0);
  };
  var src = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
  if (src && src.set && src.configurable) {
    Object.defineProperty(HTMLScriptElement.prototype, 'src', {
      configurable: true,
      enumerable: src.enumerable,
      get: function () { return src.get.call(this); },
      set: function (v) {
        src.set.call(this, String(v) === QRC ? QRC_SHIM : v);
      }
    });
  }

  // Web-extension shape.
  window.addEventListener('message', function (ev) {
    var d = ev.data;
    if (ev.source !== window || !d || typeof d !== 'object' ||
        d.type !== 'create_beam_api') return;
    post('hello', {
      apiver: typeof d.apiver === 'string' ? d.apiver : null,
      apivermin: typeof d.apivermin === 'string' ? d.apivermin : null,
      appname: typeof d.appname === 'string' ? d.appname : null
    });
  });
  function handshake(ok) {
    if (ok) {
      window.BeamApi = {
        callWalletApi: function (id, method, params) {
          request({jsonrpc: '2.0', id: id, method: method, params: params});
        },
        callWalletApiResult: function (f) {
          callback = f;
          return Promise.resolve();
        }
      };
    }
    window.postMessage(ok ? 'apiInjected' : 'rejected', window.origin);
  }

  Object.defineProperty(window, '__campfireBeam', {
    value: Object.freeze({deliver: deliver, handshake: handshake}),
    writable: false,
    configurable: false,
    enumerable: false
  });
})();
''';

/// The bridge script for one page load.
///
/// [token] must be the page's bridge token (`DappBridge.newToken`).
/// [style] is the `BEAM.style` object dApps colour themselves from:
/// `content_main`, `background_main`, `background_main_top`,
/// `background_popup`, `validator_error`, `navigation_background` (CSS
/// colours) and `appsGradientOffset`, `appsGradientTop` (ints); see
/// [dappDefaultStyle].
String dappBridgeScript({
  required String token,
  Map<String, Object> style = dappDefaultStyle,
}) {
  if (!RegExp(r'^[0-9a-f]{32,64}$').hasMatch(token)) {
    throw ArgumentError.value(token, 'token', 'hex token expected');
  }
  for (final v in style.values) {
    if (v is! String && v is! int) {
      throw ArgumentError.value(style, 'style', 'strings and ints only');
    }
  }
  return _template
      .replaceFirst('__CAMPFIRE_TOKEN__', jsonEncode(token))
      .replaceFirst('__CAMPFIRE_STYLE__', _jsLiteral(jsonEncode(style)))
      .replaceFirst('__CAMPFIRE_CHANNEL__', jsonEncode(dappBridgeChannelName))
      .replaceFirst(
        '__CAMPFIRE_QRC_SHIM__',
        jsonEncode(dappQwebchannelShimPath),
      );
}

/// The Qt wallet's mainnet palette (`ui/view/color_themes/Mainnet.qml:6-49`)
/// under the keys dApps read. The UI should pass Campfire's theme colours
/// with the same keys.
const Map<String, Object> dappDefaultStyle = {
  'content_main': '#ffffff',
  'background_main': '#042548',
  'background_main_top': '#035b8f',
  'background_popup': '#00446c',
  'validator_error': '#ff625c',
  'navigation_background': '#000000',
  'appsGradientOffset': -95,
  'appsGradientTop': 135,
};

/// JSON is valid JavaScript except for U+2028/U+2029 in strings on engines
/// older than ES2019; escape them anyway.
String _jsLiteral(String json) => json
    .replaceAll(String.fromCharCode(0x2028), '${r'\'}u2028')
    .replaceAll(String.fromCharCode(0x2029), '${r'\'}u2029');

/// A JavaScript expression evaluating to [text] as a string.
String dappJsString(String text) => _jsLiteral(jsonEncode(text));
