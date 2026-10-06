/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter.dart';

void main() {
  const cid = kMinterContractId;
  const g = BigInt.from;
  final meta = BeamTokenMetadata(
    name: 'Campfire Coin',
    shortName: 'CFC',
    unitName: 'CFC',
  );

  test('views, with no role (the Minter shader reads only action)', () {
    expect(MinterArgs.viewParams(), 'action=view_params,cid=$cid');
    expect(MinterArgs.viewOwned(), 'action=view_owned,cid=$cid');
    expect(
      MinterArgs.viewToken(assetId: 44),
      'action=view_token,cid=$cid,aid=44',
    );
    // aid=0 would list every token instead of one.
    expect(() => MinterArgs.viewToken(assetId: 0), throwsArgumentError);
  });

  test('create_token quotes the metadata and splits the limit', () {
    expect(
      MinterArgs.createToken(metadata: meta, limit: g(100000000000)),
      'action=create_token,cid=$cid,limit=100000000000,limitHi=0,'
      'metadata="STD:SCH_VER=1;N=Campfire Coin;SN=CFC;UN=CFC;NTHUN=groth;'
      'NTH_RATIO=100000000"',
    );
    final big = (BigInt.one << 64) * g(3) + g(5);
    expect(
      MinterArgs.createToken(metadata: meta, limit: big),
      contains('limit=5,limitHi=3,'),
    );
    expect(
      () => MinterArgs.createToken(metadata: meta, limit: BigInt.zero),
      throwsArgumentError,
    );
    expect(
      () => MinterArgs.createToken(metadata: meta, limit: BigInt.one << 128),
      throwsArgumentError,
    );
  });

  test('mint is the withdraw action, aid and value', () {
    expect(
      MinterArgs.mint(assetId: 4242, value: g(1)),
      'action=withdraw,cid=$cid,aid=4242,value=1',
    );
    expect(() => MinterArgs.mint(assetId: 0, value: g(1)), throwsArgumentError);
    expect(
      () => MinterArgs.mint(assetId: 1, value: BigInt.zero),
      throwsArgumentError,
    );
  });

  test(
    'the shader pin is the bundled file, byte-identical to the tag',
    () async {
      final bytes = await minterAppShader(
        const FileShaderSource('assets/beam/shaders'),
      ).load();
      expect(bytes, hasLength(kMinterAppShaderSize));
      expect(PinnedShader.digestOf(bytes), kMinterAppShaderSha256);
    },
  );

  test('fees from the declared charges', () {
    expect(kMinterCreateTokenFee, g(1670000));
    expect(kMinterMintFee, g(1100000));
    expect(kMinterAssetDeposit, g(1000000000));
  });
}
