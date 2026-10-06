/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

/// One gibibyte. Disk sizes in this file are binary, the way `df -h` and the
/// live node measurements report them (node.db reached 7.55 of these after
/// a full fast sync, PROGRESS.md B-NODE-2a run 3).
const int kBeamGiB = 1024 * 1024 * 1024;

/// Free space on the volume that holds the private node, and how much the
/// node already stores there.
class BeamNodeDiskSpace {
  const BeamNodeDiskSpace({required this.freeBytes, required this.nodeBytes});

  /// Bytes the user may still write on that volume.
  final int freeBytes;

  /// Bytes already in the node's directory (`node.db` and friends). A node
  /// that synced before only needs room for the blocks since then.
  final int nodeBytes;

  @override
  bool operator ==(Object other) =>
      other is BeamNodeDiskSpace &&
      other.freeBytes == freeBytes &&
      other.nodeBytes == nodeBytes;

  @override
  int get hashCode => Object.hash(freeBytes, nodeBytes);

  @override
  String toString() =>
      'BeamNodeDiskSpace(free ${formatBeamDiskSize(freeBytes)}, '
      'node ${formatBeamDiskSize(nodeBytes)})';
}

/// Measures the node's volume. Returns null when it cannot tell; the caller
/// then decides without numbers.
typedef BeamNodeDiskProbe = Future<BeamNodeDiskSpace?> Function();

/// How much room the private node needs. Never fill the disk.
///
/// Measured on mainnet (2026-10-06): a fresh node's folder ends at 7.55 GiB,
/// but peaks at ≥ 11.42 GiB while BEAM raises its "fossil" height right
/// after fast sync. So a fresh node starts only with room for that peak plus
/// [reserveBytes] for everything else (≈ 14 GiB with the defaults); a node
/// that finished its setup before only needs room for new blocks; and a
/// running node is stopped once free space falls under [stopBelowBytes].
class BeamNodeDiskPolicy {
  const BeamNodeDiskPolicy({
    this.setupPeakBytes = 12 * kBeamGiB,
    this.nodeBytes = 8 * kBeamGiB,
    this.settledBytes = 7 * kBeamGiB,
    this.catchUpBytes = kBeamGiB ~/ 2,
    this.reserveBytes = 2 * kBeamGiB,
    this.stopBelowBytes = 2 * kBeamGiB,
  });

  /// The most the node folder holds while it sets up (measured 11.42 GiB,
  /// rounded up).
  final int setupPeakBytes;

  /// What it holds once set up (measured 7.55 GiB, rounded up; the chain
  /// grows).
  final int nodeBytes;

  /// A folder at least this big belongs to a node that finished its setup
  /// before (or was stopped during its peak): it only grows by new blocks.
  final int settledBytes;

  /// Room for the blocks a set-up node catches up on.
  final int catchUpBytes;

  /// Space left free for the rest of the computer.
  final int reserveBytes;

  /// A running node is stopped below this much free space.
  final int stopBelowBytes;

  /// How much the folder may still grow, given what it holds now.
  int growthBytes(int existingNodeBytes) => existingNodeBytes >= settledBytes
      ? catchUpBytes
      : math.max(0, setupPeakBytes - existingNodeBytes);

  /// Free bytes needed before the node may start.
  int neededToStart(int existingNodeBytes) =>
      growthBytes(existingNodeBytes) + reserveBytes;

  bool allowsStart(BeamNodeDiskSpace s) =>
      s.freeBytes >= neededToStart(s.nodeBytes);

  bool mustStop(BeamNodeDiskSpace s) => s.freeBytes < stopBelowBytes;

  /// The numbers the node panel and its messages show for [s].
  BeamNodeDiskCheck check(BeamNodeDiskSpace s) => BeamNodeDiskCheck(
    space: s,
    growthBytes: growthBytes(s.nodeBytes),
    reserveBytes: reserveBytes,
    setupPeakBytes: setupPeakBytes,
    nodeBytes: nodeBytes,
    freshNode: s.nodeBytes < settledBytes,
  );
}

/// One measurement judged against a [BeamNodeDiskPolicy].
class BeamNodeDiskCheck {
  const BeamNodeDiskCheck({
    required this.space,
    required this.growthBytes,
    required this.reserveBytes,
    required this.setupPeakBytes,
    required this.nodeBytes,
    required this.freshNode,
  });

  final BeamNodeDiskSpace space;

  /// How much the node folder may still grow.
  final int growthBytes;

