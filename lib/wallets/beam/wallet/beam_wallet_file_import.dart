/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:isar_community/isar.dart';

import '../../../db/isar/main_db.dart';
import '../../../services/node_service.dart';
import '../../../utilities/flutter_secure_storage_interface.dart';
import '../../../utilities/prefs.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../isar/models/wallet_info.dart';
import '../../wallet/impl/beam_wallet.dart';
import '../../wallet/supporting/beam_wallet_info_extension.dart';
import '../../wallet/wallet.dart';
import '../host/beam_host.dart';
import '../host/beam_host_exception.dart';
import 'beam_secret_store.dart';
import 'beam_wallet_environment.dart';
import 'beam_wallet_errors.dart';

/// What went wrong importing a `wallet.db`, in words for the person who
/// picked the file. Never blames them; always says what to do next.
abstract final class BeamImportMessages {
  static const wrongPassword =
      "That password doesn't open this wallet file. Check it (it is the "
      "password you set in the BEAM wallet this file comes from) and try "
      'again. If it still fails, the file may not be a BEAM wallet.';
  static const inUse =
      'Another program is using this wallet file right now. Close that BEAM '
      'wallet app, then import the file again.';
  static const gone =
      'BEAM Campfire could not read that file any more. Choose it again.';
  static const unsupported =
      "This version of BEAM Campfire can't import wallet files on this "
      'device yet.';
  static const failed =
      'Importing the wallet did not work. Nothing was changed; try again.';
}

/// Brings a BEAM `wallet.db` and its password into Campfire as a new wallet,
/// without a recovery phrase (the owner has files, not phrases).
///
/// 1. A wallet entry with no phrase (none stored, none made up).
/// 2. The host copies the file into the wallet's own directory (the
///    original is only read) and opens the copy with the password through
///    BEAM's own code.
/// 3. The password goes to secure storage, where it opens the copy from now
///    on; the owner key is read once (desktop: the private node needs it).
/// 4. The wallet is marked imported: no "show phrase", no rescan, no phrase
///    backup for it.
/// Any failure undoes everything (entry, copy, secrets) and throws a
/// [BeamWalletException] with a [BeamImportMessages] text.
Future<BeamWallet> importBeamWalletFile({
  required String name,
  required String sourcePath,
  required String password,
  required MainDB mainDB,
  required SecureStorageInterface secureStorage,
  required NodeService nodeService,
  required Prefs prefs,
  BeamWalletEnvironment? environment,
  CryptoCurrencyNetwork network = CryptoCurrencyNetwork.main,
}) async {
  final env = environment ?? BeamWalletEnvironment.instance;
  final info = WalletInfo.createNew(coin: Beam(network), name: name);
  final walletId = info.walletId;
  var created = false;
  try {
    final wallet =
        await Wallet.create(
              walletInfo: info,
              mainDB: mainDB,
              secureStorageInterface: secureStorage,
              nodeService: nodeService,
              prefs: prefs,
            )
            as BeamWallet;
    created = true;

    final BeamHost host;
    try {
      host = await env.host();
    } catch (e) {
      throw beamWalletExceptionFrom(e);
    }
    if (host is! BeamWalletFileImporter) {
      throw const BeamWalletException(
        BeamWalletProblem.other,
        BeamImportMessages.unsupported,
      );
    }
    final dir = await env.walletDir(walletId);
    try {
      await (host as BeamWalletFileImporter).importWalletFile(
        walletDir: dir,
        sourcePath: sourcePath,
        password: password,
      );
    } on BeamHostException catch (e) {
      throw BeamWalletException(
        e.kind == BeamHostError.wrongPassword
            ? BeamWalletProblem.wrongPassword
            : BeamWalletProblem.other,
        switch (e.kind) {
          BeamHostError.wrongPassword => BeamImportMessages.wrongPassword,
          BeamHostError.walletInUse => BeamImportMessages.inUse,
          BeamHostError.invalidInput when e.message.contains('no longer') =>
            BeamImportMessages.gone,
          BeamHostError.invalidInput => e.message,
          _ => BeamImportMessages.failed,
        },
      );
    }

    final secrets = BeamSecretStore(secureStorage, walletId);
    await secrets.writePassword(password);
    // The private node needs the owner key; phones never run it and refuse
    // to read it (that is fine: nothing to store then).
    try {
      final key = await host.exportOwnerKey(walletDir: dir, password: password);
      await secrets.writeOwnerKey(key);
    } catch (e) {
      env.log('Owner key not read at import (read before the first open): $e');
    }

    await info.updateExtraBeamWalletInfo(
      beamData: const ExtraBeamWalletInfo(importedFromFile: true),
      isar: mainDB.isar,
    );
    // There is no phrase to verify: never ask for one.
    await info.setMnemonicVerified(isar: mainDB.isar);
    // wallet.db exists, so init() opens nothing new and creates nothing.
    await wallet.init();
    return wallet;
  } catch (e) {
    if (created) {
      try {
        await deleteBeamWallet(walletId: walletId, secureStore: secureStorage);
      } catch (_) {
        // Best effort; the entry below still goes.
      }
      try {
        await mainDB.isar.writeTxn(() async {
          await mainDB.isar.walletInfo
              .where()
              .walletIdEqualTo(walletId)
              .deleteAll();
        });
      } catch (_) {
        // Nothing more to undo.
      }
    }
    if (e is BeamWalletException) rethrow;
    if (e is FileSystemException) {
      throw const BeamWalletException(
        BeamWalletProblem.other,
        BeamImportMessages.gone,
      );
    }
    throw beamWalletExceptionFrom(e);
  }
}
