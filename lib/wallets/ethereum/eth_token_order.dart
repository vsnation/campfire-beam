/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../app_config.dart';
import '../../models/isar/models/ethereum/eth_contract.dart';

/// [tokens] with the build's default tokens first, in the build's order
/// (WBEAM first in Campfire for BEAM), then the others as they came (by
/// name, from the database).
List<EthContract> defaultEthTokensFirst(
  List<EthContract> tokens, {
  List<EthContract>? defaults,
}) {
  final order = [
    for (final t in defaults ?? AppConfig.defaultEthTokens)
      t.address.toLowerCase(),
  ];
  int rank(EthContract t) {
    final i = order.indexOf(t.address.toLowerCase());
    return i < 0 ? order.length : i;
  }

  return [
    for (var r = 0; r < order.length; r++) ...tokens.where((t) => rank(t) == r),
    ...tokens.where((t) => rank(t) == order.length),
  ];
}
