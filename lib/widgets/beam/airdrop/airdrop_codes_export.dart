/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../wallets/beam/host/secret_file.dart';
import 'beam_layout.dart';

/// Writes [csv] (bearer codes: whoever has one can claim its value) to
/// [path] so that only this user can read it: 0600 on macOS and Linux.
///
/// The file is emptied and locked down before a single code is written, so
/// there is no moment when codes sit in a file other accounts can read
/// (the default umask makes new files 0644). Throws if the permissions
/// cannot be set; the file is then empty.
Future<void> writePrivateCsv(String path, String csv) async {
  final file = File(path);
  await file.writeAsString('', flush: true);
  await setOwnerOnly(path);
  await file.writeAsString(csv, flush: true);
}

/// Where the user can take a batch's codes: the only ways codes leave the
/// wallet's secure storage, each on an explicit tap. Nothing here logs
/// them.
abstract class AirdropCodesExporter {
  /// Saves [csv] as a file the user picks (desktop) or hands it to the
  /// system share sheet (phone). Returns where it went, or null when the
  /// user backed out.
  Future<String?> saveCsv(
    BuildContext context, {
    required String fileName,
    required String csv,
  });

  /// The system share sheet with [text] (phones).
  Future<void> shareText(BuildContext context, String text);
}

/// Campfire's way of saving and sharing files (`address_card.dart`):
/// FilePicker on desktop, share_plus on phones. Every file is written by
/// [writePrivateCsv] (0600). A file shared from a phone is written to the
/// app's temporary folder only for the share sheet and deleted right
/// after.
class CampfireAirdropCodesExporter implements AirdropCodesExporter {
  const CampfireAirdropCodesExporter();

  @override
  Future<String?> saveCsv(
    BuildContext context, {
    required String fileName,
    required String csv,
  }) async {
    if (BeamLayoutScope.isDesktop(context)) {
      final home = Platform.environment['HOME'];
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save airdrop codes',
        fileName: fileName,
        initialDirectory: home != null && Directory(home).existsSync()
            ? home
            : null,
      );
      if (path == null) return null;
      await writePrivateCsv(path, csv);
      return path;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await writePrivateCsv(file.path, csv);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: fileName),
      );
    } finally {
      if (file.existsSync()) await file.delete();
    }
    return fileName;
  }

  @override
  Future<void> shareText(BuildContext context, String text) async {
    await SharePlus.instance.share(ShareParams(text: text));
  }
}
