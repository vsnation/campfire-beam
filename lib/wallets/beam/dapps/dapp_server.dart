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
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'dapp_bridge_js.dart';
import 'dapp_errors.dart';
import 'dapp_installer.dart';
import 'dapp_manifest.dart';
import 'dapp_remote_origins.dart';

/// The Content-Security-Policy every response of a dApp carries.
///
/// Each allowance is there because a bundled mainnet package needs it
/// (checked by reading all 9 packages, 2026-10-06):
///
/// * `script-src 'self'`: the package's own scripts and the bridge. No
///   bundled package has an inline `<script>` or an inline event handler.
/// * `'unsafe-inline'` ([allowInline]): a dApp installed from a file only.
///   Single-file dApps are one inline script with inline handlers, and next
///   to `'unsafe-eval'` it gives a page nothing more.
/// * `'unsafe-eval'` ([allowEval]): 7 packages are webpack `devtool: eval`
///   builds (every module is an `eval("…")` string, 600 to 970 per
///   bundle) and the emscripten glue in 3 uses `new Function`; without it
///   they do not start. Only `dao-core-app` needs none. It gives a page
///   nothing its own scripts do not already have: the bridge is gated in
///   Dart either way.
/// * `style-src 'self' 'unsafe-inline'`: styled-components and emotion
///   inject `<style>` elements. Styles cannot run script.
/// * `img-src` / `media-src` `'self' data: blob:`: bundles and CSS carry
///   `data:` images.
/// * `font-src 'self' data:`: every package ships its own fonts.
/// * `connect-src 'self'`: a dApp fetches its own app shader
///   (`fetch('./app.wasm')`).
/// * [remoteOrigins], added to `connect-src` and `img-src`: named https
///   origins only ([dappRemoteOriginFor]), for the price and bridge-fee
///   APIs some packages call (see `dappBundledCatalogue`), or the servers
///   the person let a dApp from a file reach. None by default.
/// * `worker-src 'self'`: the wasm-client worker (headless mode only).
///
/// Everything else is `'none'`: no frames, plugins, `<base>`, form posts,
/// or framing of the dApp by anything.
@immutable
class DappCsp {
  const DappCsp({
    this.allowEval = true,
    this.allowInline = false,
    this.remoteOrigins = const [],
  });

  /// A dApp installed from a file: eval and inline scripts, and exactly the
  /// servers the person allowed for it.
  const DappCsp.fromFile(List<String> allowedOrigins)
    : this(allowInline: true, remoteOrigins: allowedOrigins);

  final bool allowEval;
  final bool allowInline;

  /// `https://host[:port]` origins the dApp may fetch from and load images
  /// from.
  final List<String> remoteOrigins;

  String get header {
    for (final o in remoteOrigins) {
      if (dappRemoteOriginFor(o) != o) {
        throw ArgumentError.value(o, 'remoteOrigins', 'https origin only');
      }
    }
    if (remoteOrigins.length > dappMaxFileOrigins ||
        remoteOrigins.toSet().length != remoteOrigins.length) {
      throw ArgumentError.value(
        remoteOrigins,
        'remoteOrigins',
        'too many or repeated origins',
      );
    }
    final remote = remoteOrigins.isEmpty ? '' : ' ${remoteOrigins.join(' ')}';
    final inline = allowInline ? " 'unsafe-inline'" : '';
    final eval = allowEval ? " 'unsafe-eval'" : '';
    return [
      "default-src 'none'",
      "script-src 'self'$inline$eval",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:$remote",
      "media-src 'self' data: blob:",
      "font-src 'self' data:",
      "connect-src 'self'$remote",
      "worker-src 'self'",
      "manifest-src 'self'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
      "frame-ancestors 'none'",
    ].join('; ');
  }
}

/// Serves one installed dApp on its own loopback origin.
///
/// * Bound to `127.0.0.1` only, on the dApp's saved port when free (so its
///   origin, and with it its browser storage, stays the same), else on a
///   random free one: one origin per dApp, unlike beam-ui's shared
///   `127.0.0.1:34700`.
/// * Read-only: GET and HEAD. Requests whose `Host` is not exactly this
///   origin are refused (no DNS rebinding).
/// * Only regular files inside the dApp's `files/` folder: each path
///   segment is checked with [DappPath], hidden files, directories (no
///   listings) and symlinks are refused, and the resolved path must stay
///   inside the folder.
/// * Every HTML page gets `<script src="/__campfire/<token>/bridge.js">`
///   as the first element of `<head>`, so the bridge exists before the
///   page's scripts even where the webview cannot inject at document start,
///   followed by `<link rel="stylesheet" href="/__campfire/<token>/host.css">`
///   ([dappHostStylesheet]: the background the Qt wallet shows dApps on,
///   before the page's own styles so those win); static
///   `qrc:///qtwebchannel/qwebchannel.js` references are pointed at an
///   empty same-origin file. Both are same-origin, so the CSP is unchanged.
/// * Every response carries [DappCsp] and `nosniff`, `no-referrer`,
///   same-origin resource and opener policies, `DENY` framing, a
///   Permissions-Policy denying camera, microphone and location, and
///   `no-store`.
class DappServer {
  DappServer._(
    this.installation,
    this._server,
    this._root,
    this._token,
    this._style,
    this._cspHeader,
    this.portChanged,
  );

