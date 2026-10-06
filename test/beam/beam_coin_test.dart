/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/utilities/beam_app_identity.dart';
import 'package:stackwallet/utilities/default_nodes.dart';
import 'package:stackwallet/wallets/beam/address/beam_address_format.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wl_gen/interfaces/libbeam_interface.dart';

// x of the secp256k1 generator: a public constant that is a curve point.
const _gx = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
// The field prime: not a valid x.
const _p = 'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f';

Map<String, Object?> _vectors() => (jsonDecode(
  File('test/beam/fixtures/beam_core_address_vectors.json').readAsStringSync(),
) as Map).cast<String, Object?>();

List<Map<String, Object?>> _list(String key) => [
  for (final e in _vectors()[key]! as List) (e as Map).cast<String, Object?>(),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final beam = Beam(CryptoCurrencyNetwork.main);

  group('constants', () {
    test('identity', () {
      expect(beam.identifier, 'beam');
      expect(beam.mainNetId, 'beam');
      expect(beam.ticker, 'BEAM');
      expect(beam.prettyName, 'Beam');
      expect(beam.uriScheme, 'beam');
    });

    test('amounts, seed and blocks', () {
      expect(beam.fractionDigits, 8);
      expect(beam.satsPerCoin, BigInt.from(100000000));
      expect(beam.defaultSeedPhraseLength, 12);
      expect(beam.possibleMnemonicLengths, [12]);
      expect(beam.hasMnemonicPassphraseSupport, isFalse);
      expect(beam.hasBuySupport, isFalse);
      expect(beam.hasTokenSupport, isFalse);
      expect(beam.torSupport, isFalse);
      expect(beam.targetBlockTimeSeconds, 60);
      expect(beam.minConfirms, 1);
      expect(beam.minCoinbaseConfirms, 240);
      expect(beam.defaultAddressType, AddressType.mimbleWimble);
      expect(() => beam.defaultDerivePathType, throwsUnsupportedError);
    });

    test('mainnet only', () {
      expect(() => Beam(CryptoCurrencyNetwork.test), throwsException);
      expect(Beam(CryptoCurrencyNetwork.main), beam);
    });
  });

  group('node and explorer', () {
    test('default node is the current public mainnet name', () {
      final node = beam.defaultNode(isPrimary: true);
      expect(node.host, 'eu-nodes.mainnet.beam.mw');
      expect(node.port, 8100);
      expect(node.useSSL, isFalse);
      expect(node.id, 'default_beam');
      expect(node.name, DefaultNodes.defaultName);
      expect(node.coinName, 'beam');
      expect(node.enabled, isTrue);
      expect(node.torEnabled, isFalse);
      expect(node.clearnetEnabled, isTrue);
      expect(node.isPrimary, isTrue);
      expect(beam.defaultNode(isPrimary: false).isPrimary, isFalse);
    });

    test('alternates follow the default', () {
      expect(Beam.mainnetNodes.map((e) => e.toString()), [
        'eu-nodes.mainnet.beam.mw:8100',
        'us-nodes.mainnet.beam.mw:8100',
      ]);
    });

    test('explorer link takes a kernel id', () {
      const kernel =
          'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
      expect(
        beam.defaultBlockExplorer(kernel).toString(),
        'https://explorer.beam.mw/block?kernel_id=$kernel',
      );
    });
  });

  group('BEAM core test vectors', () {
    for (final v in _list('valid')) {
      final address = v['address']! as String;
      final type = BeamAddressType.fromWire(v['type']! as String);
      test('accepts ${type.wireName} (${address.length} chars)', () {
        expect(beam.validateAddress(address), isTrue);
        expect(beam.getAddressType(address), AddressType.mimbleWimble);
        expect(beam.beamAddressType(address), type);
      });
    }

    for (final v in _list('invalid')) {
      final address = v['address']! as String;
      test('rejects: ${v['why']}', () {
        expect(beam.validateAddress(address), isFalse);
        expect(beam.getAddressType(address), isNull);
        expect(beam.beamAddressType(address), isNull);
      });
    }

    test('rejects base58 tokens with a character added or dropped', () {
      for (final v in _list('valid')) {
        final address = v['address']! as String;
        if (v['type'] == 'regular') {
          continue;
        }
        expect(beam.validateAddress('${address}z'), isFalse, reason: address);
        expect(
          beam.validateAddress(address.substring(0, address.length - 1)),
          isFalse,
          reason: address,
        );
      }
    });
  });

  group('regular (hex SBBS) addresses', () {
    test('channel below 1024 and a curve point', () {
      expect(BeamAddressFormat.typeOf('2a$_gx'), BeamAddressType.regular);
      // Odd length: the leading zero nibble is stripped when encoding.
      expect(BeamAddressFormat.typeOf('3$_gx'), BeamAddressType.regular);
      expect(BeamAddressFormat.isValid('3ff$_gx'), isTrue);
      expect(BeamAddressFormat.isValid(_gx), isTrue); // channel 0
      expect(BeamAddressFormat.isValid('2A${_gx.toUpperCase()}'), isTrue);
    });

    test('channel 1024 and above', () {
      expect(BeamAddressFormat.isValid('400$_gx'), isFalse);
      expect(BeamAddressFormat.isValid('010000000000002a$_gx'), isFalse);
    });

    test('key that is not a valid x', () {
      expect(BeamAddressFormat.isValid('2a$_p'), isFalse);
      expect(BeamAddressFormat.isValid('2a${'0' * 64}'), isFalse);
    });

    test('lengths and characters', () {
      expect(BeamAddressFormat.isValid(''), isFalse);
      expect(BeamAddressFormat.isValid('2'), isFalse);
      expect(BeamAddressFormat.isValid('11'), isFalse); // zero WalletID
      expect(BeamAddressFormat.isValid(' 2a$_gx'), isFalse);
      expect(BeamAddressFormat.isValid('2a$_gx '), isFalse);
      expect(BeamAddressFormat.isValid('0x2a$_gx'), isFalse);
      expect(BeamAddressFormat.isValid('beam:2a$_gx'), isFalse);
      expect(BeamAddressFormat.isValid('1' * 20000), isFalse);
    });

    test('shorter than 60 hex characters', () {
      // Both keys are curve points with channel 0; the core takes both.
      expect(BeamAddressFormat.isValid('1${'0' * 58}1'), isTrue); // 60
      expect(BeamAddressFormat.isValid('1${'0' * 58}'), isFalse); // 59
    });

    test('a WalletID written in base58 is not an address', () {
      // The core would parse it; no BEAM wallet writes it.
      expect(BeamAddressFormat.isValid(_base58(_walletId(5, _gx))), isFalse);
    });

    test('other coins are rejected', () {
      expect(
        beam.validateAddress('bc1qc5ymmsay89r6gr4fy2kklvrkuvzyln4shdvjhf'),
        isFalse,
      );
      // Firo, Bitcoin legacy: base58check, 25 bytes.
      for (final base58check in [
        'a8VV7vMzJdTQj1eLEJNskhLEBUxfNWhpAg',
        '1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2',
      ]) {
        expect(beam.validateAddress(base58check), isFalse);
      }
      // Ethereum without 0x: 40 hex.
      expect(
        beam.validateAddress('742d35cc6634c0532925a3b844bc454e4438f44e'),
        isFalse,
      );
    });
  });

  group('synthetic tokens', () {
    final peerAddr = _param(7, _walletId(5, _gx));
    final endpoint = _param(21, _hexBytes(_gx));
    final simple = _param(0, [1, 0]);
    final push = _param(0, [1, 7]);
    // Real sizes: a voucher is 226 bytes, a public generator 193.
    final voucherBytes = List.filled(226, 7);
    final version = _param(127, List.filled(40, 0x31)); // LibraryVersion

    test('regular_new needs a valid PeerAddr', () {
      expect(_type([simple, peerAddr]), BeamAddressType.regularNew);
      expect(_type([peerAddr]), BeamAddressType.regularNew);
      expect(_type([simple, version]), isNull);
      final permanent = _param(8, [1]);
      final permanentTooLong = _param(8, [1, 0]);
      expect(_type([simple, peerAddr, permanent]), isNotNull);
      expect(_type([simple, peerAddr, permanentTooLong]), isNull);
      expect(_type([simple, _param(7, _walletId(1024, _gx))]), isNull);
      expect(_type([simple, _param(7, _walletId(5, _p))]), isNull);
    });

    test('offline, max privacy, public offline', () {
      final twoVouchers = _param(124, [0x82, ...voucherBytes, ...voucherBytes]);
      final noVouchers = _param(124, [0x80]);
      final voucher = _param(125, voucherBytes);
      final publicGen = _param(123, List.filled(193, 3));
      expect(
        _type([push, peerAddr, endpoint, twoVouchers]),
        BeamAddressType.offline,
      );
      expect(_type([push, endpoint, voucher]), BeamAddressType.maxPrivacy);
      expect(_type([push, publicGen]), BeamAddressType.publicOffline);
      expect(_type([push, endpoint, noVouchers, version]), isNull);
      expect(_type([push, voucher, version]), isNull); // no endpoint
    });

    test('vouchers and generators must have their serialized size', () {
      final shortVoucher = _param(125, [0x81]);
      expect(_type([push, endpoint, shortVoucher]), isNull);
      final longVoucher = _param(125, [...voucherBytes, 0]);
      expect(_type([push, endpoint, longVoucher]), isNull);
      // Claims two vouchers, holds one.
      final shortList = _param(124, [0x82, ...voucherBytes]);
      expect(_type([push, peerAddr, endpoint, shortList]), isNull);
      expect(_type([push, _param(123, List.filled(192, 3))]), isNull);
    });

    test('a tx id is skipped', () {
      expect(
        _type([simple, peerAddr], txId: List.filled(16, 0xab)),
        BeamAddressType.regularNew,
      );
    });

    test('malformed structure', () {
      expect(_type([simple, peerAddr], trailing: [0]), isNull);
      expect(_type([simple, _param(21, List.filled(31, 1)), peerAddr]), isNull);
      final atomicSwap = _param(0, [1, 1]);
      final contract = _param(0, [1, 12]);
      final badEnumSize = _param(0, [0]);
      expect(_type([atomicSwap, peerAddr]), isNull);
      expect(_type([contract, peerAddr]), isNull);
      expect(_type([badEnumSize, peerAddr]), isNull);
      expect(
        BeamAddressFormat.typeOf(
          _base58([0x80, 0, 0x82, ...simple]), // claims 2 parameters, has 1
        ),
        isNull,
      );
      expect(
        BeamAddressFormat.typeOf(
          _base58([0x80, 2, 0x81, ...simple, ...List.filled(40, 0)]),
        ),
        isNull,
      );
    });
  });

  group('build wiring', () {
    test('the configured app knows the coin and ships the core', () {
      expect(AppConfig.getCryptoCurrencyFor('beam'), beam);
      expect(libBeam.isAvailable, isTrue);
    });

    test('never shares a data or side folder with a real Campfire', () {
      expect(AppConfig.appDefaultDataDirName, isNot('campfire'));
      if (BeamAppIdentity.isActive) {
        expect(AppConfig.appDefaultDataDirName, 'campfirebeam');
        expect(BeamAppIdentity.folderStem, 'Campfire_BEAM');
      } else {
        expect(BeamAppIdentity.folderStem, AppConfig.prefix);
      }
    });

    test('the Campfire theme has the BEAM colour and icons', () async {
      final archive = ZipDecoder().decodeBytes(
        File('asset_sources/default_themes/campfire/light.zip')
            .readAsBytesSync(),
      );
      final theme = (jsonDecode(
        utf8.decode(archive.findFile('theme.json')!.content),
      ) as Map).cast<String, Object?>();
      final colors = (theme['colors']! as Map)['coin']! as Map;
      // Campfire's own coin colour (the owner kept Campfire's look).
      expect(colors['beam'], colors['firo']);

      final coins = (theme['assets']! as Map)['coins']! as Map;
      for (final kind in ['icons', 'images', 'secondaries']) {
        final path = (coins[kind]! as Map)['beam'];
        expect(path, isA<String>(), reason: kind);
        final file = archive.findFile('assets/$path');
        expect(file, isNotNull, reason: 'assets/$path');
        final content = file!.content as List<int>;
        if ((path as String).endsWith('.png')) {
          // The Beam girl images are PNGs (scripts/beam/theme).
          expect(content.take(8), [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
          ], reason: path);
          continue;
        }
        // flutter_svg must be able to compile it.
        final bytes = await SvgStringLoader(utf8.decode(content))
            .loadBytes(null);
        expect(bytes.lengthInBytes, greaterThan(0), reason: path);
      }
    });
  });
}

