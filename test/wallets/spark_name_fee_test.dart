import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/wallet/wallet_mixin_interfaces/spark_interface.dart';
import 'package:stackwallet/wl_gen/interfaces/lib_spark_interface.dart';

import '../app_config_test_utils.dart';

// No direct import of flutter_libsparkmobile: the package only exists in builds
// configured with the FIRO flag, and importing it would stop this file from
// loading anywhere else. The library is reached through the app's own
// generated `libSpark` interface instead, and the cases that need it are
// skipped when the flag is off. The script, fee and version-number cases are
// plain Dart and run in every configuration.
void main() {
  test('Spark Name validation rejects underscores before construction', () {
    // libSpark.nameRegexString is flutter_libsparkmobile's kNameRegexString,
    // and is what the app validates names with.
    final pattern = RegExp(libSpark.nameRegexString);
    expect(pattern.hasMatch('NAME-FOR.TESTING'), isTrue);
    expect(pattern.hasMatch('NAME_FOR_TESTING'), isFalse);
  }, skip: skipUnlessFiro);

  test('Spark Name fee output includes the name and address tag', () {
    final baseScript = Uint8List(25);
    final feeScript = sparkNameFeeScript(
      baseScript: baseScript,
      name: 'alice',
      sparkAddress: List.filled(144, 'a').join(),
    );

    expect(feeScript.length - baseScript.length, 155);
    expect(feeScript.length, 180);
    expect(feeScript[25], OP_SPARKNAMEID);
    expect(feeScript[32], OP_DROP);
    expect(feeScript.last, OP_DROP);
  });

  test('Spark Name payments never have the miner fee subtracted', () {
    expect(
      shouldSubtractSparkFeeFromAmount(
        isSparkNameRegistration: true,
        spendsAll: true,
      ),
      isFalse,
    );
    expect(
      shouldSubtractSparkFeeFromAmount(
        isSparkNameRegistration: false,
        spendsAll: true,
      ),
      isTrue,
    );
  });

  group('Spark H2 activation', () {
    test('mainnet uses V1 before the activation block', () {
      final version = sparkSpendVersionForNextBlock(
        network: CryptoCurrencyNetwork.main,
        nextBlockHeight: 1370999,
      );

      expect(version, LibSparkSpendVersion.chaumV1);
      expect(version.allowsMultipleInputs, isFalse);
      expect(version.transactionVersion, 3 | (9 << 16));
    }, skip: skipUnlessFiro);

    test('mainnet uses V2 at activation and later', () {
      for (final nextBlockHeight in [1371000, 1371001]) {
        final version = sparkSpendVersionForNextBlock(
          network: CryptoCurrencyNetwork.main,
          nextBlockHeight: nextBlockHeight,
        );

        expect(version, LibSparkSpendVersion.chaumV2);
        expect(version.allowsMultipleInputs, isTrue);
        expect(version.transactionVersion, 3 | (11 << 16));
      }
    }, skip: skipUnlessFiro);

    test('non-mainnet networks remain on V1', () {
      for (final network in CryptoCurrencyNetwork.values.where(
        (network) => network != CryptoCurrencyNetwork.main,
      )) {
        expect(
          sparkSpendVersionForNextBlock(
            network: network,
            nextBlockHeight: 1371000,
          ),
          LibSparkSpendVersion.chaumV1,
        );
      }
    });

    test('only the Chaum V2 transaction version permits multiple inputs', () {
      expect(
        isChaumV2SparkTransactionVersion(
          LibSparkSpendVersion.chaumV1.transactionVersion,
        ),
        isFalse,
      );
      expect(
        isChaumV2SparkTransactionVersion(
          LibSparkSpendVersion.chaumV2.transactionVersion,
        ),
        isTrue,
      );
    });
  });
}
