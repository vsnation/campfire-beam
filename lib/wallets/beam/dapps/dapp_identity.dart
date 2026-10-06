/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import 'dapp_manifest.dart';

/// Who a request comes from, as the approval sheet names it.
@immutable
class DappIdentity {
  const DappIdentity({
    required this.guid,
    required this.name,
    required this.origin,
    required this.startUrl,
    this.version,
    this.publisher,
    this.checkedByCampfire = false,
  });

  /// For a dApp installed from [manifest] and served at [origin]
  /// (`http://127.0.0.1:<port>`). [checkedByCampfire]: the installed
  /// package is a bundled one, byte for byte.
  factory DappIdentity.fromManifest(
    DappManifest manifest,
    String origin, {
    bool checkedByCampfire = false,
  }) => DappIdentity(
    guid: manifest.guid,
    name: manifest.name,
    origin: origin,
    startUrl: '$origin/${manifest.startPath}',
    version: manifest.version,
    publisher: manifest.publisher,
    checkedByCampfire: checkedByCampfire,
  );

  /// Canonical 32-hex guid.
  final String guid;
  final String name;

  /// The origin the dApp is served from.
  final String origin;

  /// The URL the dApp's page is opened at.
  final String startUrl;
  final String? version;
  final String? publisher;

  /// The package is one of the bundled dApps Campfire pins by SHA-256.
  /// False for anything installed from a file: the approval sheet then
  /// says Campfire did not check it, since its name is whatever the file
  /// says.
  final bool checkedByCampfire;

  /// The core's app id for this dApp: `"appid:" + hex(SHA-256(name ‖ 0 ‖
  /// url ‖ 0))`, as `GenerateAppID` computes it
  /// (`wallet/client/apps_api/apps_utils.cpp:25-31`; `ECC::Hash::Processor`
  /// writes a `std::string` with its terminating NUL, `ecc_native.h:599`).
  /// It differs from the Qt wallet's for the same dApp because the URL
  /// does (research/04 §7.2).
  String get appId => appIdFor(name, startUrl);

  static String appIdFor(String name, String url) {
    final bytes = <int>[...utf8.encode(name), 0, ...utf8.encode(url), 0];
    return 'appid:${crypto.sha256.convert(bytes)}';
  }
}
