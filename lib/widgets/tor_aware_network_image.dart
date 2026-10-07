/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../networking/http.dart';
import '../wallets/beam/explorer/campfire_proxy_info.dart';

/// An image from the web (token icon, theme preview) that follows Campfire's
/// Tor rule. Flutter's `Image.network` and `SvgPicture.network` open their
/// own connections, which never go through Tor; with Tor on they would show
/// the image host this device's internet address. So: Tor off, Flutter's own
/// network image; Tor on, the bytes come through Tor's SOCKS proxy
/// (Campfire's [HTTP]); Tor on but not connected, nothing is fetched and
/// [error] shows.
class TorAwareNetworkImage extends StatefulWidget {
  const TorAwareNetworkImage(
    this.url, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.svg,
    this.placeholder,
    this.error,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;

  /// Whether [url] is an SVG; null: by its file extension.
  final bool? svg;

  /// Shown while loading.
  final Widget? placeholder;

  /// Shown when the image cannot be loaded (or Tor is on and not connected).
  final Widget? error;

  @override
  State<TorAwareNetworkImage> createState() => _TorAwareNetworkImageState();
}

/// Bytes fetched through Tor this session, newest last (a small LRU).
final LinkedHashMap<String, Uint8List> _torImageCache = LinkedHashMap();
const int _torImageCacheSize = 64;

class _TorAwareNetworkImageState extends State<TorAwareNetworkImage> {
  Future<Uint8List?>? _bytes;

  bool get _isSvg =>
      widget.svg ??
      Uri.tryParse(widget.url)?.path.toLowerCase().endsWith('.svg') ??
      false;

  Widget get _error =>
      widget.error ?? SizedBox(width: widget.width, height: widget.height);

  Widget get _placeholder =>
      widget.placeholder ??
      SizedBox(width: widget.width, height: widget.height);

  Future<Uint8List?> _fetch(
    ({InternetAddress host, int port}) proxy,
  ) async {
    final cached = _torImageCache.remove(widget.url);
    if (cached != null) {
      _torImageCache[widget.url] = cached;
      return cached;
    }
    final uri = Uri.tryParse(widget.url);
    if (uri == null || uri.scheme != 'https') return null;
    final r = await const HTTP().get(url: uri, proxyInfo: proxy);
    if (r.code != 200 || r.bodyBytes.isEmpty) return null;
    final bytes = Uint8List.fromList(r.bodyBytes);
    _torImageCache[widget.url] = bytes;
    while (_torImageCache.length > _torImageCacheSize) {
      _torImageCache.remove(_torImageCache.keys.first);
    }
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final ({InternetAddress host, int port})? proxy;
    try {
      proxy = campfireProxyInfo();
    } catch (_) {
      // Tor on, not connected: fetch nothing rather than go around it.
      return _error;
    }
    if (proxy == null) {
      _bytes = null;
      return _isSvg
          ? SvgPicture.network(
              widget.url,
              width: widget.width,
              height: widget.height,
              fit: widget.fit ?? BoxFit.contain,
              placeholderBuilder: (_) => _placeholder,
            )
          : Image.network(
              widget.url,
              width: widget.width,
              height: widget.height,
              fit: widget.fit,
              errorBuilder: (_, _, _) => _error,
            );
    }
    final bytes = _bytes ??= _fetch(proxy).catchError((Object _) => null);
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return _placeholder;
        final data = snap.data;
        if (data == null) return _error;
        return _isSvg
            ? SvgPicture.memory(
                data,
                width: widget.width,
                height: widget.height,
                fit: widget.fit ?? BoxFit.contain,
              )
            : Image.memory(
                data,
                width: widget.width,
                height: widget.height,
                fit: widget.fit,
                errorBuilder: (_, _, _) => _error,
              );
      },
    );
  }
}
