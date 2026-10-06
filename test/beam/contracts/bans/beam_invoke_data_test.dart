// Decoding invoke_contract raw_data (bvm2::ContractInvokeData, yas compacted)
// and the core's contract fee rules, on real recorded kernels.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/common/contract_args.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';

import 'bans_fixtures.dart';

/// yas compacted unsigned.
List<int> u(int v) {
  if (v < 128) return [0x80 | v];
  final b = <int>[];
  var x = v;
  while (x > 0) {
    b.add(x & 0xff);
    x >>= 8;
  }
  return [b.length, ...b];
}

/// yas compacted signed.
List<int> s(int v) {
  final neg = v < 0;
  final a = v.abs();
  if (a < 64) return [(neg ? 0x80 : 0) | 0x40 | a];
  final b = <int>[];
  var x = a;
  while (x > 0) {
    b.add(x & 0xff);
    x >>= 8;
  }
  return [(neg ? 0x80 : 0) | b.length, ...b];
}

List<int> blob(List<int> b) => [...u(b.length), ...b];

/// One plain entry: method, args, no sigs, charge, comment, spend, cid.
List<int> entry({
  int method = 7,
  List<int> args = const [1, 2, 3],
  int charge = 80150,
  String comment = 'c',
  Map<int, int> spend = const {0: 1000},
  List<int>? cid,
}) => [
  ...u(method),
  ...blob(args),
  ...u(0),
  ...u(charge),
  ...blob(comment.codeUnits),
  ...u(spend.length),
  for (final e in spend.entries) ...[...u(e.key), ...s(e.value)],
  ...(cid ?? List.filled(32, 0xab)),
];

