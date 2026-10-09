/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge's two BEAM app shaders, pinned by SHA-256 and size.
//
// Both are BeamMW's own, byte-identical at apps.beam.mw
// (`beam-bridge-app/pipe_app.wasm`, `beam-bridge-reverse-app/pipe_app.wasm`)
// and inside the pinned beam-ui dApp packages of the same names
// (`dapp_catalogue.dart`). The forward one is built from
// BeamMW/beam-bridge-pipe@fd5b2a67 (`shaders/pipe_app.cpp`); the reverse
// one's contract source is not public.

import '../../../bridge/bridge_routes.dart';
import '../common/pinned_shader.dart';

const kPipeAppShaderName = 'pipe_app.wasm';
const kPipeAppShaderSha256 =
    '6a2ca541ac14e20cdeb55f432bf3d5ee273547844bc92853f1d1282fa6f9a9c3';
const kPipeAppShaderSize = 7840;

const kPipeReverseAppShaderName = 'pipe_reverse_app.wasm';
const kPipeReverseAppShaderSha256 =
    '6310f8af645dc85e093ab975209a60ca1b71197d92841c78fdac70088341415e';
const kPipeReverseAppShaderSize = 5876;

/// The pinned app shader that drives [shader]'s pipes, read from [source].
PinnedShader pipeAppShader(BridgeShader shader, ShaderSource source) =>
    switch (shader) {
      BridgeShader.forward => PinnedShader(
        name: kPipeAppShaderName,
        sha256: kPipeAppShaderSha256,
        size: kPipeAppShaderSize,
        source: source,
      ),
      BridgeShader.reverse => PinnedShader(
        name: kPipeReverseAppShaderName,
        sha256: kPipeReverseAppShaderSha256,
        size: kPipeReverseAppShaderSize,
        source: source,
      ),
    };
