/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/airdrop/airdrop.dart';

/// Keeps a voucher code readable while it is typed or pasted: upper case,
/// letters and digits only, grouped `XXXX-XXXX-…`, as the contract
/// normalises it. Whatever the user pastes (spaces, line breaks, a
/// sentence around the code) ends up as the code alone.
class VoucherCodeFormatter extends TextInputFormatter {
  const VoucherCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = AirdropVoucherCode.format(newValue.text);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// How voucher codes are printed: Inter with even digits and a little air
/// between symbols, so `8` and `B` are told apart.
TextStyle voucherCodeStyle(BuildContext context, {double size = 16}) =>
    STextStyles.w600_14(context).copyWith(
      fontSize: size,
      letterSpacing: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: Theme.of(context).extension<StackColors>()!.textDark,
    );
