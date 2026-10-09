/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

/// The rules for an Ethereum RPC address in Settings › Nodes. An RPC is a
/// whole URL (`https://eth.drpc.org`, path kept), not a host and a port.
abstract final class EthRpcUrl {
  static const String example = 'https://ethereum-rpc.publicnode.com';

  /// Null when [input] can be used, otherwise what to change, in plain words.
  static String? problem(String input) {
    final s = input.trim();
    if (s.isEmpty) return 'Enter the RPC URL';
    final uri = Uri.tryParse(s);
    if (uri == null ||
        !(uri.isScheme('https') || uri.isScheme('http')) ||
        uri.host.isEmpty ||
        uri.host.contains(' ')) {
      return 'Use a URL like $example';
    }
    if (uri.isScheme('http') && !allowsPlainHttp(uri.host)) {
      return 'Use https:// (http:// is only for a server on this device, '
          'your own network, or a .onion address)';
    }
    return null;
  }

  /// http:// is accepted only where nobody on the way can read or change
  /// the traffic: this device, the local network, or a Tor onion service.
  static bool allowsPlainHttp(String host) {
    final h = _bare(host.toLowerCase());
    if (h == 'localhost' || h.endsWith('.onion')) return true;
    final ip = InternetAddress.tryParse(h);
    if (ip == null) return false;
    if (ip.isLoopback || ip.isLinkLocal) return true;
    final b = ip.rawAddress;
    if (ip.type == InternetAddressType.IPv4) {
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
          (b[0] == 192 && b[1] == 168);
    }
    return (b[0] & 0xfe) == 0xfc; // IPv6 unique local, fc00::/7
  }

  static bool isOnion(String host) =>
      _bare(host.toLowerCase()).endsWith('.onion');

  /// The port [url] connects to (443 for https unless it says otherwise).
  /// Campfire's node records keep one; the URL is what is used.
  static int portOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return 443;
    if (uri.hasPort) return uri.port;
    return uri.isScheme('http') ? 80 : 443;
  }

  static bool usesTls(String url) =>
      Uri.tryParse(url.trim())?.isScheme('https') ?? true;

  static String _bare(String host) => host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
}
