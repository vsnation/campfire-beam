/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../dapp_catalogue.dart';
import '../dapp_errors.dart';
import '../dapp_installer.dart';
import '../dapp_package.dart';
import 'dapp_package_fetcher.dart';

/// One row of the dApp store: a bundled dApp, an installed one, or both.
@immutable
class DappStoreItem {
  const DappStoreItem({
    required this.guid,
    required this.name,
    this.description,
    this.bundled,
    this.installed,
  });

  final String guid;
  final String name;
  final String? description;

  /// The catalogue entry when this is one of the bundled dApps.
  final DappCatalogueEntry? bundled;

  /// The installation, when installed.
  final DappInstallation? installed;

  bool get isInstalled => installed != null;

  /// Installed from the pinned bundled package, byte for byte.
  bool get isPinned =>
      bundled != null &&
      (installed == null || installed!.packageSha256 == bundled!.sha256);

  /// The dApp's icon file, when it is installed and has one.
  String? get iconFile {
    final i = installed;
    final icon = i?.manifest.iconPath;
    if (i == null || icon == null) return null;
    return p.joinAll([i.filesDirectory, ...icon.split('/')]);
  }

  /// "5.3 MB download".
  String? get downloadLabel {
    final b = bundled;
    if (b == null) return null;
    if (b.size < 1000 * 1000) {
      return '${(b.size / 1000).ceil()} KB download';
    }
    return '${(b.size / (1000 * 1000)).toStringAsFixed(1)} MB download';
  }
}

enum DappStoreStatus { loading, ready, failed }

/// The dApp store's state: the bundled catalogue merged with what is
/// installed, and the install / uninstall actions.
class DappStoreController extends ChangeNotifier {
  DappStoreController({
    required this.installer,
    required this.fetcher,
    List<DappCatalogueEntry> catalogue = dappBundledCatalogue,
  }) : _catalogue = List.unmodifiable(catalogue);

  final DappInstaller installer;
  final DappPackageFetcher fetcher;
  final List<DappCatalogueEntry> _catalogue;

  DappStoreStatus _status = DappStoreStatus.loading;
  List<DappInstallation> _installed = const [];
  final Set<String> _busy = {};
  bool _disposed = false;

  DappStoreStatus get status => _status;

  /// Installed dApps, by name.
  List<DappStoreItem> get installed => [
    for (final i in _installed)
      DappStoreItem(
        guid: i.guid,
        name: i.manifest.name,
        description: i.manifest.description,
        bundled: _bundled(i.guid),
        installed: i,
      ),
  ];

