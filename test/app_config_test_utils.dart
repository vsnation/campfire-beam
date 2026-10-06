// Upstream wrote its tests against Stack Wallet's configuration: every coin and
// every build flag. White-label builds (Campfire, the BEAM-only Campfire) ship
// fewer of both, so a test that hard-codes a coin or links a coin library fails
// there for reasons that say nothing about the code under test.
//
// These helpers let a test follow the configured app instead:
// - behaviour that does not depend on the coin runs against a coin the build
//   ships ([configuredCoinOr]);
// - behaviour that only exists with a build flag is skipped, with the reason,
//   when the flag is off ([skipUnlessFiro]).
// Under the Stack Wallet configuration both resolve to what the test always
// used, so nothing is lost there.

import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wl_gen/interfaces/lib_spark_interface.dart';

/// [preferred] when this build ships it, otherwise the first main-net coin it
/// does ship. [where] excludes coins the test cannot use.
CryptoCurrency configuredCoinOr(
  CryptoCurrency preferred, {
  bool Function(CryptoCurrency coin)? where,
}) {
  bool usable(CryptoCurrency coin) => where?.call(coin) ?? true;

  if (AppConfig.coins.contains(preferred) && usable(preferred)) {
    return preferred;
  }
  return AppConfig.coins.firstWhere(
    (coin) => coin.network == CryptoCurrencyNetwork.main && usable(coin),
    orElse: () => throw StateError(
      'No usable main-net coin in this build: '
      '${AppConfig.coins.map((e) => e.identifier).join(", ")}',
    ),
  );
}

/// Whether this build links the Firo Spark library (the `FIRO` flag of
/// `tool/process_pubspec_deps.dart` and `tool/gen_interfaces.dart`). Without
/// it the generated `libSpark` getter throws "FIRO not enabled!". Any other
/// error is rethrown so a broken build is not mistaken for a smaller one.
final bool isFiroLibraryEnabled = () {
  try {
    return libSpark.nameRegexString.isNotEmpty;
  } on Exception catch (e) {
    if (e.toString().contains('FIRO not enabled')) return false;
    rethrow;
  }
}();

/// `skip:` value for a test that needs the Firo Spark library.
String? get skipUnlessFiro => isFiroLibraryEnabled
    ? null
    : 'needs the Firo Spark library; this build is configured without the '
          'FIRO flag';
