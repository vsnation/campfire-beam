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

import 'beam_layout.dart';

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
/// FilePicker on desktop, share_plus on phones. A file shared from a phone
/// is written to the app's temporary folder only for the share sheet and
/// deleted right after.
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
      await File(path).writeAsString(csv, flush: true);
      return path;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(csv, flush: true);
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