  /// Bundled dApps that are not installed, by name.
  List<DappStoreItem> get available {
    final have = {for (final i in _installed) i.guid};
    final out = [
      for (final e in _catalogue)
        if (!have.contains(e.guid))
          DappStoreItem(
            guid: e.guid,
            name: e.name,
            description: dappBundledDescriptions[e.guid],
            bundled: e,
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// An install or uninstall of [guid] is running.
  bool isBusy(String guid) => _busy.contains(guid);

  DappCatalogueEntry? _bundled(String guid) {
    for (final e in _catalogue) {
      if (e.guid == guid) return e;
    }
    return null;
  }

  Future<void> refresh() async {
    _status = DappStoreStatus.loading;
    _notify();
    try {
      await installer.cleanup();
      _installed = await installer.list();
      _status = DappStoreStatus.ready;
    } catch (_) {
      _status = DappStoreStatus.failed;
    }
    _notify();
  }

  /// Downloads [entry] by its pinned hash and installs it (replacing an
  /// older install of the same dApp).
  Future<DappInstallation> installBundled(DappCatalogueEntry entry) =>
      _whileBusy(entry.guid, () async {
        final package = await fetcher.fetch(entry);
        return installer.install(package, replace: true);
      });

  /// Reads a `.dapp` file the user picked. Throws [DappInstallException]
  /// for anything that is not a safe, valid package.
  Future<DappPackage> readFile(String path) async {
    final file = File(path);
    const limits = DappPackageLimits();
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      throw const DappInstallException(
        DappInstallError.cantOpenFile,
        'the file could not be read',
      );
    }
    if (length > limits.maxPackageBytes) {
      throw DappInstallException(
        DappInstallError.tooLarge,
        'package is $length bytes',
      );
    }
    final package = DappPackage.read(
      await file.readAsBytes(),
      limits: limits,
    );
    _refuseBundledGuid(package);
    return package;
  }

  /// A file may not take a bundled dApp's identity unless it is that dApp's
  /// pinned package byte for byte: it would get its origin, its browser
  /// storage and its transaction scope, and the store, browser and approval
  /// sheet would name it exactly like the checked one.
  void _refuseBundledGuid(DappPackage package) {
    final b = _bundled(package.manifest.guid);
    if (b != null && b.sha256 != package.sha256) {
      throw DappInstallException(
        DappInstallError.reservedGuid,
        'the file uses the guid of the bundled ${b.name}',
        dappName: b.name,
      );
    }
  }

  /// The bundled dApp whose name [package] copies under another guid, or
  /// null. The install dialog warns about it.
  String? bundledNameCopiedBy(DappPackage package) {
    final name = package.manifest.name.trim().toLowerCase();
    for (final e in _catalogue) {
      if (e.guid != package.manifest.guid &&
          e.name.trim().toLowerCase() == name) {
        return e.name;
      }
    }
    return null;
  }

  /// The installed dApp [package] would replace, if any.
  DappInstallation? existingFor(DappPackage package) {
    for (final i in _installed) {
      if (i.guid == package.manifest.guid) return i;
    }
    return null;
  }

  /// Installs a package the user picked ([readFile]).
  Future<DappInstallation> installPackage(
    DappPackage package, {
    bool replace = false,
  }) {
    try {
      _refuseBundledGuid(package);
    } catch (e) {
      return Future.error(e);
    }
    return _whileBusy(
      package.manifest.guid,
      () => installer.install(package, replace: replace),
    );
  }

  Future<void> uninstall(String guid) =>
      _whileBusy(guid, () => installer.uninstall(guid));

  Future<T> _whileBusy<T>(String guid, Future<T> Function() op) async {
    _busy.add(guid);
    _notify();
    try {
      return await op();
    } finally {
      _busy.remove(guid);
      try {
        _installed = await installer.list();
        _status = DappStoreStatus.ready;
      } catch (_) {
        _status = DappStoreStatus.failed;
      }
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The bundled dApps' own one-line descriptions (from their manifests,
/// pinned with the packages), shown before a dApp is downloaded.
const Map<String, String> dappBundledDescriptions = {
  '7e9c916bc3444aadbd10232713be4525':
      'Liquidity Accumulator for BEAM / BEAMX | BEAM / NPH pair on Beam DEX',
  'a0b387971c9c4b0eaefa34f4deb888e4':
      'Decentralized anonymous naming for the BEAM wallet',
  '6e5151edf286458da42d11f3aef4969d':
      'Mint confidential assets with provably limited supply',
  '9811fa65e16b44b585ee22e227b0e2ee': 'Confidential Bridges app',
  '43d08c209df04c169005446d7eff51ab': 'Confidential Beam to Ethereum bridge',
  'abcc470e12c6422291f360f83d79355e': 'Governance, staking and voting',
  'c26538f5ce9e410b89c1fd0dff783f97': 'Voting on Beam community proposals',
  'db851322f6674a6da3e84e9953db2ffd':
      'AMM based decentralized exchange for Confidential Assets',
  'ffbec734a0bb4f88a7104357a2680d20': 'Buy and sell confidential NFTs',
};

/// What went wrong with an install, in words that never blame the user and
/// name the next step.
String dappInstallErrorText(Object error, {required String name}) {
  if (error is DappFetchException) {
    return switch (error.failure) {
      DappFetchFailure.network =>
        "Couldn't download $name. Check your internet connection (and Tor, "
            "if it's on), then try again.",
      DappFetchFailure.server =>
        "The download server didn't send $name. Try again in a few "
            'minutes.',
      DappFetchFailure.mismatch =>
        "The download didn't match the fingerprint Campfire expects for "
            '$name, so nothing was installed. Try again later.',
    };
  }
  if (error is DappInstallException) {
    return switch (error.error) {
      DappInstallError.unsupported =>
        '$name needs a newer wallet than this version of Campfire.',
      DappInstallError.alreadyInstalled => '$name is already installed.',
      DappInstallError.reservedGuid =>
        'This file claims to be ${error.dappName ?? 'a dApp Campfire '
                'checks'}, but it is not the package Campfire checked, so '
            'nothing was installed. Install ${error.dappName ?? 'it'} from '
            'the Available list instead.',
      DappInstallError.folderPrepFailed || DappInstallError.extractFailed =>
        "Campfire couldn't save $name on this device. Check that there is "
            'free space, then try again.',
      _ =>
        "This file isn't a dApp package Campfire can install safely, so "
            'nothing was installed. Ask the dApp\'s publisher for a new '
            'copy.',
    };
  }
  return 'Something went wrong installing $name. Nothing was changed. '
      'Try again.';
}
