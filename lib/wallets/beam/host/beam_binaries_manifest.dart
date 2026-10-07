/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Pinned SHA-256 of every BEAM binary Campfire ships, keyed by `<os>-<arch>`
/// (see `BeamBinaries.currentPlatform`) and then by binary name without
/// extension (`beam-wallet`, `wallet-api`, `beam-node`).
///
/// These are the Campfire builds from `scripts/beam/core` (tag
/// `beam-7.5.14493`, version 7.5.14493, `the project notes`): wallet-api
/// and beam-node listen on 127.0.0.1 only, and wallet-api accepts
/// `--privileged_shader_sha256`. `BeamBinaries` hashes a binary before every
/// launch and refuses anything not pinned. Nothing is downloaded or updated
/// at runtime; changing a binary means changing this file in a reviewed
/// commit, together with `scripts/beam/core/manifest.json`.
const Map<String, Map<String, String>> kBeamBinaryManifest = {
  'macos-arm64': {
    'beam-wallet':
        '7c982d03134a05435d237f85f762381303d99e0008721f59fbe8b806e489e1bc',
    'wallet-api':
        'fd9b912eea5f59228ef8630725765ad7d50fedf69fca348bd80982d5cb4036cb',
    'beam-node':
        '8fb4dd9ac7c7bc95d7f0bf2ab067fe6f646b53b38cab96b22e3433b65de7ad6b',
  },
  'linux-arm64': {
    'beam-wallet':
        '400d460025f4b7aa7cef35ee8882d41b01cbcda19dee457802663a8bf0b56697',
    'wallet-api':
        '20230bc35f9aa7d8e406a746a556f1e7acffa12ebdb4cc445fe2fccadc21ec9a',
    'beam-node':
        '6c1c43ec9d8aff2d5f793d993491cda7cc04b66f7fecc1d29b8e0242666d5a61',
  },
  'linux-x86_64': {
    'beam-wallet':
        '403f34e65b88510b4dd6f900f5cb385e5b8d6e95b6958badd14af715e080444b',
    'wallet-api':
        '166f26ab35ef32a6f74170fa0dc3c0bcf107ba23e9cd732fdd0efae47c990048',
    'beam-node':
        '8a88a3f671459d95b759c4239397cdab629b452f9db7394748da75abc20bc7d4',
  },
  'windows-x86_64': {
    'beam-wallet':
        'a5acd1258a2bbda59f16f798cf11505d5df2b1d5b2e5ab8cfcf156e37d18da44',
    'wallet-api':
        'f9866d2be93d0528826347629105ea177e495f1fe16982c5e98ce4a5e3edf201',
    'beam-node':
        'c999ee432cd155cf21adcd9135c2c697b30adda173e55454adea870bd43f79d1',
  },
  // Android: beam-wallet (create/restore) and wallet-api; phones never run
  // the private node. Packaged as jniLibs/<abi>/libbeam_wallet.so and
  // libbeam_wallet_api.so and run from nativeLibraryDir
  // (scripts/beam/core/android/build_wallet_api.sh, the project notes).
  'android-arm64': {
    'beam-wallet':
        '735c63507df14069a374121f768cd0ecbbc63086055e6daaebd14aa887291e08',
    'wallet-api':
        '54696bbabae9abae8dc516648a8b74ddab8a5b472da93d8f3ba1695020c0c8c7',
  },
  'android-x86_64': {
    'beam-wallet':
        '4732cf6a282d9fc0c7525a533289ebabf8a5d5714ee190ddc461edead3ab60dd',
    'wallet-api':
        'da18f333c8871d7d55abfafb6ffc71e5ffc161ca408102bfdc8b30abc4018a06',
  },
};

/// Development-only pins, accepted solely when `BEAM_BIN_DIR` is set: the
/// stock-bind HF6 binaries BEAM Light Wallet ships (tag `beam-7.5.14493`,
/// reporting 7.5.1). They listen on 0.0.0.0 and know no
/// `--privileged_shader_sha256`, so a wallet on them cannot claim BANS
/// payments. An installed app never sets `BEAM_BIN_DIR`, so it never runs
/// these.
const Map<String, Map<String, String>> kBeamDevBinaryManifest = {
  'macos-arm64': {
    'beam-wallet':
        'c694187b4b5e00afb30d2106a2bfd4303462af37f8764afee7c28abfdc1adebb',
    'wallet-api':
        '46856bebcef045173fbe39c7c75efc34b74f80fb1e02761fb977b5bf6453c82e',
    'beam-node':
        'd5aadc3f3758f1ff9bd433915c08d0e81c9388b11b84ec94d0f7eade2adb5a57',
  },
};

/// App shaders the Campfire wallet-api may run at privilege 1. BANS needs it
/// to find and claim payments sent to the user's names (`get_PkEx`,
/// `get_BlindSk`); every other shader, including any dApp's, stays at 0.
/// Must equal `kBansShaderSha256` (a test checks it).
const List<String> kBeamPrivilegedShaderSha256s = [
  '99eb1dfb023d30c338e3c4a4c536b7695b48ca25e27f9ce5f659b6567241736d',
];

/// The Fork6 entry of BEAM's `Rules::get_SignatureStr()` on mainnet. A binary
/// whose rules lack it stalls at block 3928665 forever (HF6, 2026-06-30).
const String kBeamHf6RulesFork = '3928666-96df3f33ee02ad9e';
