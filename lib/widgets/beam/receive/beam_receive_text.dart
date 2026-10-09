/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:intl/intl.dart';

import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import 'beam_private_receive.dart';

/// Every word the BEAM receive screens show, in one place.
///
/// Plain language only: never "SBBS", "voucher",
/// "Lelantus", "shielded" or "token". Each address type is described by
/// what it does for the person being paid.
abstract final class BeamReceiveText {
  // ------------------------------------------------------------ receive

  static const yourAddress = 'Your BEAM address';
  static const regularExplainer =
      "The sender's wallet and yours must both be online to finish the "
      'payment.';
  static const copy = 'Copy address';
  static const copied = 'Address copied';
  static const share = 'Share';
  static const newAddress = 'New address';
  static const newAddressReady = 'New address ready. Your old one still works.';
  static const allAddresses = 'See all your addresses';

  static const gettingAddress = 'Getting your address…';
  static const gettingAddressSlow =
      'Connecting to the BEAM network. This usually takes a few seconds.';
  static const cantGetAddress = "Can't get your address right now";
  static const tryAgain = 'Try again';
  static const offlineWarning =
      'Campfire is not connected right now. A payment to this address '
      'finishes once it reconnects.';

  // --------------------------------------------------------------- name

  static const yourName = 'Your name';
  static const nameExplainer =
      'People can pay this name instead of an address.';
  static const nameCopied = 'Name copied';

  // ---------------------------------------------------- more ways to receive

  static const moreWays = 'More ways to receive';
  static const moreWaysHint =
      'Get paid while your wallet is closed, or more '
      'privately';
  static const needsPrivateNode = 'These need your private node';
  static const openNodeSettings = 'Open Node settings';
  static const making = 'Making your address…';

  /// Title of an address type, as a person would say it.
  static String typeTitle(BeamAddressType type) => switch (type) {
    BeamAddressType.regular => 'Regular address',
    BeamAddressType.regularNew => 'Regular address (with payment proof)',
    BeamAddressType.offline => 'Offline address',
    BeamAddressType.maxPrivacy => 'Max privacy address',
    BeamAddressType.publicOffline => 'Public address',
    BeamAddressType.unknown => 'Other address',
  };

  /// Short label for lists.
  static String typeLabel(BeamAddressType type) => switch (type) {
    BeamAddressType.regular => 'Regular',
    BeamAddressType.regularNew => 'Regular, with proof',
    BeamAddressType.offline => 'Offline',
    BeamAddressType.maxPrivacy => 'Max privacy',
    BeamAddressType.publicOffline => 'Public',
    BeamAddressType.unknown => 'Other',
  };

  /// What the address does for the person being paid.
  static String typeExplainer(BeamAddressType type) => switch (type) {
    BeamAddressType.regular || BeamAddressType.regularNew => regularExplainer,
    BeamAddressType.offline =>
      'Works while your wallet is closed. Good for one payment.',
    BeamAddressType.maxPrivacy =>
      'Hides the payment among many others; takes longer. Use it once.',
    BeamAddressType.publicOffline =>
      'Safe to post publicly. Payments arrive even while your wallet is '
          'closed.',
    BeamAddressType.unknown => '',
  };

  /// Why the private types are off, and whether Node settings helps.
  static ({String reason, bool showNodeSettings}) privateReason(
    BeamPrivateReceive gate,
  ) => switch (gate.block) {
    null => (reason: '', showNodeSettings: false),
    BeamPrivateReceiveBlock.connecting => (
      reason:
          'Campfire is still connecting to the BEAM network. These options '
          'unlock in a few seconds if your private node is on.',
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.notOnThisDevice => (
      reason:
          "They need Campfire's private node, which runs on computers. Use "
          'your regular address above.',
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.nodeOff => (
      reason:
          'Turn on your private node in Node settings — it takes about 2 '
          'hours the first time.',
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeStarting => (
      reason:
          'Your private node is starting. These unlock when it has '
          "downloaded BEAM's history — about 2 hours the first time.",
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeDownloading => (
      reason:
          "Your private node is downloading BEAM's history"
          '${gate.percent == null ? '' : ' (${gate.percent}% done)'}. '
          'These unlock when it finishes.',
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeCatchingUp => (
      reason:
          'Your private node is almost ready: it is catching up on the '
          'newest blocks.',
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeSwitching => (
      reason: 'Moving your wallet to your private node. This takes a moment.',
      showNodeSettings: false,
    ),
    BeamPrivateReceiveBlock.nodeConfirming => (
      reason:
          "Waiting for your private node to confirm it holds this wallet's "
          'key.',
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeProblem => (
      reason:
          "Your private node isn't running right now, so Campfire is using a "
          'public node. Open Node settings to see why.',
      showNodeSettings: true,
    ),
    BeamPrivateReceiveBlock.nodeServingOtherWallet => (
      reason:
          'Your private node is serving another of your wallets. These '
          'unlock here when that wallet closes.',
      showNodeSettings: true,
    ),
  };

  // ------------------------------------------------------- address list

  static const active = 'Active';
  static String expiredCount(int n) => 'Expired ($n)';
  static const noLabel = 'No label';
  static const onReceive = 'Shown on Receive';
  static const editLabel = 'Edit label';
  static const delete = 'Delete';
  static const cancel = 'Cancel';
  static const saveLabel = 'Save label';
  static const labelHint = 'e.g. From Alex';
  static const labelSaved = 'Label saved';
  static const deleteTitle = 'Delete this address?';
  static const deleteMessage =
      "Payments sent to it after this won't reach your wallet. Your balance "
      'and past payments stay as they are.';
  static const deleted = 'Address deleted';
  static const noAddresses = 'No addresses yet';
  static const noAddressesHint =
      'Make one now and share it with whoever is paying you.';
  static const getMyAddress = 'Get my address';
  static const cantShowAddresses = "Can't show your addresses yet";

  static final DateFormat _date = DateFormat('d MMM y');

  /// "Created 22 Jun 2024 · Never expires" and the like.
  static String lifetime(BeamAddress a) {
    final created = 'Created ${_date.format(a.createdAt.toLocal())}';
    final ends = a.expiresAt;
    if (ends == null) return '$created · Never expires';
    final when = _date.format(ends.toLocal());
    return a.expired ? '$created · Expired $when' : '$created · Expires $when';
  }

  /// First and last characters, for lists where the full address is one
  /// tap away.
  static String short(String address, {int keep = 10}) =>
      address.length <= keep * 2 + 1
      ? address
      : '${address.substring(0, keep)}…'
            '${address.substring(address.length - keep)}';

  // ------------------------------------------------------------- errors

  /// What went wrong, in words that never blame the person, with the fix.
  static String error(Object e) {
    if (e is BeamRpcException) {
      if (e.code == -32005) {
        return "Your wallet isn't on your private node right now, so this "
            "address type can't be made. Use your regular address, or try "
            'again once Node settings shows the private node is on.';
      }
      final m = e.message.toLowerCase();
      if (m.contains('active transaction') || m.contains('in use')) {
        return 'A payment to this address is still in progress. Try again '
            'when it finishes.';
      }
      return 'The wallet could not do that just now. Try again in a moment.';
    }
    if (e is BeamConnectionException) {
      return 'Campfire is still connecting to the BEAM network. Try again in '
          'a few seconds.';
    }
    if (e is TimeoutException) {
      return 'The BEAM network is slow to answer. Try again in a moment.';
    }
    return 'Something went wrong on our side. Try again in a moment.';
  }
}
