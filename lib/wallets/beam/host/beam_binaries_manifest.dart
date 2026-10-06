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
        '6319a8f862de232e24395680a0b0d0948a627f915e5b9abb510c067537b53bfb',
    'wallet-api':
        '9d121e64066ec01e0626f2132f50da33bccf02adc9362c1c343af64db6c146f4',
    'beam-node':
        '8fb4dd9ac7c7bc95d7f0bf2ab067fe6f646b53b38cab96b22e3433b65de7ad6b',
  },
  'linux-arm64': {
    'beam-wallet':
        '3a0fa1c14494680d334b838b2ab69e536d71dac69c8641ba14b68d9b5091dff1',
    'wallet-api':
        '6cd49cb4c23f8de5f9d0fc19fb603148fcfba450414fd94ae7153fe7e87a4b25',
    'beam-node':
        'e5317ac88a8b0d8ffb0ecbd75ccb59c189c3122db7aebdfb00880c6ce863be59',
  },
  'linux-x86_64': {
    'beam-wallet':
        '8d388c96728caf931a5d76baa126da42961728d2398136b64851b33175bb3615',
    'wallet-api':
        'f8f41c5e137d07b4f21d45c412b54e6806f77209d90f81dbfd542a24aef3540c',
    'beam-node':
        'd20218c9f3805ec9fa3c9c5a492d3501f1a19850f8fa54b5553d0be95984832d',
  },
  // Android: wallet-api only (phones never run the private node), packaged
  // as jniLibs/<abi>/libbeam_wallet_api.so and run from nativeLibraryDir.
  'android-arm64': {
    'wallet-api':
        'c1da9ae7f18a7dbbe7fbf99d6c9dafc2ff6f0bb293e0344c8fb076eeb9251f3d',
  },
  'android-x86_64': {
    'wallet-api':
        '22d02e68c74fec724caf2c1c8445342d6006077c139a345aca68862df28c178d',
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
