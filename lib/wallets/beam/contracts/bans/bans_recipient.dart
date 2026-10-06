/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../address/beam_address_format.dart';
import '../../models/beam_address.dart';
import 'bans_exceptions.dart';
import 'bans_name.dart';
import 'bans_service.dart';
import 'bans_timeline.dart';

/// What the Send screen's recipient field holds. One field takes both a
/// BEAM address and a BANS name, so the user never has to pick a mode.
sealed class BeamRecipientInput {
  const BeamRecipientInput();

  /// Reads [text]. A well-formed address always wins: a 64-character hex
  /// address is also a syntactically valid name, and treating it as one
  /// would send money somewhere the user did not paste.
  static BeamRecipientInput classify(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const BeamRecipientEmpty();
    final type = BeamAddressFormat.typeOf(trimmed);
    if (type != null) return BeamRecipientAddress(trimmed, type);
    final candidate = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
    final normalised = BansName.normalise(candidate);
    final name = BansName.tryParse(normalised);
    if (name != null) return BeamRecipientName(name);
    return BeamRecipientInvalid(BansName.check(normalised));
  }
}

final class BeamRecipientEmpty extends BeamRecipientInput {
  const BeamRecipientEmpty();
}

final class BeamRecipientAddress extends BeamRecipientInput {
  const BeamRecipientAddress(this.address, this.type);
  final String address;
  final BeamAddressType type;
}

final class BeamRecipientName extends BeamRecipientInput {
  const BeamRecipientName(this.name);
  final BansName name;
}

/// Neither an address nor a possible name. [nameProblem] says why it is not
/// a name, so the field can say "Names use a-z, 0-9, _ - ~" rather than a
/// bare "invalid".
final class BeamRecipientInvalid extends BeamRecipientInput {
  const BeamRecipientInvalid(this.nameProblem);
  final BansNameProblem? nameProblem;
}

/// The resolution card under the recipient field.
sealed class BansRecipientState {
  const BansRecipientState(this.name);
  final BansName name;
}

final class BansRecipientResolving extends BansRecipientState {
  const BansRecipientResolving(super.name);
}

/// Payments to [name] are accepted. The card shows who will receive them;
/// the payment re-resolves before it is built and again before signing.
final class BansRecipientPayable extends BansRecipientState {
  const BansRecipientPayable(super.name, this.resolution);

  final BansResolution resolution;

  String get ownerKey => resolution.ownerKey!;

  /// Short, comparable form of the owner key for the card ("72e3…51ef").
  String get ownerFingerprint {
    final k = ownerKey;
    if (k.length <= 12) return k;
    return '${k.substring(0, 4)}…${k.substring(k.length - 4)}';
  }

  /// Expired but in its 90-day hold: payments still reach the owner, who
  /// may not renew. The card warns before the user sends.
  bool get onHold => resolution.status == BansNameStatus.onHold;

  /// Read while the wallet was behind; the card says the answer may be old.
  bool get maybeStale => !resolution.walletInSync;
}

/// Nobody owns [name], or its owner let it lapse past the hold. The vault
/// refuses payments to it, so sending is not offered.
final class BansRecipientNotPayable extends BansRecipientState {
  const BansRecipientNotPayable(super.name, this.status);
  final BansNameStatus status;
}

final class BansRecipientFailed extends BansRecipientState {
  const BansRecipientFailed(super.name, this.error);
  final Object error;
}

/// Turns typing into resolution cards: waits for a pause, resolves the
/// newest name only, and drops answers to text the user has already
/// changed, so a slow lookup can never overwrite a newer one.
class BansRecipientResolver {
  BansRecipientResolver(
    this._resolve, {
    this.debounce = const Duration(milliseconds: 400),
  });

  /// Normally `BeamBansService.resolve`.
  final Future<BansResolution> Function(BansName name) _resolve;
  final Duration debounce;

  final _states = StreamController<BansRecipientState?>.broadcast();
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  /// Null when the field holds no name (empty, an address, or invalid).
  Stream<BansRecipientState?> get states => _states.stream;

  /// Call on every change of the recipient field.
  void input(String text) {
    if (_disposed) return;
    _timer?.cancel();
    final generation = ++_generation;
    final parsed = BeamRecipientInput.classify(text);
    if (parsed is! BeamRecipientName) {
      _states.add(null);
      return;
    }
    _states.add(BansRecipientResolving(parsed.name));
    _timer = Timer(debounce, () => _lookup(parsed.name, generation));
  }

  Future<void> _lookup(BansName name, int generation) async {
    BansRecipientState state;
    try {
      final r = await _resolve(name);
      state = r.status.canReceivePayments && r.ownerKey != null
          ? BansRecipientPayable(name, r)
          : BansRecipientNotPayable(name, r.status);
    } catch (e) {
      state = BansRecipientFailed(name, e);
    }
    if (_disposed || generation != _generation) return;
    _states.add(state);
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    await _states.close();
  }
}