  /// Space kept free for everything else.
  final int reserveBytes;

  /// The setup peak and the settled size (for "about 12 GB while it sets
  /// up, then about 8 GB").
  final int setupPeakBytes;
  final int nodeBytes;

  /// The node has not finished its setup yet (it will reach the peak).
  final bool freshNode;

  /// Free space the node needs before it may start.
  int get neededFreeBytes => growthBytes + reserveBytes;

  /// How much the user has to free up; 0 when there is room.
  int get shortfallBytes => math.max(0, neededFreeBytes - space.freeBytes);

  bool get allowsStart => shortfallBytes == 0;

  @override
  bool operator ==(Object other) =>
      other is BeamNodeDiskCheck &&
      other.space == space &&
      other.growthBytes == growthBytes &&
      other.reserveBytes == reserveBytes &&
      other.setupPeakBytes == setupPeakBytes &&
      other.nodeBytes == nodeBytes &&
      other.freshNode == freshNode;

  @override
  int get hashCode => Object.hash(
    space,
    growthBytes,
    reserveBytes,
    setupPeakBytes,
    nodeBytes,
    freshNode,
  );

  @override
  String toString() =>
      'BeamNodeDiskCheck($space, needs ${formatBeamDiskSize(neededFreeBytes)})';
}

/// "8 GB", "37.2 GB", "750 MB": binary units with the labels people know.
String formatBeamDiskSize(int bytes) {
  if (bytes < kBeamGiB) {
    final mb = (bytes / (1024 * 1024)).round();
    return '$mb MB';
  }
  final gb = bytes / kBeamGiB;
  if (gb >= 10) return '${gb.round()} GB';
  final text = gb.toStringAsFixed(1);
  final trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  return '$trimmed GB';
}

/// Disk measurements with the operating system's own tools.
abstract final class BeamNodeDisk {
  /// A probe for a node stored in [nodeDir] (which may not exist yet).
  static BeamNodeDiskProbe probe(String nodeDir) => () async {
    final free = await freeBytes(nodeDir);
    if (free == null) return null;
    return BeamNodeDiskSpace(
      freeBytes: free,
      nodeBytes: await directoryBytes(nodeDir),
    );
  };

  /// Free bytes on the volume holding [path] (or its nearest existing
  /// parent), or null when the system does not say.
  static Future<int?> freeBytes(String path) async {
    try {
      final at = _existingAncestor(p.normalize(p.absolute(path)));
      if (Platform.isWindows) return await _windowsFree(at);
      final df = File('/bin/df').existsSync() ? '/bin/df' : 'df';
      final r = await Process.run(df, ['-Pk', at]);
      if (r.exitCode != 0) return null;
      final kb = parseDfAvailableKb('${r.stdout}');
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

  /// The "Available" column of `df -Pk` output, in KiB. Parsed from the
  /// capacity column (`NN%`) leftwards, because a filesystem name or a mount
  /// point may contain spaces.
  static int? parseDfAvailableKb(String output) {
    final lines = output
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final tokens = lines.last.split(RegExp(r'\s+'));
    for (var i = 2; i < tokens.length; i++) {
      if (RegExp(r'^\d+%$').hasMatch(tokens[i])) {
        return int.tryParse(tokens[i - 1]);
      }
    }
    return null;
  }

  /// Total size of the files under [dir]; 0 when it does not exist. Links
  /// are not followed.
  static Future<int> directoryBytes(String dir) async {
    var total = 0;
    try {
      final d = Directory(dir);
      if (!await d.exists()) return 0;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } on FileSystemException {
            // Gone while counting.
          }
        }
      }
    } on FileSystemException {
      // Unreadable: count what was seen.
    }
    return total;
  }

  static String _existingAncestor(String path) {
    var at = path;
    while (!Directory(at).existsSync() && !File(at).existsSync()) {
      final parent = p.dirname(at);
      if (parent == at) break;
      at = parent;
    }
    return at;
  }

  static Future<int?> _windowsFree(String path) async {
    final drive = p.rootPrefix(path).replaceAll(RegExp(r'[\\/]'), '');
    // Only a bare drive letter reaches the command line.
    if (!RegExp(r'^[A-Za-z]:$').hasMatch(drive)) return null;
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-PSDrive -Name ${drive[0]}).Free',
    ]);
    if (r.exitCode != 0) return null;
    return int.tryParse('${r.stdout}'.trim());
  }
}
