/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utilities/stack_file_system.dart';
import '../host/secret_file.dart';
import 'beam_private_node_coordinator.dart';

/// The node panel's "Use my own private node" choice, kept for the next run
/// in `<beam root>/private_node.json` (next to the node's own data, so a
/// "delete everything" of the BEAM folder removes it too).
///
/// Until the user has chosen, it reads as [defaultValue]: on for desktop,
/// off elsewhere (phones cannot run the node).
///
/// It is a [BeamPrivateNodeSetting], so the wallet environment can hand it
/// to every coordinator. Not a secret: it holds one boolean.
class BeamPrivateNodePreference implements BeamPrivateNodeSetting {
  BeamPrivateNodePreference({
    required this._beamRoot,
    bool? defaultValue,
  }) : defaultValue =
           defaultValue ??
           BeamFixedPrivateNodeSetting.platformDefault().enabled;

  /// The app's BEAM folder (`StackFileSystem.applicationBeamDirectory`).
  factory BeamPrivateNodePreference.app() => BeamPrivateNodePreference(
    beamRoot: () async =>
        (await StackFileSystem.applicationBeamDirectory()).path,
  );

  static const String fileName = 'private_node.json';

  final Future<String> Function() _beamRoot;

  /// What [read] answers before the user has chosen.
  final bool defaultValue;

  static final StreamController<bool> _changes =
      StreamController<bool>.broadcast();

  /// Every [write], from any instance. Broadcast.
  static Stream<bool> get changes => _changes.stream;

  Future<File> _file() async => File(p.join(await _beamRoot(), fileName));

  /// The stored choice, or [defaultValue]. A missing or unreadable file is
  /// the default, never an error.
  @override
  Future<bool> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return defaultValue;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['enabled'] is bool) {
        return decoded['enabled'] as bool;
      }
    } catch (_) {
      // Fall through to the default.
    }
    return defaultValue;
  }

  /// Stores [enabled] (atomically: a temp file renamed over the old one).
  Future<void> write(bool enabled) async {
    final root = await _beamRoot();
    await ensurePrivateDir(root);
    final target = File(p.join(root, fileName));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode({'enabled': enabled}), flush: true);
    await tmp.rename(target.path);
    if (!_changes.isClosed) _changes.add(enabled);
  }
}
