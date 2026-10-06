/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/address_utils.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_white_container.dart';
import '../../stack_dialog.dart';
import 'beam_receive_text.dart';

/// Keys the tests and screenshots find widgets by.
abstract final class BeamReceiveKeys {
  static const qr = ValueKey('beamReceive.qr');
  static const address = ValueKey('beamReceive.address');
  static const copy = ValueKey('beamReceive.copy');
  static const share = ValueKey('beamReceive.share');
  static const newAddress = ValueKey('beamReceive.newAddress');
  static const explainer = ValueKey('beamReceive.explainer');
  static const nameCard = ValueKey('beamReceive.nameCard');
  static const moreWays = ValueKey('beamReceive.moreWays');
  static const privateReason = ValueKey('beamReceive.privateReason');
  static const openNodeSettings = ValueKey('beamReceive.openNodeSettings');
  static const allAddresses = ValueKey('beamReceive.allAddresses');
  static const tryAgain = ValueKey('beamReceive.tryAgain');
  static const dialogCopy = ValueKey('beamReceive.dialogCopy');
  static const dialogDone = ValueKey('beamReceive.dialogDone');
  static ValueKey<String> typeTile(BeamAddressType t) =>
      ValueKey('beamReceive.type.${t.wireName}');
  static ValueKey<String> nameCopy(String name) =>
      ValueKey('beamReceive.nameCopy.$name');
}

/// A Campfire card. On desktop the BEAM receive screens sit inside
/// Campfire's own white Send/Receive card, so their cards get the outline
/// `DesktopReceive` gives its address box; on phones they sit on the page
/// background and need none.
class BeamCard extends StatelessWidget {
  const BeamCard({
    super.key,
    required this.desktop,
    required this.child,
    this.onPressed,
    this.padding,
  });

  final bool desktop;
  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => RoundedWhiteContainer(
    padding: padding,
    onPressed: onPressed,
    borderColor: desktop
        ? Theme.of(context).extension<StackColors>()!.backgroundAppBar
        : null,
    child: child,
  );
}

/// The QR code of a BEAM address (`beam:<address>`, as BEAM's own wallets
/// write it), black on white like Campfire's. An address too long for any
/// QR code says so instead of failing.
class BeamReceiveQr extends StatelessWidget {
  const BeamReceiveQr({
    super.key,
    required this.address,
    required this.size,
    this.scheme = 'beam',
  });

  final String address;
  final double size;
  final String scheme;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: QrImageView(
      data: AddressUtils.buildUriString(scheme, address, {}),
      size: size,
      padding: const EdgeInsets.all(10),
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
      errorStateBuilder: (context, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'This address is too long for a QR code. Copy it instead.',
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle12(context),
          ),
        ),
      ),
    ),
  );
}

/// Copies [text] and confirms it, the way Campfire's receive screen does.
Future<void> beamCopy(
  BuildContext context,
  ClipboardInterface clipboard,
  String text, {
  String message = BeamReceiveText.copied,
}) async {
  unawaited(HapticFeedback.lightImpact());
  await clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  unawaited(
    showFloatingFlushBar(
      type: FlushBarType.info,
      message: message,
      iconAsset: Assets.svg.copy,
      context: context,
    ),
  );
}

/// A short note in the user's words, with an info icon.
class BeamNote extends StatelessWidget {
  const BeamNote(this.text, {super.key, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = warning ? colors.warningForeground : colors.textSubtitle1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: SvgPicture.asset(
            warning ? Assets.svg.alertCircle : Assets.svg.circleInfo,
            width: 14,
            height: 14,
            colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: STextStyles.itemSubtitle12(context).copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A new private address, ready to give out: what it does, its QR code,
/// copy and share.
Future<void> showBeamAddressDialog(
  BuildContext context, {
  required BeamAddressType type,
  required String address,
  required ClipboardInterface clipboard,
  required Future<void> Function(String text) share,
  required bool desktop,
}) => showDialog<void>(
  context: context,
  builder: (context) => StackDialogBase(
    width: desktop ? 460 : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          BeamReceiveText.typeTitle(type),
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          BeamReceiveText.typeExplainer(type),
          style: STextStyles.smallMed14(context),
        ),
        const SizedBox(height: 16),
        Center(child: BeamReceiveQr(address: address, size: 200)),
        const SizedBox(height: 12),
        // Long addresses are shortened in the middle; Copy and the QR
        // code carry the whole address.
        Text(
          BeamReceiveText.short(address, keep: 18),
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle12(context),
        ),
        const SizedBox(height: 16),
        PrimaryButton(
          key: BeamReceiveKeys.dialogCopy,
          label: BeamReceiveText.copy,
          buttonHeight: desktop ? ButtonHeight.l : null,
          onPressed: () => beamCopy(context, clipboard, address),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SecondaryButton(
                label: BeamReceiveText.share,
                buttonHeight: desktop ? ButtonHeight.l : null,
                onPressed: () => share(address),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SecondaryButton(
                key: BeamReceiveKeys.dialogDone,
                label: 'Done',
                buttonHeight: desktop ? ButtonHeight.l : null,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ],
    ),
  ),
);
