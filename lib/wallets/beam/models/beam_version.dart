/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_json.dart';

/// `get_version` (API 6.1+).
///
/// Self-built binaries from a shallow clone report `7.5.1`, not the tag's
/// build number: verify binaries by SHA-256, never by [beamVersion].
@immutable
class BeamVersion {
  const BeamVersion({
    required this.apiVersion,
    required this.apiVersionMajor,
    required this.apiVersionMinor,
    required this.beamVersion,
    required this.beamVersionMajor,
    required this.beamVersionMinor,
    required this.beamVersionRevision,
    required this.commitHash,
    required this.branchName,
    required this.networkName,
  });

  factory BeamVersion.fromJson(Map<String, Object?> json) => BeamVersion(
    apiVersion: BeamJson.string(json, 'api_version'),
    apiVersionMajor: BeamJson.integer(json, 'api_version_major'),
    apiVersionMinor: BeamJson.integer(json, 'api_version_minor'),
    beamVersion: BeamJson.string(json, 'beam_version'),
    beamVersionMajor: BeamJson.integer(json, 'beam_version_major'),
    beamVersionMinor: BeamJson.integer(json, 'beam_version_minor'),
    beamVersionRevision: BeamJson.integer(json, 'beam_version_rev'),
    commitHash: BeamJson.optString(json, 'beam_commit_hash') ?? '',
    branchName: BeamJson.optString(json, 'beam_branch_name') ?? '',
    networkName: BeamJson.optString(json, 'beam_network_name') ?? '',
  );

  final String apiVersion;
  final int apiVersionMajor;
  final int apiVersionMinor;
  final String beamVersion;
  final int beamVersionMajor;
  final int beamVersionMinor;
  final int beamVersionRevision;
  final String commitHash;
  final String branchName;

  /// `mainnet`, `testnet`, `dappnet`, …
  final String networkName;

  bool get isMainnet => networkName == 'mainnet';
}
