/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// A wallet API version a dApp can be served.
///
/// The set and the meaning of `current` are the core's `ApiVersions` at tag
/// `beam-7.5.14493` (`wallet/api/i_wallet_api.h:38-53`): 6.0 to 7.4, with
/// `current` = 7.4. 6.2 is the same API as 6.1 (`i_wallet_api.cpp:118-125`).
enum DappApiVersion {
  v6_0(6, 0),
  v6_1(6, 1),
  v6_2(6, 2),
  v7_0(7, 0),
  v7_1(7, 1),
  v7_2(7, 2),
  v7_3(7, 3),
  v7_4(7, 4);

  const DappApiVersion(this.major, this.minor);

  final int major;
  final int minor;

  /// What `current` means in this core.
  static const current = DappApiVersion.v7_4;

  /// `major.minor`, the form manifests and the method table use.
  String get label => '$major.$minor';

  /// The version whose method table applies: 6.2 is served by the 6.1 API.
  DappApiVersion get methodTable => this == v6_2 ? v6_1 : this;

  /// Parses `current` or `major.minor`; null when the core would not accept
  /// it (`IWalletApi::ValidateAPIVersion`). Stricter than the core on
  /// spelling: only digits and one dot, no signs, spaces or suffixes.
  static DappApiVersion? tryParse(String? text) {
    if (text == null) return null;
    if (text == 'current') return current;
    final m = _pattern.firstMatch(text);
    if (m == null) return null;
    final major = int.parse(m.group(1)!);
    final minor = int.parse(m.group(2)!);
    for (final v in values) {
      if (v.major == major && v.minor == minor) return v;
    }
    return null;
  }

  static final _pattern = RegExp(r'^([0-9]{1,4})\.([0-9]{1,4})$');

  /// The version a dApp is served, chosen exactly as beam-ui does
  /// (`WebAPICreator::createApi`, `webapi_creator.cpp:51-95`): the wanted
  /// version (`current` when absent) if supported, else the minimum version
  /// if supported, else null and the dApp must not be loaded ("This dApp
  /// needs a newer wallet").
  ///
  /// The same rule applies to a manifest's `api_version` /
  /// `min_api_version` and to the `apiver` / `apivermin` a page sends in
  /// the web-extension handshake.
  static DappApiVersion? negotiate({String? wanted, String? minimum}) =>
      tryParse(wanted ?? 'current') ?? tryParse(minimum ?? '');
}
