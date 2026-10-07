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

/// The BEAM build keeps Campfire's logo and branding, and `AppConfig.appName`
/// is "Campfire" exactly as in a real Campfire install.
/// Everything that names files or system registrations from the app name
/// would then collide with a real Campfire on the same machine: shared logs,
/// one app's auto-backup rotation deleting the other's backups, one Windows
/// data dir. This tells the BEAM build apart by its data dir name instead,
/// which no user sees. Upstream builds are unaffected.
abstract final class BeamAppIdentity {
  /// `_appDataDirName` written by `scripts/app_config/configure_campfire.sh`.
  static const String dataDirName = "campfirebeam";

  static bool get isActive => AppConfig.appDefaultDataDirName == dataDirName;

  /// The name the user sees for the app itself (window title, launch and
  /// login screens, About): "BEAM Campfire" in the BEAM build, so it is never
  /// mistaken for (or installed over) Firo's Campfire. `AppConfig.appName`
  /// stays "Campfire": code branches on that exact string.
  static String get displayName => isActive ? "BEAM Campfire" : AppConfig.appName;

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
