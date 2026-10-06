/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Pinned SHA-256 of every BEAM binary Campfire may run, keyed by
/// `<os>-<arch>` (see `BeamBinaries.currentPlatform`) and then by binary name
/// without extension (`beam-wallet`, `wallet-api`, `beam-node`).
///
/// `BeamBinaries` hashes a binary before every launch and refuses to run it
/// when its platform, its name or its hash is missing here. Nothing is ever
/// downloaded or updated at runtime; changing a binary means changing this
/// file in a reviewed commit.
///
/// The `macos-arm64` values are the self-built HF6 binaries (tag
/// `beam-7.5.14493`, reporting version 7.5.1) that BEAM Light Wallet ships
/// today. Their `wallet-api` and `beam-node` listen on 0.0.0.0. Task B-BIN-1
/// replaces these values with its loopback-patched builds and adds the Linux
/// and Windows entries.
const Map<String, Map<String, String>> kBeamBinaryManifest = {
  'macos-arm64': {
    'beam-wallet':
        'c694187b4b5e00afb30d2106a2bfd4303462af37f8764afee7c28abfdc1adebb',
    'wallet-api':
        '46856bebcef045173fbe39c7c75efc34b74f80fb1e02761fb977b5bf6453c82e',
    'beam-node':
        'd5aadc3f3758f1ff9bd433915c08d0e81c9388b11b84ec94d0f7eade2adb5a57',
  },
};

/// The Fork6 entry of BEAM's `Rules::get_SignatureStr()` on mainnet. A binary
/// whose rules lack it stalls at block 3928665 forever (HF6, 2026-06-30).
const String kBeamHf6RulesFork = '3928666-96df3f33ee02ad9e';