void main() {
  group('recorded kernels', () {
    test('register, 13-char name, 1 period', () {
      final d = BeamInvokeData.decode(bansRaw('register5'));
      expect(d.entries, hasLength(1));
      final e = d.entries.single;
      expect(e.flags, 0);
      expect(e.method, BansMethod.register);
      expect(e.contractId, kBansCid);
      expect(e.charge, 80150);
      expect(e.comment, BansKernelComment.register);
      expect(e.signatureCount, 0);
      expect(e.spend, {0: BigInt.from(116213166091)});
      // Register args: pkOwner[33] periods[1] nameLen[1] name
      final r = BeamArgsReader(e.args);
      expect(r.pubKey(), fakeMyKey);
      expect(r.u8(), 1);
      final len = r.u8();
      expect(String.fromCharCodes(r.bytes(len)), quotedName5);
      expect(r.atEnd, isTrue);
      expect(d.spend, {0: BigInt.from(116213166091)});
      expect(d.fee, BigInt.from(1100000));
    });

    test('register, 4-char name, 2 periods', () {
      final d = BeamInvokeData.decode(bansRaw('register4'));
      final e = d.entries.single;
      expect(e.spend, {0: BigInt.from(2789115986201)});
      final r = BeamArgsReader(e.args)..pubKey();
      expect(r.u8(), 2);
      expect(String.fromCharCodes(r.bytes(r.u8())), quotedName4);
      expect(d.fee, BigInt.from(1100000));
    });

    test('kernel amounts are floor(usd * 1e8 * n / median) at 0.008604877', () {
      // Oracle2 median on the explorer at h 4068102 was 0.008604877.
      BigInt price(int usd, int n) =>
          BigInt.from(usd) *
          BigInt.from(n) *
          BigInt.from(10).pow(8) *
          BigInt.from(10).pow(9) ~/
          BigInt.from(8604877);
      expect(
        BeamInvokeData.decode(bansRaw('register5')).spend[0],
        price(10, 1),
      );
      expect(
        BeamInvokeData.decode(bansRaw('register4')).spend[0],
        price(120, 2),
      );
    });

    test('buy a listed name pays the listing', () {
      final d = BeamInvokeData.decode(bansRaw('buy_listed'));
      final e = d.entries.single;
      expect(e.method, BansMethod.buy);
      expect(e.comment, BansKernelComment.buy);
      expect(e.spend, {0: BigInt.from(10000000000000)});
      final r = BeamArgsReader(e.args);
      expect(r.pubKey(), fakeMyKey);
      expect(String.fromCharCodes(r.bytes(r.u8())), 'nephrite');
      expect(d.fee, BigInt.from(1100000));
    });

    test('pay goes to the Anon-Vault, not the BANS contract', () {
      final d = BeamInvokeData.decode(bansRaw('pay_beam'));
      final e = d.entries.single;
      expect(e.contractId, vaultCid);
      expect(e.method, BansMethod.vaultDeposit);
      expect(e.charge, 0);
      expect(e.comment, BansKernelComment.pay);
      expect(e.spend, {0: BigInt.from(12345)});
      // Deposit: amount u64, sizeCustom u32, pkOneTime[33], aid u32,
      // then custom = pkSender[33] + encrypted name[64].
      final r = BeamArgsReader(e.args);
      expect(r.u64(), BigInt.from(12345));
      expect(r.u32(), 97);
      expect(r.pubKey(), isNot(beamOwnerKey)); // one-time key, not the owner
      expect(r.u32(), 0);
      expect(r.remaining, 97);
      // charge 0 still pays the BVM minimum
      expect(d.fee, BigInt.from(1100000));
    });
  });

  group('encoding edge cases', () {
    test('multi-byte and negative compacted integers', () {
      final bytes = [
        ...u(1),
        ...entry(
          charge: 0x123456,
          spend: {0: -150000000, 174: 63, 3: -64},
        ),
      ];
      final e = BeamInvokeData.decode(bytes).entries.single;
      expect(e.charge, 0x123456);
      expect(e.spend, {
        0: BigInt.from(-150000000),
        174: BigInt.from(63),
        3: BigInt.from(-64),
      });
    });

    test('several entries: spends add up, fees add up', () {
      final bytes = [
        ...u(2),
        ...entry(spend: {0: 500}),
        ...entry(spend: {0: 700, 7: 9}),
      ];
      final d = BeamInvokeData.decode(bytes);
      expect(d.spend, {0: BigInt.from(1200), 7: BigInt.from(9)});
      // second entry: 2 outputs -> still under the 100,000 floor
      expect(d.fee, BigInt.from(2 * 1100000));
    });

    test('fee rules: BEAM change output, big charges, extra arg bytes', () {
      BeamInvokeEntry one(List<int> bytes) =>
          BeamInvokeData.decode([...u(1), ...bytes]).entries.single;
      // no BEAM spend: one asset output + one BEAM change output
      expect(
        one(entry(spend: {7: 5})).fee,
        BigInt.from(100000 + 1000000),
      );
      // charge above the minimum: 10 groth per unit
      expect(
        one(entry(charge: 300000)).fee,
        BigInt.from(100000 + 3000000),
      );
      // 40,000 argument bytes: 7,232 above the free 32 KiB at 50 each
      expect(
        one(entry(args: List.filled(40000, 1))).fee,
        BigInt.from(18000 + 10000 + 7232 * 50 + 1000000),
      );
    });

    test('flags: an advanced entry carries its own fee', () {
      final bytes = [
        ...u(1),
        ...u(0x80000000 | BeamInvokeData.flagAdvanced),
        ...u(3),
        ...blob([9]),
        ...u(0),
        ...u(0),
        ...blob('vault_anon receive'.codeUnits),
        ...u(1),
        ...u(0),
        ...s(-480000000000),
        ...List.filled(32, 0xa3),
        ...u(4068103), // hMin
        ...u(15), // dh
        ...u(1100000), // fee
        ...List.filled(65, 1), // sig
        ...List.filled(32, 2), // hvSk
      ];
      // Only a caller that expects advanced entries (BANS claims) reads one.
      expect(() => BeamInvokeData.decode(bytes), throwsFormatException);
      final d = BeamInvokeData.decode(bytes, allowAdvanced: true);
      final e = d.entries.single;
      expect(e.isAdvanced, isTrue);
      expect(e.method, 3);
      expect(e.minHeight, BigInt.from(4068103));
      expect(e.maxHeight, BigInt.from(4068118));
      expect(d.fee, BigInt.from(1100000));
      expect(d.spend, {0: BigInt.from(-480000000000)});
    });

    test('rejects trailing, truncated and absurd data', () {
      final good = [...u(1), ...entry()];
      expect(
        () => BeamInvokeData.decode([...good, 0]),
        throwsFormatException,
      );
      expect(
        () => BeamInvokeData.decode(good.sublist(0, good.length - 1)),
        throwsFormatException,
      );
      expect(() => BeamInvokeData.decode(const []), throwsFormatException);
      // a length far beyond the data
      expect(
        () => BeamInvokeData.decode([...u(1), ...u(7), 8, 0xff, 0xff, 0xff]),
        throwsFormatException,
      );
      // a 9-byte integer
      expect(
        () => BeamInvokeData.decode([9, ...List.filled(9, 1)]),
        throwsFormatException,
      );
      expect(
        () => BeamArgsReader(Uint8List(3)).u32(),
        throwsFormatException,
      );
    });
  });
}