  final DappInstallation installation;
  final HttpServer _server;
  final String _root;
  final String _token;
  final Map<String, Object> _style;
  String _cspHeader;

  /// Every response from now on carries [csp] (a dApp from a file was
  /// allowed, or no longer allowed, to reach a server); a page has it once
  /// it is reloaded. Throws [ArgumentError] for an origin [DappCsp] refuses,
  /// and then keeps the policy it had.
  set csp(DappCsp csp) => _cspHeader = csp.header;

  /// True when the saved port was taken and the dApp got a new one (its
  /// browser storage starts empty on the new origin).
  final bool portChanged;

  int get port => _server.port;
  String get origin => 'http://127.0.0.1:$port';

  /// The URL to open the dApp at.
  Uri get startUri =>
      Uri.parse('$origin/${_encodePath(installation.manifest.startPath)}');

  String get bridgePath => '/__campfire/$_token/bridge.js';

  /// The host stylesheet ([dappHostStylesheet]) every page links.
  String get stylesheetPath => '/__campfire/$_token/host.css';

  static Future<DappServer> start(
    DappInstallation installation, {
    required String bridgeToken,
    Map<String, Object> style = dappDefaultStyle,
    DappCsp csp = const DappCsp(),
    int? preferredPort,
    Set<int> avoidPorts = const {},
  }) async {
    final header = csp.header; // validates the origins
    dappBridgeScript(token: bridgeToken, style: style); // validates both
    dappHostStylesheet(style); // and the colours it paints
    final root = await Directory(installation.filesDirectory)
        .resolveSymbolicLinks();
    HttpServer? server;
    if (preferredPort != null && !avoidPorts.contains(preferredPort)) {
      try {
        server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          preferredPort,
        );
      } on SocketException {
        server = null;
      }
    }
    server ??= await _bindAvoiding(avoidPorts);
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..autoCompress = false
      ..serverHeader = null;
    server.defaultResponseHeaders.clear();
    final s = DappServer._(
      installation,
      server,
      root,
      bridgeToken,
      Map.unmodifiable(style),
      header,
      preferredPort != null && server.port != preferredPort,
    );
    server.listen((req) => unawaited(s._handle(req)));
    return s;
  }

  Future<void> close() => _server.close(force: true);

  /// A free loopback port that is none of [avoid] (other dApps' origins):
  /// ports the system offers from [avoid] stay held while the next is
  /// asked for, so it cannot offer them again.
  static Future<HttpServer> _bindAvoiding(Set<int> avoid) async {
    final held = <HttpServer>[];
    try {
      for (var i = 0; i < 64; i++) {
        final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        if (!avoid.contains(s.port)) return s;
        held.add(s);
      }
      throw const SocketException(
        "no free loopback port outside the other dApps' origins",
      );
    } finally {
      for (final s in held) {
        await s.close(force: true);
      }
    }
  }

  static const _permissions =
      'camera=(), microphone=(), geolocation=(), payment=(), usb=(), '
      'serial=(), bluetooth=(), hid=(), midi=(), display-capture=(), '
      'clipboard-read=()';

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      res.headers
        ..set('Content-Security-Policy', _cspHeader)
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('Cross-Origin-Resource-Policy', 'same-origin')
        ..set('Cross-Origin-Opener-Policy', 'same-origin')
        ..set('X-Frame-Options', 'DENY')
        ..set('Permissions-Policy', _permissions)
        ..set(HttpHeaders.cacheControlHeader, 'no-store');

      if (req.method != 'GET' && req.method != 'HEAD') {
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return await _status(res, HttpStatus.methodNotAllowed);
      }
      if (req.headers.value(HttpHeaders.hostHeader) != '127.0.0.1:$port') {
        return await _status(res, HttpStatus.forbidden);
      }

      final segments = req.uri.pathSegments;
      if (segments.isEmpty) {
        res.headers.set(
          HttpHeaders.locationHeader,
          '/${_encodePath(installation.manifest.startPath)}',
        );
        return await _status(res, HttpStatus.found);
      }
      if (segments.first == '__campfire') {
        return await _internal(req, res, segments);
      }
      try {
        for (final s in segments) {
          DappPath.checkSegment(s);
          if (s.startsWith('.')) return await _status(res, HttpStatus.notFound);
        }
      } on DappInstallException {
        return await _status(res, HttpStatus.notFound);
      }

      final path = p.joinAll([_root, ...segments]);
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        return await _status(res, HttpStatus.notFound);
      }
      final real = await File(path).resolveSymbolicLinks();
      if (!p.isWithin(_root, real)) {
        return await _status(res, HttpStatus.notFound);
      }

      final type = contentTypeFor(segments.last);
      res.headers.set(HttpHeaders.contentTypeHeader, type);
      if (type.startsWith('text/html')) {
        final body = injectBridge(
          await File(real).readAsBytes(),
          bridgePath,
          stylesheetPath: stylesheetPath,
        );
        res.contentLength = body.length;
        if (req.method == 'GET') res.add(body);
        return await res.close();
      }
      final file = File(real);
      res.contentLength = await file.length();
      if (req.method == 'GET') {
        await res.addStream(file.openRead());
      }
      await res.close();
    } catch (_) {
      try {
        await _status(res, HttpStatus.internalServerError);
      } catch (_) {
        // headers already sent; the connection is dropped
      }
    }
  }

  Future<void> _internal(
    HttpRequest req,
    HttpResponse res,
    List<String> segments,
  ) async {
    final String? body;
    var type = 'text/javascript; charset=utf-8';
    if (segments.length == 3 &&
        segments[1] == _token &&
        segments[2] == 'bridge.js') {
      body = dappBridgeScript(token: _token, style: _style);
    } else if (segments.length == 3 &&
        segments[1] == _token &&
        segments[2] == 'host.css') {
      body = dappHostStylesheet(_style);
      type = 'text/css; charset=utf-8';
    } else if ('/${segments.join('/')}' == dappQwebchannelShimPath) {
      body = '// QWebChannel is provided by the Campfire bridge.\n';
    } else {
      body = null;
    }
    if (body == null) return _status(res, HttpStatus.notFound);
    final bytes = utf8.encode(body);
    res.headers.set(HttpHeaders.contentTypeHeader, type);
    res.contentLength = bytes.length;
    if (req.method == 'GET') res.add(bytes);
    await res.close();
  }

  static Future<void> _status(HttpResponse res, int code) async {
    res
      ..statusCode = code
      ..contentLength = 0;
    await res.close();
  }

  static String _encodePath(String path) =>
      path.split('/').map(Uri.encodeComponent).join('/');

  /// Inserts the bridge `<script>` (and, given [stylesheetPath], the host
  /// stylesheet `<link>` right after it) as the first elements of `<head>`
  /// (else after `<html>`, else after the doctype, else at the start) and
  /// points static `qrc:///qtwebchannel/qwebchannel.js` references at the
  /// empty shim. Works on bytes (as Latin-1), so the page's own encoding is
  /// untouched.
  @visibleForTesting
  static List<int> injectBridge(
    List<int> html,
    String bridgePath, {
    String? stylesheetPath,
  }) {
    var text = latin1
        .decode(html)
        .replaceAll(
          'qrc:///qtwebchannel/qwebchannel.js',
          dappQwebchannelShimPath,
        );
    final css = stylesheetPath == null
        ? ''
        : '<link rel="stylesheet" href="$stylesheetPath">';
    final tag = '<script src="$bridgePath"></script>$css';
    final at = [
      RegExp(r'<head(\s[^>]*)?>', caseSensitive: false),
      RegExp(r'<html(\s[^>]*)?>', caseSensitive: false),
      RegExp(r'<!doctype[^>]*>', caseSensitive: false),
    ].map((r) => r.firstMatch(text)).whereType<RegExpMatch>().firstOrNull;
    text = at == null ? '$tag$text' : text.replaceRange(at.end, at.end, tag);
    return latin1.encode(text);
  }

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'htm': 'text/html; charset=utf-8',
    'js': 'text/javascript; charset=utf-8',
    'mjs': 'text/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json',
    'map': 'application/json',
    'txt': 'text/plain; charset=utf-8',
    'wasm': 'application/wasm',
    'svg': 'image/svg+xml',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'avif': 'image/avif',
    'ico': 'image/x-icon',
    'bmp': 'image/bmp',
    'woff': 'font/woff',
    'woff2': 'font/woff2',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'eot': 'application/vnd.ms-fontobject',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'mp4': 'video/mp4',
    'webm': 'video/webm',
  };

  /// The Content-Type for a file name; unknown types are served as opaque
  /// bytes, which `nosniff` keeps from being run as script or style.
  static String contentTypeFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    return _types[fileName.substring(dot + 1).toLowerCase()] ??
        'application/octet-stream';
  }
}
