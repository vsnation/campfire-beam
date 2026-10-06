// BANS name and key rules, checked against the shader's own definition
// (`bvm/Shaders/bans/contract.h:41-51`, `app.cpp:252-272`).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_name.dart';

/// `Domain::IsValidChar`, transcribed from contract.h.
bool shaderIsValidChar(int c) {
  if (c == 0x5f || c == 0x2d || c == 0x7e) return true;
  return (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
}

void main() {
  group('BansName (strict, as stored on-chain)', () {
    test('accepts the shader charset and length range', () {
      for (final n in ['beam', 'abc', 'a-b_c~1', '0xredbeard', 'a' * 64]) {
        expect(BansName(n).value, n);
      }
    });

    test('rejects what the shader rejects, with the right problem', () {
      final cases = {
        '': BansNameProblem.empty,
        'ab': BansNameProblem.tooShort,
        'a' * 65: BansNameProblem.tooLong,
        'Beam': BansNameProblem.invalidCharacter,
        'alice.beam': BansNameProblem.invalidCharacter,
        'al ice': BansNameProblem.invalidCharacter,
        'a,b=c': BansNameProblem.invalidCharacter,
        'аlice': BansNameProblem.invalidCharacter, // Cyrillic a
        'café': BansNameProblem.invalidCharacter,
      };
      cases.forEach((input, problem) {
        expect(
          () => BansName(input),
          throwsA(
            isA<BansInvalidName>()
                .having((e) => e.problem, 'problem', problem)
                .having((e) => e.input, 'input', input),
          ),
          reason: input,
        );
        expect(BansName.tryParse(input), isNull, reason: input);
      });
    });

    test('every code unit 0..255 agrees with Domain::IsValidChar', () {
      for (var c = 0; c < 256; c++) {
        expect(BansName.isValidCodeUnit(c), shaderIsValidChar(c), reason: '$c');
      }
    });

    test('display form and tier', () {
      expect(BansName('alice').display, 'alice.beam');
      expect(BansName('abc').usdPerPeriod, 320);
      expect(BansName('abcd').usdPerPeriod, 120);
      expect(BansName('abcde').usdPerPeriod, 10);
      expect(BansName('a' * 64).usdPerPeriod, 10);
    });

    test('equality is by value', () {
      expect(BansName('beam'), BansName('beam'));
      expect(BansName('beam').hashCode, BansName('beam').hashCode);
      expect(BansName('beam') == BansName('beams'), isFalse);
    });
  });

  group('BansName.fromUserInput (lenient door for typed text)', () {
    test('trims, lower-cases and strips one .beam', () {
      expect(BansName.fromUserInput('  Alice.BEAM ').value, 'alice');
      expect(BansName.fromUserInput('ALICE').value, 'alice');
      expect(BansName.fromUserInput('alice.beam').value, 'alice');
      expect(BansName.normalise('a.beam.beam'), 'a.beam');
    });

    test('still enforces the shader rules after normalising', () {
      expect(
        () => BansName.fromUserInput('Ålice'),
        throwsA(isA<BansInvalidName>()),
      );
      expect(
        () => BansName.fromUserInput('ab.beam'),
        throwsA(
          isA<BansInvalidName>().having(
            (e) => e.problem,
            'problem',
            BansNameProblem.tooShort,
          ),
        ),
      );
    });

    test('limits are the contract constants', () {
      expect(kBansNameMinLength, 3);
      expect(kBansNameMaxLength, 64);
    });
  });

  group('BansKey', () {
    const beamKey =
        '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';

    test('accepts 33-byte keys with a 00/01 parity byte', () {
      expect(BansKey.isValid(beamKey), isTrue);
      expect(BansKey.require(beamKey.toUpperCase()), beamKey);
      expect(BansKey.require(' $beamKey '), beamKey);
    });

    test('rejects anything else, and the zero key', () {
      for (final k in [
        '',
        beamKey.substring(2),
        '${beamKey}00',
        '${beamKey.substring(0, 64)}02',
        '${'g' * 64}00',
        BansKey.zero,
      ]) {
        expect(
          () => BansKey.require(k),
          throwsA(isA<BansInvalidKey>()),
          reason: k,
        );
      }
    });

    test('fingerprint skips the parity byte', () {
      expect(BansKey.fingerprint(beamKey), '72e3…51ef');
    });
  });
}
