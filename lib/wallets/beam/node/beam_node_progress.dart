/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Typed progress of a `beam-node` child, parsed from its console output.
///
/// The markers come from BEAM's source at tag `beam-7.5.14493`
/// (research/02 §5.2):
///
/// * `Fast-sync mode up to block number N, TxoLo=M` (`processor.cpp:397`;
///   7.5.13882 printed `Fast-sync mode up to height N`)
/// * `Fast-sync failed: …`, `Fast-sync succeeded` (`processor.cpp:1916,
///   1959`)
/// * `Updating node: p% (done/total)`, in work units, not heights
///   (`cli.cpp:253`)
/// * `My Tip: <height>-<hash>, Work = …` (`node.cpp:695`)
/// * `Initial Tip: <height>-<hash>` (`node.cpp:1118`)
/// * `Tx replication is ON`, once, when done == total and fast sync is over
///   (`node.cpp:89`)
/// * `Owned accounts :`, then one tab-indented endpoint per owner key
///   (`node.cpp:1443`)
/// * `Raising Fossil...` (and the other `LongAction` steps: `Raising TxoLo`,
///   `Raising TxoHi`, `Rebuilding …`, `Rescanning …`), then every 10 s
///   `\tN%...` (`processor.cpp:2068`, `block_crypt.cpp:3784`). Measured
///   2026-10-06: after fast sync, `Raising Fossil` runs 5–10 minutes and the
///   node folder peaks at ≥ 11.42 GB before it shrinks to ~7.55 GB
/// * `key import failed`, after which the node exits with code 0
///   (`cli.cpp:265`)
///
/// There is no "fully synchronized" line in BEAM; LightWallet waited for one.
library;

/// Where a `beam-node` is in its life.
enum BeamNodePhase {
  /// Launched, and neither fast sync nor the tip has been reported: the
  /// node is fetching headers (a fresh node) or checking peers (a restart).
  starting,

  /// Fast sync is running: headers and the recent UTXO set are downloading.
  fastSyncDownloading,

  /// Fast sync is over and the node is applying the newest blocks, but it
  /// has not reported `Tx replication is ON` since.
  catchingUp,

  /// The node reports that it is at the tip: `Tx replication is ON` after
  /// the last fast-sync line, or — because BEAM logs that line only once
  /// per process (`node.cpp:85-87`) and a fresh node logs it during the
  /// header download, before fast sync even starts — its own
  /// `Updating node: 100% (n/n)` once fast sync is over. Never at height 0.
  /// Not proof by itself: the coordinator also compares
  /// [BeamNodeProgress.myTipHeight] with an explorer.
  txReplicationOn,

  /// Stopped on request.
  stopped,

  /// Failed or exited without being asked to; see
  /// [BeamNodeProgress.error].
  error,
}

/// Why a node failed.
enum BeamNodeError {
  /// The node did not accept the owner key (`key import failed`, no
  /// password, or no owned account listed). A node in this state would run
  /// without the key, so it is stopped instead.
  ownerKeyRejected,

  /// The node exited without being asked to.
  exited,

  /// The node never printed `Reading config from` for its config file.
  configNotRead,

  /// Another app instance is running a node on the same storage.
  nodeInUse,

  /// Its database is corrupted.
  corrupted,

  /// It could not listen on its P2P port.
  portUnavailable,
}

/// One snapshot of a node's progress. Immutable.
class BeamNodeProgress {
  const BeamNodeProgress({
    this.phase = BeamNodePhase.starting,
    this.percent,
    this.myTipHeight,
    this.myTipAt,
    this.initialTipHeight,
    this.fastSyncTarget,
    this.fastSyncFailures = 0,
    this.peersSeen = 0,
    this.ownerAccounts,
    this.error,
    this.errorDetail,
    this.exitCode,
    this.finishingPercent,
  });

  final BeamNodePhase phase;

  /// While the node runs one of its long maintenance steps after fast sync
  /// ("Raising Fossil" and friends): how far it is, 0-100. Null otherwise.
  final int? finishingPercent;

  /// `Updating node: p%`. Work units relative to the first value the node
  /// saw, not heights; good enough for "downloading (43%)".
  final int? percent;

  /// Height from the newest `My Tip:` line.
  final int? myTipHeight;

