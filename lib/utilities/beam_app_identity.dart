/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:path/path.dart' as path;

import '../app_config.dart';

/// The BEAM build shows the user the Campfire name, logo and branding, so
/// `AppConfig.appName` is "Campfire" exactly as in a real Campfire install.
/// Everything that names files or system registrations from the app name
/// would then collide with a real Campfire on the same machine: shared logs,
/// one app's auto-backup rotation deleting the other's backups, one Windows
/// data dir. This tells the BEAM build apart by its data dir name instead,
/// which no user sees. Upstream builds are unaffected.
abstract final class BeamAppIdentity {
  /// `_appDataDirName` written by `scripts/app_config/configure_campfire.sh`.
  static const String dataDirName = "campfirebeam";

  static bool get isActive => AppConfig.appDefaultDataDirName == dataDirName;

  /// Stem for folders kept outside the data dir (logs, backups):
  /// `AppConfig.prefix` upstream, "Campfire_BEAM" in the BEAM build.
  static String get folderStem =>
      isActive ? "${AppConfig.prefix}_BEAM" : AppConfig.prefix;

  /// `%APPDATA%\campfirebeam`. Not `getApplicationSupportDirectory()`:
  /// Windows builds that path from the exe's CompanyName and ProductName,
  /// which are the same as a real Campfire install's, and creates it.
  static Directory windowsDataDirectory() {
    final env = Platform.environment;
    final appData = env["APPDATA"];
    final profile = env["USERPROFILE"];
    final String roaming;
    if (appData != null && appData.isNotEmpty) {
      roaming = appData;
    } else if (profile != null && profile.isNotEmpty) {
      roaming = path.join(profile, "AppData", "Roaming");
    } else {
      throw Exception("Cannot find the Windows AppData folder");
    }
    return Directory(path.join(roaming, dataDirName));
  }
}
