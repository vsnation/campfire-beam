/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:stack_wallet_backup/generate_password.dart';

import '../../../utilities/flutter_secure_storage_interface.dart';

/// Secure-storage key names for a BEAM wallet's own secrets
/// (ARCHITECTURE.md §5, research/01 §6.2).
///
/// Neither key is part of a Stack backup: a backup carries only the
/// recovery phrase, and restoring rebuilds `wallet.db` with a fresh
/// password and owner key.
abstract final class BeamSecretKeys {
  /// Random password of `wallet.db`. Never shown, never logged, never on an
  /// argv.
  static String walletPassword(String walletId) =>
      'BEAM_WALLET_PASSWORD_${walletId.toUpperCase()}';

  /// The wallet's owner (viewer) key, exported while the wallet was closed
  /// anyway. A privacy secret: it reveals the whole
  /// transaction history. Same protection as the password.
  static String ownerKey(String walletId) =>
      'BEAM_OWNER_KEY_${walletId.toUpperCase()}';

  static List<String> all(String walletId) => [
    walletPassword(walletId),
    ownerKey(walletId),
  ];
}

/// Reads and writes one wallet's BEAM secrets.
class BeamSecretStore {
  BeamSecretStore(this._storage, this.walletId);

  final SecureStorageInterface _storage;
  final String walletId;

  Future<String?> readPassword() =>
      _storage.read(key: BeamSecretKeys.walletPassword(walletId));

  /// Generates a new random password (Campfire's `generatePassword`, ~133
  /// bits, alphanumeric without look-alikes) and stores it before any file
  /// is created with it.
  Future<String> createPassword() async {
    final password = generatePassword();
    await _storage.write(
      key: BeamSecretKeys.walletPassword(walletId),
      value: password,
    );
    return password;
  }

  /// Stores the password of an imported `wallet.db` (the one its owner
  /// set), which opens it from now on like a generated one.
  Future<void> writePassword(String password) => _storage.write(
    key: BeamSecretKeys.walletPassword(walletId),
    value: password,
  );

  Future<String?> readOwnerKey() async {
    final key = await _storage.read(key: BeamSecretKeys.ownerKey(walletId));
    return key == null || key.isEmpty ? null : key;
  }

  Future<void> writeOwnerKey(String ownerKey) =>
      _storage.write(key: BeamSecretKeys.ownerKey(walletId), value: ownerKey);

  Future<void> deleteOwnerKey() =>
      _storage.delete(key: BeamSecretKeys.ownerKey(walletId));

  /// Deletes the password and the owner key.
  Future<void> deleteAll() async {
    for (final key in BeamSecretKeys.all(walletId)) {
      await _storage.delete(key: key);
    }
  }
}
