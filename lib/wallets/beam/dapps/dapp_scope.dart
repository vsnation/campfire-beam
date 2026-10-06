/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The transactions and addresses one dApp created, which are the only
/// ones it may see.
///
/// The core scopes these by tagging each tx and address with the app id
/// (`checkTxAccessRights`, `v6_api.cpp:37-50`; address `category`,
/// `v6_api_handle.cpp:126-177`). wallet-api has no app identity, so it tags
/// nothing; the session records ids from the dApp's own successful calls
/// instead and filters by them.
class DappScope {
  DappScope({
    Iterable<String> txIds = const [],
    Iterable<String> addresses = const [],
  }) : txIds = {...txIds},
       addresses = {...addresses};

  final Set<String> txIds;
  final Set<String> addresses;

  Map<String, Object?> toJson() => {
    'tx_ids': txIds.toList()..sort(),
    'addresses': addresses.toList()..sort(),
  };

  static DappScope fromJson(Map<String, Object?> json) => DappScope(
    txIds: (json['tx_ids'] as List<Object?>? ?? const []).whereType<String>(),
    addresses: (json['addresses'] as List<Object?>? ?? const [])
        .whereType<String>(),
  );
}

/// Where a dApp's [DappScope] is kept between launches.
abstract class DappScopeStore {
  Future<DappScope> load();
  Future<void> save(DappScope scope);
}

/// Keeps the scope for the life of the object only.
class InMemoryDappScopeStore implements DappScopeStore {
  InMemoryDappScopeStore([DappScope? initial])
    : _scope = initial ?? DappScope();

  DappScope _scope;

  @override
  Future<DappScope> load() async =>
      DappScope(txIds: _scope.txIds, addresses: _scope.addresses);

  @override
  Future<void> save(DappScope scope) async =>
      _scope = DappScope(txIds: scope.txIds, addresses: scope.addresses);
}

/// Keeps the scope in `scope.json` in the dApp's data directory
/// (`DappInstaller.dataDirectory`): it survives updates and goes with
/// uninstall. Written to a temporary file and renamed into place.
class FileDappScopeStore implements DappScopeStore {
  FileDappScopeStore(this.directory);

  final String directory;

  File get _file => File(p.join(directory, 'scope.json'));

  @override
  Future<DappScope> load() async {
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map<String, Object?>) return DappScope.fromJson(json);
    } on FileSystemException {
      // none yet
    } on FormatException {
      // damaged: start empty rather than show the dApp everything
    }
    return DappScope();
  }

  @override
  Future<void> save(DappScope scope) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(scope.toJson()), flush: true);
    await tmp.rename(_file.path);
  }
}
