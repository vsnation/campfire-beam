/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Which servers a dApp may be allowed to reach, as the web wallet decides
/// it (`pwa/src/lib/dapps/frame_policy.js`, `remoteHostOk` and
/// `remoteOriginFor`): an https origin whose host is a public DNS name in
/// lowercase, two labels at least, with an optional port. Never an IP
/// address in any spelling (`1.2.3.4`, `127.1`, `0x7f.1`, `[::1]`), a
/// single-label name, a name of this device or the local network
/// (`localhost`, `.local`, `.internal`, …), or a wildcard.
library;

/// At most this many servers for one dApp installed from a file.
const int dappMaxFileOrigins = 16;

final _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
final _digits = RegExp(r'^[0-9]+$');
final _hex = RegExp(r'^0x[0-9a-f]*$');
final _origin = RegExp(
  r'^https://([a-z0-9.-]{1,253})'
  r'(?::([1-9][0-9]{0,4}))?$',
);

// Names that never mean a public server: this device, the local network,
// nowhere.
const _localTlds = {
  'localhost',
  'local',
  'internal',
  'lan',
  'home',
  'arpa',
  'test',
  'invalid',
  'onion',
};

/// A public DNS name in lowercase: two labels at least, never an IPv4
/// address in any spelling.
bool dappRemoteHostOk(String host) {
  if (host.isEmpty || host.length > 253) return false;
  final labels = host.split('.');
  if (labels.length < 2 || !labels.every(_label.hasMatch)) return false;
  final last = labels.last;
  if (_digits.hasMatch(last) || _hex.hasMatch(last)) return false;
  return !_localTlds.contains(last);
}

/// [text] as an https origin a dApp may be allowed (lowercase host, the
/// port only when it is not 443), or null.
String? dappRemoteOriginFor(String text) {
  final m = _origin.firstMatch(text);
  if (m == null || !dappRemoteHostOk(m.group(1)!)) return null;
  final port = m.group(2) == null ? 443 : int.parse(m.group(2)!);
  if (port > 65535) return null;
  return 'https://${m.group(1)}${port == 443 ? '' : ':$port'}';
}

/// The host (and port) of an origin, for the words on screen:
/// `https://explorer.0xmx.net` → `explorer.0xmx.net`.
String dappOriginHost(String origin) =>
    origin.startsWith('https://') ? origin.substring(8) : origin;
