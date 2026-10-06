/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';

import 'dex_fixtures.dart';

void main() {
  test('integers stay exact beyond 2^63-1 and 2^53', () {
    final out = ShaderOutput.decode(
      '{"res": {"tok1": 18446744073709551615,"tok2": 9007199254740993,'
      '"neg": -5,"zero": 0}}',
    );
    final res = ShaderOutput.map(out['res'], 'res');
    expect(res['tok1'], BigInt.parse('18446744073709551615'));
    expect(ShaderOutput.amount(res, 'tok1'), (BigInt.one << 64) - BigInt.one);
    expect(res['tok2'], BigInt.parse('9007199254740993'));
    expect(res['neg'], BigInt.from(-5));
    expect(res['zero'], BigInt.zero);
    expect(() => ShaderOutput.amount(res, 'neg'), throwsFormatException);
  });

  test('strings, including digits, quotes and escapes, are untouched', () {
    final out = ShaderOutput.decode(
      r'{"k1_2": "0.123","t": "say \"42\" -7","u": "a\\","n": [1, "2", 3.5],'
      r'"b": true,"x": null,"e": 1e3}',
    );
    expect(out['k1_2'], '0.123');
    expect(out['t'], 'say "42" -7');
    expect(out['u'], r'a\');
    expect(out['n'], [BigInt.one, '2', 3.5]);
    expect(out['b'], isTrue);
    expect(out['x'], isNull);
    expect(out['e'], 1000.0);
  });

  test('a root error becomes BeamShaderException', () {
    for (final f in ['error_no_such_pool', 'error_invalid_kind']) {
      expect(
        () => ShaderOutput.decode(dexOutput(f)),
        throwsA(isA<BeamShaderException>()),
      );
    }
    expect(
      () => ShaderOutput.decode(dexOutput('add_both_too_large')),
      throwsA(
        isA<BeamShaderException>().having(
          (e) => e.message,
          'message',
          'val1 too large',
        ),
      ),
    );
  });

  test('non-objects and broken JSON are FormatExceptions', () {
    expect(() => ShaderOutput.decode('[1]'), throwsFormatException);
    expect(() => ShaderOutput.decode('{"a": '), throwsFormatException);
    expect(() => ShaderOutput.decode(''), throwsFormatException);
  });

  test('typed reads check ranges', () {
    final m = ShaderOutput.decode('{"a": 4294967295,"b": 4294967296,"s": 1}');
    expect(ShaderOutput.uint32(m, 'a'), 4294967295);
    expect(() => ShaderOutput.uint32(m, 'b'), throwsFormatException);
    expect(() => ShaderOutput.string(m, 's'), throwsFormatException);
    expect(ShaderOutput.optAmount(m, 'missing'), isNull);
  });

  test('the recorded pools_view decodes', () {
    final out = ShaderOutput.decode(dexOutput('pools_view'));
    expect(ShaderOutput.list(out['res'], 'res'), hasLength(97));
  });
}