  /// When that line arrived (device clock).
  final DateTime? myTipAt;

  /// Height from `Initial Tip:` (what the node had on disk at start).
  final int? initialTipHeight;

  /// Block number fast sync is heading for, from `Fast-sync mode up to`.
  final int? fastSyncTarget;

  /// How many `Fast-sync failed` lines were seen. BEAM retries on its own.
  final int fastSyncFailures;

  /// Distinct peers that reported a tip since start. Not a live connection
  /// count: beam-node prints none at info level.
  final int peersSeen;

  /// How many owner keys the node lists under `Owned accounts :`, or null
  /// before that listing.
  final int? ownerAccounts;

  final BeamNodeError? error;

  /// A redacted, user-safe hint for [error]. Never contains a secret.
  final String? errorDetail;

  final int? exitCode;

  /// The handover marker: `Tx replication is ON` after the last fast-sync
  /// line.
  bool get txReplicationOn => phase == BeamNodePhase.txReplicationOn;

  bool get isEnded =>
      phase == BeamNodePhase.stopped || phase == BeamNodePhase.error;

  /// The best height the node has reported, from `My Tip:` or else
  /// `Initial Tip:`.
  int? get bestHeight => myTipHeight ?? initialTipHeight;

  BeamNodeProgress copyWith({
    BeamNodePhase? phase,
    int? percent,
    int? myTipHeight,
    DateTime? myTipAt,
    int? initialTipHeight,
    int? fastSyncTarget,
    int? fastSyncFailures,
    int? peersSeen,
    int? ownerAccounts,
    BeamNodeError? error,
    String? errorDetail,
    int? exitCode,
    int? finishingPercent,
    bool clearFinishing = false,
  }) => BeamNodeProgress(
    phase: phase ?? this.phase,
    percent: percent ?? this.percent,
    myTipHeight: myTipHeight ?? this.myTipHeight,
    myTipAt: myTipAt ?? this.myTipAt,
    initialTipHeight: initialTipHeight ?? this.initialTipHeight,
    fastSyncTarget: fastSyncTarget ?? this.fastSyncTarget,
    fastSyncFailures: fastSyncFailures ?? this.fastSyncFailures,
    peersSeen: peersSeen ?? this.peersSeen,
    ownerAccounts: ownerAccounts ?? this.ownerAccounts,
    error: error ?? this.error,
    errorDetail: errorDetail ?? this.errorDetail,
    exitCode: exitCode ?? this.exitCode,
    finishingPercent: clearFinishing
        ? null
        : finishingPercent ?? this.finishingPercent,
  );

  @override
  bool operator ==(Object other) =>
      other is BeamNodeProgress &&
      other.phase == phase &&
      other.percent == percent &&
      other.myTipHeight == myTipHeight &&
      other.myTipAt == myTipAt &&
      other.initialTipHeight == initialTipHeight &&
      other.fastSyncTarget == fastSyncTarget &&
      other.fastSyncFailures == fastSyncFailures &&
      other.peersSeen == peersSeen &&
      other.ownerAccounts == ownerAccounts &&
      other.error == error &&
      other.errorDetail == errorDetail &&
      other.exitCode == exitCode &&
      other.finishingPercent == finishingPercent;

  @override
  int get hashCode => Object.hash(
    phase,
    percent,
    myTipHeight,
    myTipAt,
    initialTipHeight,
    fastSyncTarget,
    fastSyncFailures,
    peersSeen,
    ownerAccounts,
    error,
    errorDetail,
    exitCode,
    finishingPercent,
  );

  @override
  String toString() =>
      'BeamNodeProgress(${phase.name}'
      '${percent == null ? '' : ', $percent%'}'
      '${myTipHeight == null ? '' : ', tip $myTipHeight'}'
      '${fastSyncTarget == null ? '' : ', fast-sync to $fastSyncTarget'}'
      '${finishingPercent == null ? '' : ', finishing $finishingPercent%'}'
      ', peers $peersSeen'
      '${ownerAccounts == null ? '' : ', owners $ownerAccounts'}'
      '${error == null ? '' : ', error ${error!.name}'}'
      '${exitCode == null ? '' : ', exit $exitCode'})';
}

