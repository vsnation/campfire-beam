/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../dapp_consent.dart';

/// A [DappConsentQueue] the approval sheet can watch, to say "2 more
/// requests waiting" while one is on screen.
///
/// It only observes: queueing, throttling, cancelling and the one-at-a-time
/// rule are the core queue's, unchanged.
class DappWatchedConsentQueue extends DappConsentQueue {
  DappWatchedConsentQueue(super.policy, {super.maxPendingPerDapp});

  final ValueNotifier<int> _pending = ValueNotifier<int>(0);

  /// Requests waiting or on screen.
  ValueListenable<int> get pending => _pending;

  /// Requests waiting behind the one on screen.
  int get waitingBehindCurrent => pendingCount > 0 ? pendingCount - 1 : 0;

  @override
  Future<bool> request(DappConsentRequest request, {Object? owner}) {
    final result = super.request(request, owner: owner);
    _changed();
    // The queue moves on before the result's listeners run, so the count
    // read here already includes the next request on screen.
    unawaited(
      result.then<void>(
        (_) => _changed(),
        onError: (Object _) {
          _changed();
        },
      ),
    );
    return result;
  }

  @override
  void cancel(Object owner) {
    super.cancel(owner);
    _changed();
  }

  @override
  void cancelAll(String dappGuid) {
    super.cancelAll(dappGuid);
    _changed();
  }

  void _changed() => _pending.value = pendingCount;
}
