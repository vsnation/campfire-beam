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
import '../host/beam_binaries_manifest.dart';
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
/// **Tor.** With Campfire's Tor on, every connection goes through Tor or is
/// not made. The node talks to many BEAM peers, so with
/// Tor on it runs only on a core that routes its peers through Tor's SOCKS5
/// proxy ([nodeTorCapable], `kBeamCoreSupportsSocks`); on any other core it is
/// off while Tor is on, whatever was chosen, and the node panel says why. No
/// choice lets it run outside Tor while Tor is on.
///
/// It is a [BeamPrivateNodeSetting], so the wallet environment can hand it
/// to every coordinator. Not a secret: it holds one boolean (two with Tor).
class BeamPrivateNodePreference implements BeamPrivateNodeSetting {
  BeamPrivateNodePreference({
    required this._beamRoot,
    bool? defaultValue,
    bool Function()? torEnabled,
    bool Function()? nodeTorCapable,
  }) : defaultValue =
           defaultValue ??
           BeamFixedPrivateNodeSetting.platformDefault().enabled,
       _torEnabled = torEnabled ?? campfireTorEnabled,
       _nodeTorCapable = nodeTorCapable ?? (() => kBeamCoreSupportsSocks);

  /// The app's BEAM folder (`StackFileSystem.applicationBeamDirectory`).
  factory BeamPrivateNodePreference.app() => BeamPrivateNodePreference(
    beamRoot: () async =>
        (await StackFileSystem.applicationBeamDirectory()).path,
  );

  static const String fileName = 'private_node.json';

  final Future<String> Function() _beamRoot;
  final bool Function() _torEnabled;
  final bool Function() _nodeTorCapable;

  /// The core can route the node's peers through Tor.
  bool get nodeTorCapable => _nodeTorCapable();

  /// What [read] answers before the user has chosen (with Tor off).
  final bool defaultValue;

  /// Campfire's Tor is on now: the private node runs only through Tor.
  bool get torEnabled => _torEnabled();

  static final StreamController<bool> _changes =
      StreamController<bool>.broadcast();

  /// Every [write], from any instance. Broadcast.
  static Stream<bool> get changes => _changes.stream;

  Future<File> _file() async => File(p.join(await _beamRoot(), fileName));

  /// The stored choice, or [defaultValue]. A missing or unreadable file is
  /// the default, never an error. With Tor on and a core that cannot route
  /// the node through Tor: false, whatever is stored.
  @override
  Future<bool> read() async {
    if (torEnabled && !nodeTorCapable) return false;
    try {
      final file = await _file();
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['enabled'] is bool) {
          return decoded['enabled'] as bool;
        }
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
    await tmp.writeAsString(
      jsonEncode({'enabled': enabled}),
      flush: true,
    );
    await tmp.rename(target.path);
    if (!_changes.isClosed) _changes.add(enabled);
  }
}