/// Splits `I 2026-02-13.13:15:26.261 My Tip: …` into level and message.
final RegExp _prefix = RegExp(
  r'^([IWEDV]) \d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2}\.\d{3} ',
);
final RegExp _myTip = RegExp(r'^My Tip: (\d+)-[0-9a-fA-F]+');
final RegExp _initialTip = RegExp(r'^Initial Tip: (\d+)-[0-9a-fA-F]+');
final RegExp _fastSyncMode = RegExp(
  r'^Fast-sync mode up to (?:block number|height) (\d+)',
);
final RegExp _updating = RegExp(r'^Updating node: (\d+)% \((\d+)/(\d+)\)');
final RegExp _peerTip = RegExp(r'^Peer (\S+) Tip: \d+-');

/// A long maintenance step starting (`LongAction::Reset` logs its name).
final RegExp _longStep = RegExp(
  r'^(Raising (Fossil|TxoLo|TxoHi)|Rebuilding .+|Rescanning .+)\.\.\.$',
);

/// Its progress, every 10 s: `\tN%...` after the time prefix.
final RegExp _longStepPercent = RegExp(r'^(\d{1,3})%\.\.\.$');

/// Turns console lines into [BeamNodeProgress] snapshots. Stateful; one
/// instance per node launch. Pure otherwise: no I/O, no clock unless given.
///
/// The parser reads raw lines (it must, to see `key import failed`), but
/// nothing from a raw line except numbers and fixed phrases ever reaches a
/// [BeamNodeProgress].
class BeamNodeLogParser {
  BeamNodeLogParser({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  BeamNodeProgress _progress = const BeamNodeProgress();
  final Set<String> _peers = {};

  /// Inside the tab-indented list after `Owned accounts :`.
  bool _inOwnedAccounts = false;
  int _ownedCount = 0;

  /// Fast sync is running (between `Fast-sync mode` and `succeeded`).
  bool _fastSyncActive = false;

  /// `Fast-sync succeeded` (or `abort`) was seen.
  bool _fastSyncOver = false;

  /// `Tx replication is ON` was logged, counted or not. BEAM never logs it
  /// twice in one process.
  bool _replicationLogged = false;

  /// Inside a long maintenance step ([BeamNodeProgress.finishingPercent]).
  bool _inLongStep = false;

  BeamNodeProgress get progress => _progress;

  /// Feeds one line. Returns the new snapshot, or null when nothing
  /// changed.
  BeamNodeProgress? add(String rawLine) {
    final before = _progress;
    _parse(rawLine);
    return _progress == before ? null : _progress;
  }

  /// Marks the end of the process. [requested]: stopped on purpose.
  BeamNodeProgress finish({required int exitCode, required bool requested}) {
    _finishOwnedAccounts();
    if (_progress.phase == BeamNodePhase.error) {
      _progress = _progress.copyWith(exitCode: exitCode);
    } else if (requested) {
      _progress = _progress.copyWith(
        phase: BeamNodePhase.stopped,
        exitCode: exitCode,
      );
    } else {
      _progress = _progress.copyWith(
        phase: BeamNodePhase.error,
        error: BeamNodeError.exited,
        errorDetail: 'The node exited (code $exitCode)',
        exitCode: exitCode,
      );
    }
    return _progress;
  }

  /// Records a failure decided outside the log (e.g. a start timeout).
  BeamNodeProgress fail(BeamNodeError error, String detail) {
    if (_progress.phase != BeamNodePhase.error) {
      _progress = _progress.copyWith(
        phase: BeamNodePhase.error,
        error: error,
        errorDetail: detail,
      );
    }
    return _progress;
  }

  void _parse(String raw) {
    if (raw.startsWith('\t')) {
      if (_inOwnedAccounts && raw.trim().isNotEmpty) _ownedCount++;
      return;
    }
    // Any non-indented line ends the owned-accounts list; BEAM ends it
    // with an empty line.
    _finishOwnedAccounts();
    if (_progress.phase == BeamNodePhase.error) return;

    final m = _prefix.firstMatch(raw);
    final level = m?.group(1);
    final msg = m == null ? raw.trim() : raw.substring(m.end).trim();

    if (_longStep.hasMatch(msg)) {
      _inLongStep = true;
      _progress = _progress.copyWith(finishingPercent: 0);
      return;
    }
    final stepPct = _longStepPercent.firstMatch(msg);
    if (stepPct != null) {
      if (_inLongStep) {
        _progress = _progress.copyWith(
          finishingPercent: _int(stepPct.group(1))!.clamp(0, 100),
        );
      }
      return;
    }
    // Any progress line of the node's normal work ends the step (it runs
    // on the node's only thread, so nothing else is logged meanwhile).
    if (_inLongStep &&
        (msg.startsWith('My Tip: ') ||
            msg.startsWith('Updating node: ') ||
            msg.startsWith('Fast-sync ') ||
            msg == 'Tx replication is ON')) {
      _inLongStep = false;
      _progress = _progress.copyWith(clearFinishing: true);
    }

    if (msg.startsWith('My Tip: ')) {
      final h = _int(_myTip.firstMatch(msg)?.group(1));
      if (h != null) {
        _progress = _progress.copyWith(myTipHeight: h, myTipAt: _now());
      }
      return;
    }
    if (msg.startsWith('Updating node: ')) {
      final u = _updating.firstMatch(msg);
      final pct = _int(u?.group(1));
      final done = _int(u?.group(2));
      final total = _int(u?.group(3));
      if (pct != null) {
        _progress = _progress.copyWith(percent: pct.clamp(0, 100));
      }
      // done == total is the node's own "synced" (it is what triggers the
      // replication line). It counts once fast sync is over, or after the
      // replication line was already used up early.
      if (done != null &&
          total != null &&
          total > 0 &&
          done == total &&
          !_fastSyncActive &&
          (_fastSyncOver || _replicationLogged) &&
          (_progress.bestHeight ?? 0) > 0) {
        _progress = _progress.copyWith(phase: BeamNodePhase.txReplicationOn);
      }
      return;
    }
    if (msg.startsWith('Peer ')) {
      final peer = _peerTip.firstMatch(msg)?.group(1);
      if (peer != null && _peers.add(peer)) {
        _progress = _progress.copyWith(peersSeen: _peers.length);
      }
      return;
    }
    if (msg.startsWith('Fast-sync mode up to ')) {
      _fastSyncActive = true;
      _progress = _progress.copyWith(
        phase: BeamNodePhase.fastSyncDownloading,
        fastSyncTarget: _int(_fastSyncMode.firstMatch(msg)?.group(1)),
      );
      return;
    }
    if (msg.startsWith('Fast-sync failed')) {
      // BEAM rolls back and retries by itself; still fast-syncing.
      _fastSyncActive = true;
      _progress = _progress.copyWith(
        phase: BeamNodePhase.fastSyncDownloading,
        fastSyncFailures: _progress.fastSyncFailures + 1,
      );
      return;
    }
    if (msg.startsWith('Fast-sync succeeded') ||
        msg.startsWith('Fast-sync abort')) {
      _fastSyncActive = false;
      _fastSyncOver = true;
      _progress = _progress.copyWith(phase: BeamNodePhase.catchingUp);
      return;
    }
    if (msg == 'Tx replication is ON') {
      _replicationLogged = true;
      // node.cpp:85 only logs this outside fast sync; the guard keeps an
      // out-of-order line from counting. At height 0 it is the header-
      // download blip of a fresh node (seen live 2026-10-06), not a sync.
      if (!_fastSyncActive && (_progress.bestHeight ?? 0) > 0) {
        _progress = _progress.copyWith(phase: BeamNodePhase.txReplicationOn);
      }
      return;
    }
    if (msg.startsWith('Initial Tip: ')) {
      final h = _int(_initialTip.firstMatch(msg)?.group(1));
      if (h != null) _progress = _progress.copyWith(initialTipHeight: h);
      return;
    }
    if (msg.startsWith('Owned accounts :')) {
      _inOwnedAccounts = true;
      _ownedCount = 0;
      return;
    }
    if (msg == 'key import failed' ||
        msg.startsWith('Please, provide password for the keys')) {
      _progress = _progress.copyWith(
        phase: BeamNodePhase.error,
        error: BeamNodeError.ownerKeyRejected,
        errorDetail: msg.startsWith('Please')
            ? 'The node got no password for the owner key'
            : 'The node could not import the owner key',
      );
      return;
    }
    if (msg.startsWith('Corruption') || msg.contains('orruption')) {
      _progress = _progress.copyWith(
        phase: BeamNodePhase.error,
        error: BeamNodeError.corrupted,
        errorDetail: 'The node database is damaged',
      );
      return;
    }
    if (level == 'E' || m == null) {
      final lower = msg.toLowerCase();
      if (lower.contains('address already in use') ||
          (lower.contains('bind') && lower.contains('fail'))) {
        _progress = _progress.copyWith(
          phase: BeamNodePhase.error,
          error: BeamNodeError.portUnavailable,
          errorDetail: 'The node could not open its network port',
        );
      }
    }
  }

  void _finishOwnedAccounts() {
    if (!_inOwnedAccounts) return;
    _inOwnedAccounts = false;
    final count = _ownedCount;
    _progress = _progress.copyWith(ownerAccounts: count);
    if (count == 0 && _progress.phase != BeamNodePhase.error) {
      // Started with a key, but it owns nothing: running like this would
      // be a keyless node. Refuse.
      _progress = _progress.copyWith(
        phase: BeamNodePhase.error,
        error: BeamNodeError.ownerKeyRejected,
        errorDetail: 'The node started without your owner key',
      );
    }
  }

  static int? _int(String? s) => s == null ? null : int.tryParse(s);
}

/// Makes `beam-node` console lines safe to keep in a log file.
///
/// beam-node never prints the owner key or password at info level, but this
/// does not rely on that:
///
/// * the tab-indented endpoints under `Owned accounts :` (they identify the
///   wallet) are withheld;
/// * a line mentioning an owner key, a miner key, a password, a seed or a
///   phrase is withheld, except BEAM's two fixed error messages;
/// * any token of 32+ base64/base58 characters that is not plain hex (an
///   exported key is base64) is replaced; hex hashes are public chain data
///   and are kept;
/// * literal [secrets] are replaced.
///
/// Other tab-indented continuation lines (transaction dumps) are dropped to
/// keep the log small, except the rules signature, which is evidence of the
/// consensus the node follows.
class BeamNodeLogRedactor {
  BeamNodeLogRedactor([Iterable<String> secrets = const []])
    : _secrets = secrets.where((s) => s.isNotEmpty).toList();

  final List<String> _secrets;

  /// What the current run of continuation lines belongs to.
  _Continuation _continuation = _Continuation.other;

  static final RegExp _longToken = RegExp(r'[A-Za-z0-9+/=_-]{32,}');
  static final RegExp _hexOnly = RegExp(r'^[0-9a-fA-F]+$');
  static const _withheld = '[line withheld]';
  static const _safeFixed = {
    'key import failed',
    'Please, provide password for the keys.',
  };
  static const _sensitive = [
    'owner',
    'key_',
    '_key',
    'viewer key',
    'pass',
    'seed',
    'phrase',
    'mnemonic',
  ];

  /// The safe form of [raw], or null to drop it.
  String? redact(String raw) {
    if (raw.startsWith('\t')) {
      return switch (_continuation) {
        _Continuation.rules => _scrub(raw),
        _Continuation.owned => raw.trim().isEmpty ? null : '\t[withheld]',
        _Continuation.other => null,
      };
    }
    final m = _prefix.firstMatch(raw);
    final msg = m == null ? raw.trim() : raw.substring(m.end).trim();
    if (msg.startsWith('Owned accounts :')) {
      _continuation = _Continuation.owned;
      return raw;
    }
    _continuation = msg.startsWith('Rules signature:')
        ? _Continuation.rules
        : _Continuation.other;
    if (raw.trim().isEmpty) return null;
    if (_safeFixed.contains(msg)) return raw;
    final lower = msg.toLowerCase();
    if (_sensitive.any(lower.contains)) return _withheld;
    return _scrub(raw);
  }

  String _scrub(String line) {
    var out = line.replaceAllMapped(_longToken, (t) {
      final token = t.group(0)!;
      return _hexOnly.hasMatch(token) ? token : '[redacted]';
    });
    for (final s in _secrets) {
      out = out.replaceAll(s, '[redacted]');
    }
    return out;
  }
}

enum _Continuation { rules, owned, other }