// --- helpers that build tokens the way the core serializes them ------------

BeamAddressType? _type(
  List<List<int>> params, {
  List<int>? txId,
  List<int> trailing = const [],
}) => BeamAddressFormat.typeOf(
  _base58([
    0x80,
    if (txId == null) 0 else ...[1, ...txId],
    ..._compact(params.length),
    for (final p in params) ...p,
    ...trailing,
  ]),
);

List<int> _param(int id, List<int> value) => [
  1, // enum size
  id,
  ..._compact(value.length),
  ...value,
];

List<int> _compact(int v) {
  if (v < 128) {
    return [0x80 | v];
  }
  final bytes = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    bytes.add(x & 0xff);
  }
  return [bytes.length, ...bytes];
}

List<int> _walletId(int channel, String keyHex) => [
  for (var i = 7; i >= 0; i--) (channel >> (8 * i)) & 0xff,
  ..._hexBytes(keyHex),
];

List<int> _hexBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _base58(List<int> bytes) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  final out = StringBuffer();
  final base = BigInt.from(58);
  while (n > BigInt.zero) {
    out.write(alphabet[(n % base).toInt()]);
    n = n ~/ base;
  }
  final zeros = bytes.takeWhile((b) => b == 0).length;
  return '1' * zeros + out.toString().split('').reversed.join();
}
