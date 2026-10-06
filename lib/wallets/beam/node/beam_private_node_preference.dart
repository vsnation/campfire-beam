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

import '../../../app_config.dart';
import '../../../utilities/prefs.dart';
import '../../../utilities/stack_file_system.dart';
import '../host/secret_file.dart';
import 'beam_private_node_coordinator.dart';

/// Whether Campfire routes its traffic through Tor (the app has the Tor
/// feature and the user switched it on), the same rule the explorer uses.
bool campfireTorEnabled() =>
    AppConfig.hasFeature(AppFeature.tor) && Prefs.instance.useTor;

/// The node panel's "Use my own private node" choice, kept for the next run
/// in `<beam root>/private_node.json` (next to the node's own data, so a
/// "delete everything" of the BEAM folder removes it too).
///
/// Until the user has chosen, it reads as [defaultValue]: on for desktop,
/// off elsewhere (phones cannot run the node).
///
/// **Tor.** `beam-node` talks to many BEAM peers directly, not through Tor
/// (it has no proxy option). So while Campfire's Tor is on the node is off,
/// whatever the default or a choice made with Tor off says. It runs only if
/// the user turned it on *while Tor was on*, which is stored alongside the
/// choice (`"tor": true`). The node panel says why it is off.
///
/// It is a [BeamPrivateNodeSetting], so the wallet environment can hand it
/// to every coordinator. Not a secret: it holds one boolean (two with Tor).
class BeamPrivateNodePreference implements BeamPrivateNodeSetting {
  BeamPrivateNodePreference({
    required this._beamRoot,
    bool? defaultValue,
    bool Function()? torEnabled,
  }) : defaultValue =
           defaultValue ??
           BeamFixedPrivateNodeSetting.platformDefault().enabled,
       _torEnabled = torEnabled ?? campfireTorEnabled;

  /// The app's BEAM folder (`StackFileSystem.applicationBeamDirectory`).
  factory BeamPrivateNodePreference.app() => BeamPrivateNodePreference(
    beamRoot: () async =>
        (await StackFileSystem.applicationBeamDirectory()).path,
  );

  static const String fileName = 'private_node.json';

  final Future<String> Function() _beamRoot;
  final bool Function() _torEnabled;

  /// What [read] answers before the user has chosen (with Tor off).
  final bool defaultValue;

  /// Campfire's Tor is on now: the private node stays off unless it was
  /// turned on with Tor on.
  bool get torEnabled => _torEnabled();

  static final StreamController<bool> _changes =
      StreamController<bool>.broadcast();

  /// Every [write], from any instance. Broadcast.
  static Stream<bool> get changes => _changes.stream;

  Future<File> _file() async => File(p.join(await _beamRoot(), fileName));

  /// The stored choice, or [defaultValue]. A missing or unreadable file is
  /// the default, never an error. With Tor on: true only for a choice made
  /// with Tor on.
  @override
  Future<bool> read() async {
    final tor = torEnabled;
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['enabled'] is bool) {
          final enabled = decoded['enabled'] as bool;
          return tor ? enabled && decoded['tor'] == true : enabled;
        }
      }
    } catch (_) {
      // Fall through to the default.
    }
    return tor ? false : defaultValue;
  }

  /// Stores [enabled] (atomically: a temp file renamed over the old one).
  /// Turning the node on while Tor is on records that, so it stays on under
  /// Tor.
  Future<void> write(bool enabled) async {
    final root = await _beamRoot();
    await ensurePrivateDir(root);
    final target = File(p.join(root, fileName));
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'enabled': enabled, if (enabled && torEnabled) 'tor': true}),
      flush: true,
    );
    await tmp.rename(target.path);
    if (!_changes.isClosed) _changes.add(enabled);
  }
}
