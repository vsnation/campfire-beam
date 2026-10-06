/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;

import '../../../../networking/http.dart';
import '../../explorer/campfire_proxy_info.dart';
import '../dapp_catalogue.dart';
import '../dapp_package.dart';

/// Downloads one URL; [status] is the HTTP status code.
typedef DappHttpGet = Future<({int status, List<int> body})> Function(Uri url);

/// Why a bundled dApp could not be downloaded.
enum DappFetchFailure {
  /// No answer, or the connection broke (or Tor is on but not connected).
  network,

  /// The server answered with something other than 200.
  server,

  /// The bytes are not the pinned package: wrong size or fingerprint.
  mismatch,
}

class DappFetchException implements Exception {
  const DappFetchException(this.failure, this.detail);

  final DappFetchFailure failure;

  /// For logs; never shown as the user-facing reason.
  final String detail;

  @override
  String toString() => 'DappFetchException(${failure.name}): $detail';
}

/// Fetches the bundled dApps by hash, as
/// `test/beam/dapps/tool/fetch_bundled_dapps.sh` does: download from the
/// catalogue's pinned URL, refuse anything whose size or SHA-256 differs
/// from the pin, then read and check the package. Nothing is installed from
/// bytes that did not match.
class DappPackageFetcher {
  DappPackageFetcher(this._get, {this.timeout = const Duration(minutes: 2)});

  /// Through Campfire's HTTP layer, honouring the Tor setting: with Tor on,
  /// the download goes through Tor, and fails rather than leak onto
  /// clearnet when Tor is not connected.
  factory DappPackageFetcher.campfire() => DappPackageFetcher((url) async {
    final r = await const HTTP().get(
      url: url,
      proxyInfo: campfireProxyInfo(),
      connectionTimeout: const Duration(seconds: 20),
    );
    return (status: r.code, body: r.bodyBytes);
  });

  final DappHttpGet _get;
  final Duration timeout;

  static const _host = 'raw.githubusercontent.com';

  Future<DappPackage> fetch(DappCatalogueEntry entry) async {
    final url = Uri.parse(entry.url);
    if (url.scheme != 'https' || url.host != _host) {
      throw const DappFetchException(
        DappFetchFailure.mismatch,
        'catalogue URL is not a pinned https URL',
      );
    }
    final ({int status, List<int> body}) r;
    try {
      r = await _get(url).timeout(timeout);
    } catch (e) {
      throw DappFetchException(DappFetchFailure.network, '${e.runtimeType}');
    }
    if (r.status != 200) {
      throw DappFetchException(DappFetchFailure.server, 'HTTP ${r.status}');
    }
    if (r.body.length != entry.size) {
      throw DappFetchException(
        DappFetchFailure.mismatch,
        '${r.body.length} bytes, pinned ${entry.size}',
      );
    }
    final digest = crypto.sha256.convert(r.body).toString();
    if (digest != entry.sha256) {
      throw DappFetchException(
        DappFetchFailure.mismatch,
        'sha256 $digest, pinned ${entry.sha256}',
      );
    }
    final package = DappPackage.read(r.body);
    if (package.sha256 != entry.sha256 || package.manifest.guid != entry.guid) {
      throw const DappFetchException(
        DappFetchFailure.mismatch,
        'package is not the catalogue entry',
      );
    }
    return package;
  }
}
