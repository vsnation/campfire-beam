/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:isar_community/isar.dart';
import 'package:meta/meta.dart';
import 'package:mutex/mutex.dart';
import 'package:path/path.dart' as p;

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../models/paymint/fee_object_model.dart';
import '../../../services/event_bus/events/global/blocks_remaining_event.dart';
import '../../../services/event_bus/events/global/node_connection_status_changed_event.dart';
import '../../../services/event_bus/events/global/refresh_percent_changed_event.dart';
import '../../../services/event_bus/events/global/tor_status_changed_event.dart';
import '../../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../../services/event_bus/global_event_bus.dart';
import '../../../services/tor_service.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/flutter_secure_storage_interface.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/test_beam_node_connection.dart';
import '../../beam/api/beam_api.dart';
import '../../beam/host/beam_binaries.dart';
import '../../beam/host/beam_host.dart';
import '../../beam/host/beam_host_exception.dart';
import '../../beam/host/process_host.dart';
import '../../beam/host/secret_file.dart';
import '../../beam/models/beam_address.dart';
import '../../beam/models/beam_transaction.dart';
import '../../beam/models/beam_wallet_status.dart';
import '../../beam/node/beam_private_node_coordinator.dart';
import '../../beam/node/beam_private_node_preference.dart';
import '../../beam/rpc/beam_connection_exception.dart';
import '../../beam/rpc/beam_transport.dart';
import '../../beam/sync/beam_sync_monitor.dart';
import '../../beam/sync/beam_sync_state.dart';
import '../../beam/wallet/beam_balance_mapper.dart';
import '../../beam/wallet/beam_node_switch_gate.dart';
import '../../beam/wallet/beam_open_timings.dart';
import '../../beam/wallet/beam_secret_store.dart';
import '../../beam/wallet/beam_send_rules.dart';
import '../../beam/wallet/beam_shutdown.dart';
import '../../beam/wallet/beam_sync_tracker.dart';
import '../../beam/wallet/beam_tx_mapper.dart';
import '../../beam/wallet/beam_wallet_environment.dart';
import '../../beam/wallet/beam_wallet_errors.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../isar/models/wallet_info.dart';
import '../../models/tx_data.dart';
import '../intermediate/bip39_wallet.dart';
import '../intermediate/external_wallet.dart';
import '../supporting/beam_wallet_info_extension.dart';

/// What a freshly restored BEAM wallet tells the user (restore flows). The
/// balance reads 0 until the scan finds the coins; that must not look like
/// a loss (ARCHITECTURE.md §4.5).
const String kBeamRestoreScanningMessage =
    "Scanning for your coins… Until they are found, your balance shows 0. "
    "That doesn't mean they are gone. Campfire looks for them in the "
    "background, which can take hours. Keep this wallet open in Campfire; "
    "you can receive payments meanwhile.";

/// A BEAM wallet (Mimblewimble with Confidential Assets), mirroring
/// [EpiccashWallet] for the Mimblewimble parts and [LibSalviumWallet] for
/// the open-on-demand lifecycle.
///
/// * The phrase is Campfire's own BIP39 12 words, checked (dictionary and
///   checksum) before the core sees it; the core checks neither.
/// * `wallet.db` gets a random password kept in secure storage
///   (`BEAM_WALLET_PASSWORD_<ID>`), new on every restore, never in a backup,
///   deleted with the wallet.
/// * The owner key is read right after the file is made, while it is closed
///   anyway, and kept next to the password (`BEAM_OWNER_KEY_<ID>`), so the
///   private node never has to pause the wallet for it (R11).
/// * [open] returns at once: the cached balance and history render from
///   Isar while wallet-api starts behind them (R11).
/// * "Synced" and the right to spend come only from [BeamSyncMonitor]
///   (`is_in_sync`, tip age, header lag, an independent explorer).
class BeamWallet extends Bip39Wallet<Beam> implements ExternalWallet<Beam> {
  BeamWallet(CryptoCurrencyNetwork network) : super(Beam(network));

  // ===========================================================================
  // State

  BeamWalletEnvironment get environment => BeamWalletEnvironment.instance;

  BeamSecretStore get _secrets =>
      BeamSecretStore(secureStorageInterface, walletId);

  BeamHost? _host;
  BeamCoordinatorHost? _coordHost;
  BeamNodeSwitchGate _gate = BeamNodeSwitchGate();
  BeamGatedSession? _session;
  BeamApi? _api;
  StreamSubscription<BeamEvent>? _eventSub;

  BeamSyncTracker? _tracker;
  BeamSyncMonitor? _monitor;
  StreamSubscription<BeamSyncAssessment>? _assessmentSub;
  BeamSyncAssessment _assessment = const BeamSyncConnecting(
    node: BeamNodeKind.publicNode,
    explorerCheck: BeamExplorerCheck.unavailable,
  );
  final _assessments = StreamController<BeamSyncAssessment>.broadcast();

  BeamPrivateNodeCoordinator? _coordinator;
  StreamSubscription<BeamSession?>? _coordinatorSessionSub;
  StreamSubscription<BeamPrivateNodeStatus>? _coordinatorStatusSub;
  StreamSubscription<TorPreferenceChangedEvent>? _torSub;
  BeamPrivateNodeStatus? _privateNodeStatus;
  Timer? _coordinatorTimer;
  bool _coordinatorReplacing = false;

  Future<void>? _opening;
  int _generation = 0;
  BeamWalletException? _problem;
  BeamWalletStatus? _lastStatus;
  Set<String> _ownAddresses = {};
  BeamGateLease? _preparedSend;

  final Mutex _coreSync = Mutex();
  Timer? _debounce;
  Timer? _statusPoll;
  Timer? _failoverTimer;
  DateTime? _lastFailover;
  bool _dirtyStatus = false;
  bool _dirtyTxs = false;
  bool _dirtyAddrs = false;
  int _maxBlocksBehind = 0;
  NodeConnectionStatus? _lastConnection;
  WalletSyncStatus? _lastSyncStatus;

  BeamOpenTimings? _timings;
  Completer<void> _live = Completer<void>();
  Completer<void> _canSend = Completer<void>();

  static Future<void>? _prewarm;

  // ===========================================================================
  // Public BEAM surface (sync UI, node panel, money flows, tests)

  /// The honest sync verdict. Only [BeamSynced] allows spending.
  BeamSyncAssessment get syncAssessment => _assessment;

  /// Verdicts as they change. Broadcast.
  Stream<BeamSyncAssessment> get syncAssessments => _assessments.stream;

  bool get canSpend => _assessment.canSpend;

  /// Why the core is not usable, when it is not (e.g. "BEAM core not
  /// installed"). Null while things are fine or still starting.
  BeamWalletException? get coreProblem => _problem;

  /// wallet-api is up for this wallet.
  bool get isOpen => _api != null;

  /// The typed core API while the wallet is open, for BEAM modules that
  /// need it (DEX, names, dApps). Null while closed or starting.
  BeamApi? get coreApi => _api;

  /// The node the wallet is connected to right now.
  BeamNodeEndpoint? get currentNode => _session?.node;

  /// A restored wallet whose coins are still being looked for.
  bool get isScanningForCoins => info.beamData?.restoreScanPending ?? false;

  /// Block-body scan progress while [isScanningForCoins].
  BeamScanProgress? get scanProgress => _tracker?.scanProgress;

  /// Private node state, when the private node is in use.
  BeamPrivateNodeStatus? get privateNodeStatus => _privateNodeStatus;

  /// R11 measurements of the current (or last) open.
  BeamOpenTimings? get openTimings => _timings;

  /// Completes when the current open has applied live data from the core.
  Future<void> get whenLive => _live.future;

  /// Completes when the current open first may spend.
  Future<void> get whenCanSend => _canSend.future;

  /// Keeps the private node from restarting wallet-api while a money flow
  /// (swap, claim, dApp approval) is open. Release the lease when the flow
  /// ends; [maxHold] guards against a flow that never reports back. Sends
  /// take their own lease in [prepareSend] / [confirmSend].
  BeamGateLease holdNodeSwitch(String reason, {Duration? maxHold}) =>
      _gate.hold(reason, maxHold: maxHold);

  /// True while a money flow holds the node switch.
  bool get isBusy => _gate.isBusy;

  // ===========================================================================
  // Lifecycle

  @override
  int get isarTransactionVersion => 2;

  @override
  FilterOperation? get changeAddressFilterOperation =>
      FilterGroup.and(standardChangeAddressFilters);

  @override
  FilterOperation? get receivingAddressFilterOperation =>
      FilterGroup.and(standardReceivingAddressFilters);

  /// The BEAM history only: Confidential Asset transactions carry a
  /// `contractAddress` tag (see `beamAssetTag`) and wait for the asset views.
  @override
  FilterOperation? get transactionFilterOperation =>
      const FilterCondition.isNull(property: r"contractAddress");

  /// Creates `wallet.db` for a brand-new wallet; never does anything slow
  /// for an existing one (that is [open]'s job, off the UI path).
  @override
  Future<void> init({bool? isRestore}) async {
    if (isRestore != true) {
      final dir = await _walletDir();
      if (!await beamWalletFileExists(dir) &&
          info.beamData == null &&
          await _secrets.readPassword() == null) {
        await _createWalletFile(dir, restore: false);
      } else {
        unawaited(_prewarmCore());
      }
    }
    return super.init();
  }

  /// Starts wallet-api in the background and returns at once, so the
  /// wallet opens on its cached balance and history (R11). Progress shows
  /// through [syncAssessments] and Campfire's sync events.
  @override
  Future<void> open() async {
    final started = _ensureOpening();
    if (started) _timings?.openReturned = _timings?.since(DateTime.now());
  }

  @override
  Future<void> exit() async {
    _generation++;
    _opening = null;
    _cancelTimers();
    _preparedSend?.release();
    _preparedSend = null;
    _gate.dispose();
    _coordHost?.close();
    await _disposeCoordinator();

    final session = _session;
    _session = null;
    _api = null;
    await _eventSub?.cancel();
    _eventSub = null;
    if (session != null) {
      try {
        await session.closeNow();
      } catch (e) {
        Logging.instance.w("BEAM: closing the wallet failed: $e");
      }
    }
    await _assessmentSub?.cancel();
    _assessmentSub = null;
    await _monitor?.dispose();
    _monitor = null;
    await _tracker?.dispose();
    _tracker = null;
    _host = null; // re-read from the environment on the next open
    await super.exit();
  }

  /// Rebuilds `wallet.db` from the recovery phrase with a new password and
  /// owner key, and marks the wallet as scanning for its coins (block
  /// bodies from public nodes until its own node takes over).
  ///
  /// [isRescan] `false` is the restore of a new wallet; `true` rebuilds an
  /// existing one (its Campfire history is kept and refreshed).
  @override
  Future<void> recover({required bool isRescan}) async {
    await refreshMutex.protect(() async {
      final wasOpen = _api != null || _opening != null;
      if (wasOpen) await _closeForMaintenance();
      final dir = await _walletDir();
      await _deleteWalletFile(dir);
      await _createWalletFile(dir, restore: true);
      if (wasOpen) _ensureOpening();
    });
  }

  // ===========================================================================
  // Opening

  Future<String> _walletDir() => environment.walletDir(walletId);

  Future<BeamHost> _hostOrThrow() async {
    try {
      return _host ??= await environment.host();
    } catch (e) {
      throw beamWalletExceptionFrom(e);
    }
  }

  /// Returns true if a new open was started.
  bool _ensureOpening() {
    if (_api != null || _opening != null) return false;
    final gen = ++_generation;
    _timings = BeamOpenTimings(DateTime.now());
    if (_live.isCompleted) _live = Completer<void>();
    if (_canSend.isCompleted) _canSend = Completer<void>();
    _problem = null;
    _opening = _openInBackground(gen);
    return true;
  }

  Future<void> _openInBackground(int gen) async {
    // Let open() return before any work starts.
    await Future<void>.delayed(Duration.zero);
    try {
      final host = await _hostOrThrow();
      final dir = await _walletDir();
      if (!await beamWalletFileExists(dir)) {
        throw const BeamWalletException(
          BeamWalletProblem.walletFileMissing,
          BeamWalletMessages.walletFileMissing,
        );
      }
      final password = await _secrets.readPassword();
      if (password == null || password.isEmpty) {
        throw const BeamWalletException(
          BeamWalletProblem.passwordMissing,
          BeamWalletMessages.passwordMissing,
        );
      }
      if (gen != _generation) return;

      if (_gate.isDisposed) _gate = BeamNodeSwitchGate();
      final coordHost = BeamCoordinatorHost(
        inner: host,
        gate: _gate,
        storeOwnerKey: _secrets.writeOwnerKey,
      );
      _coordHost = coordHost;
      _startSyncMonitor();

      // R11: an older wallet without a stored owner key gets it read once,
      // now, while wallet.db is closed anyway.
      if (environment.createPrivateNode != null &&
          await _secrets.readOwnerKey() == null &&
          await _privateNodeWanted()) {
        final sw = Stopwatch()..start();
        try {
          final key = await host.exportOwnerKey(
            walletDir: dir,
            password: password,
          );
          await _secrets.writeOwnerKey(key);
        } catch (e) {
          environment.log('Owner key could not be read before opening: $e');
        }
        _timings?.ownerKeyCapture = sw.elapsed;
      }
      if (gen != _generation) return;

      final session = await _openOnSomeNode(coordHost, dir, password);
      if (gen != _generation) {
        await session.closeNow();
        return;
      }
      _timings?.sessionUp = _timings?.since(DateTime.now());
      await _attach(session, gen);
    } catch (e, s) {
      if (gen != _generation) return;
      final problem = beamWalletExceptionFrom(
        e,
        node: '${_preferredEndpoint()}',
      );
      _problem = problem;
      Logging.instance.w(
        "BEAM: wallet could not open (${problem.problem.name})",
        error: e,
        stackTrace: s,
      );
      _fireConnection(NodeConnectionStatus.disconnected);
      _fireSync(WalletSyncStatus.unableToSync);
    } finally {
      if (gen == _generation) _opening = null;
    }
  }

  Future<bool> _privateNodeWanted() async {
    try {
      return await environment.privateNodeSetting.read();
    } catch (_) {
      return false;
    }
  }

  /// Opens on the configured node; if it cannot even be resolved or the
  /// core fails to come up on it, on BEAM's public nodes in turn.
  Future<BeamGatedSession> _openOnSomeNode(
    BeamCoordinatorHost host,
    String dir,
    String password,
  ) async {
    Object? lastError;
    for (final node in _publicCandidates()) {
      try {
        final s = await host.openWallet(
          walletDir: dir,
          password: password,
          node: node,
          requestBodies: isScanningForCoins,
        );
        return s as BeamGatedSession;
      } on BeamHostException catch (e) {
        lastError = e;
        if (e.kind != BeamHostError.badNode &&
            e.kind != BeamHostError.timeout &&
            e.kind != BeamHostError.processFailed) {
          rethrow;
        }
        environment.log('Node $node did not work (${e.kind.name})');
      }
    }
    throw lastError ?? StateError('no node to open on');
  }

  /// Points the wallet at [session]: events, a fresh read of everything,
  /// and the initial receiving address.
  Future<void> _attach(BeamGatedSession session, int gen) async {
    final previous = _session;
    _session = session;
    _api = BeamApi(session.transport);
    _coordinatorReplacing = false;
    _problem = null;
    _tracker?.resetConnection();
    _monitor?.setNode(
      session.node.isOwned ? BeamNodeKind.privateNode : BeamNodeKind.publicNode,
    );
    if (previous != null && !identical(previous.inner, session.inner)) {
      _maxBlocksBehind = 0;
    }

    await _eventSub?.cancel();
    _eventSub = session.transport.events.listen(
      _onEvent,
      onError: (Object e) => environment.log('Event stream error: $e'),
    );
    try {
      await _api!.subscribeEvents();
    } catch (e) {
      environment.log('Could not subscribe to wallet events: $e');
    }
    if (gen != _generation) return;

    await _syncFromCore(status: true, addresses: true, transactions: true);
    if (gen != _generation) return;
    try {
      await checkSaveInitialReceivingAddress();
    } catch (e) {
      environment.log('Receiving address not saved yet: $e');
    }

    _statusPoll?.cancel();
    _statusPoll = Timer.periodic(environment.statusPollInterval, (_) {
      _markDirty(status: true);
    });
    _fireConnection(NodeConnectionStatus.connected);
    if (_assessment.canSpend) _scheduleCoordinator(gen);
  }

  void _startSyncMonitor() {
    if (_monitor != null) return;
    final tracker = BeamSyncTracker();
    _tracker = tracker;
    final monitor = BeamSyncMonitor(
      explorer: environment.explorer,
      walletStatus: tracker.inputs,
      rules: environment.syncRules,
      pollInterval: environment.explorerPollInterval,
    );
    _monitor = monitor;
    _assessmentSub = monitor.assessments.listen(_onAssessment);
    monitor.start();
    _onAssessment(monitor.current);
  }

  /// Closes the core without forgetting the wallet (rescan, node change
  /// failure). Unlike [exit] it leaves Campfire's timers alone.
  Future<void> _closeForMaintenance() async {
    _generation++;
    _opening = null;
    _debounce?.cancel();
    _statusPoll?.cancel();
    _failoverTimer?.cancel();
    _coordinatorTimer?.cancel();
    _gate.dispose();
    _coordHost?.close();
    await _disposeCoordinator();
    final s = _session;
    _session = null;
    _api = null;
    await _eventSub?.cancel();
    _eventSub = null;
    if (s != null) {
      try {
        await s.closeNow();
      } catch (_) {
        // Already gone.
      }
    }
  }

  Future<void> _prewarmCore() async {
    // Hash and consensus-probe wallet-api once per app run, before the user
    // opens the wallet, so opening does not pay for it.
    _prewarm ??= () async {
      try {
        final host = await environment.host();
        if (host is! ProcessHost) return;
        await ensurePrivateDir(host.rootDir);
        await ensurePrivateDir(host.runDir);
        await host.binaries.prepare(
          BeamBinary.walletApi,
          scratchParent: host.runDir,
        );
      } catch (_) {
        // Reported properly when the wallet is opened.
      }
    }();
    await _prewarm;
  }

  // ===========================================================================
  // Creating wallet.db

  Future<void> _createWalletFile(String dir, {required bool restore}) async {
    final words = await getMnemonicAsWords();
    if (words.length != 12 || !bip39.validateMnemonic(words.join(' '))) {
      throw const BeamWalletException(
        BeamWalletProblem.invalidPhrase,
        BeamWalletMessages.invalidPhrase,
      );
    }
    final host = await _hostOrThrow();
    // A stale owner key would belong to the old file.
    await _secrets.deleteOwnerKey();
    final password = await _secrets.createPassword();
    try {
      await host.initWallet(walletDir: dir, password: password, words: words);
    } catch (e) {
      throw beamWalletExceptionFrom(e);
    }

    // R11: read the owner key now, while wallet.db is closed anyway.
    try {
      final key = await host.exportOwnerKey(walletDir: dir, password: password);
      await _secrets.writeOwnerKey(key);
    } catch (e) {
      environment.log(
        'Owner key not read at ${restore ? 'restore' : 'create'} '
        '(it will be read before the first open): $e',
      );
    }

    await info.updateExtraBeamWalletInfo(
      beamData: ExtraBeamWalletInfo(
        restoreScanPending: restore,
        restoreScanStartedAt: restore
            ? DateTime.now().millisecondsSinceEpoch ~/ 1000
            : null,
      ),
      isar: mainDB.isar,
    );
  }

  static Future<void> _deleteWalletFile(String dir) async {
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final f = File(p.join(dir, 'wallet.db$suffix'));
      if (await f.exists()) await f.delete();
    }
  }

  // ===========================================================================
  // Events, sync and the private node

  void _onEvent(BeamEvent e) {
    _tracker?.onEvent(e);
    switch (e.name) {
      case 'ev_txs_changed':
        _markDirty(status: true, transactions: true);
      case 'ev_utxos_changed':
      case 'ev_assets_changed':
        _markDirty(status: true);
      case 'ev_addrs_changed':
        _markDirty(addresses: true);
      case 'ev_system_state':
      case 'ev_sync_progress':
        final h = e.data['current_height'];
        if (h is int && h > info.cachedChainHeight) {
          unawaited(
            info.updateCachedChainHeight(newHeight: h, isar: mainDB.isar),
          );
        }
        _publishScan();
    }
  }

  void _markDirty({
    bool status = false,
    bool transactions = false,
    bool addresses = false,
  }) {
    _dirtyStatus |= status;
    _dirtyTxs |= transactions;
    _dirtyAddrs |= addresses;
    _debounce ??= Timer(environment.eventDebounce, () {
      _debounce = null;
      final s = _dirtyStatus, t = _dirtyTxs, a = _dirtyAddrs;
      _dirtyStatus = _dirtyTxs = _dirtyAddrs = false;
      unawaited(_syncFromCore(status: s, transactions: t, addresses: a));
    });
  }

  /// Reads what changed from the core into Campfire's cache. Serialized;
  /// failures leave the cache as it was.
  Future<void> _syncFromCore({
    bool status = false,
    bool transactions = false,
    bool addresses = false,
  }) => _coreSync.protect(() async {
    final api = _api;
    if (api == null) return;
    try {
      // Reading the balance always re-reads the history, and the history
      // is stored first: the balance must never show money the history
      // does not explain yet (a payment counted as arrived while its row
      // still says "Receiving"). The core can send ev_utxos_changed before
      // the ev_txs_changed of the same payment, and tx_list is a local call.
      final readTxs = transactions || status;
      final s = status ? await api.walletStatus() : null;
      if (addresses) {
        await _storeAddresses(await api.addrList(own: true));
      }
      if (readTxs) {
        if (_ownAddresses.isEmpty) {
          await _storeAddresses(await api.addrList(own: true));
        }
        await _storeTransactions(await api.txList());
      }
      if (s != null) {
        _lastStatus = s;
        _tracker?.onStatus(s);
        await _storeStatus(s);
      }
      // Live = balance and history from the core are in Campfire's cache.
      if (s != null && !_live.isCompleted) {
        _timings?.liveData = _timings?.since(DateTime.now());
        _live.complete();
      }
    } on BeamConnectionException catch (e) {
      _onConnectionLost(e);
    } on TimeoutException catch (e) {
      environment.log('The wallet core is slow to answer: $e');
    } on BeamRpcException catch (e) {
      environment.log('The wallet core refused a read: $e');
    } on FormatException catch (e) {
      environment.log('Unexpected answer from the wallet core: $e');
    }
  });

  Future<void> _storeStatus(BeamWalletStatus s) async {
    await info.updateBalance(
      newBalance: BeamBalanceMapper.balance(
        s,
        fractionDigits: cryptoCurrency.fractionDigits,
      ),
      isar: mainDB.isar,
    );
    await info.updateOtherData(
      newEntries: {
        WalletInfoKeys.beamAssetTotals: BeamBalanceMapper.assetTotalsJson(s),
      },
      isar: mainDB.isar,
    );
    if (s.currentHeight > 0) {
      await info.updateCachedChainHeight(
        newHeight: s.currentHeight,
        isar: mainDB.isar,
      );
    }
  }

  Future<void> _storeAddresses(List<BeamAddress> all) async {
    final own = all.where((a) => a.own).toList();
    _ownAddresses = {
      for (final a in own) ...[a.address, a.walletId],
    };
    final regular = own.where((a) => a.type == BeamAddressType.regular);
    final toWrite = <Address>[];
    for (final a in regular) {
      final next = Address(
        walletId: walletId,
        value: a.address,
        publicKey: [],
        // Creation time orders the addresses: the newest unexpired one is
        // the current receiving address.
        derivationIndex: a.createTime,
        derivationPath: null,
        type: AddressType.mimbleWimble,
        subType: a.expired ? AddressSubType.unknown : AddressSubType.receiving,
      );
      final stored = await mainDB.getAddress(walletId, a.address);
      if (stored == null ||
          stored.subType != next.subType ||
          stored.derivationIndex != next.derivationIndex ||
          stored.type != next.type) {
        toWrite.add(next);
      }
    }
    if (toWrite.isNotEmpty) await mainDB.updateOrPutAddresses(toWrite);
    final current = await getCurrentReceivingAddress();
    if (current != null && info.cachedReceivingAddress != current.value) {
      await info.updateReceivingAddress(
        newAddress: current.value,
        isar: mainDB.isar,
      );
    }
  }

  Future<void> _storeTransactions(List<BeamTransaction> txs) async {
    final existing = {
      for (final t
          in await mainDB.isar.transactionV2s
              .where()
              .walletIdEqualTo(walletId)
              .findAll())
        t.txid: t,
    };
    final changed = <TransactionV2>[];
    for (final tx in txs) {
      final mapped = BeamTxMapper.map(
        tx,
        walletId: walletId,
        ownAddresses: _ownAddresses,
        fractionDigits: cryptoCurrency.fractionDigits,
      );
      final old = existing[mapped.txid];
      if (old == null || !BeamTxMapper.same(old, mapped)) changed.add(mapped);
    }
    if (changed.isNotEmpty) await mainDB.updateOrPutTransactionV2s(changed);
  }

  void _onConnectionLost(Object e) {
    if (_coordinatorReplacing) return; // the private node is moving us
    final session = _session;
    if (session == null || session.transport.isConnected) return;
    environment.log('Lost the wallet core ($e); reopening');
    final gen = _generation;
    _session = null;
    _api = null;
    unawaited(
      Future<void>.delayed(const Duration(seconds: 2), () async {
        if (gen != _generation) return;
        await _disposeCoordinator();
        _coordHost?.close();
        _ensureOpening();
      }),
    );
  }

  void _onAssessment(BeamSyncAssessment a) {
    final gen = _generation;
    _assessment = a;
    if (!_assessments.isClosed) _assessments.add(a);

    switch (a) {
      case BeamSynced():
        _maxBlocksBehind = 0;
        _fireConnection(NodeConnectionStatus.connected);
        _firePercent(1.0);
        _fireBlocksRemaining(0);
        _fireSync(WalletSyncStatus.synced);
      case BeamSyncCatchingUp(:final blocksBehind):
        _fireConnection(NodeConnectionStatus.connected);
        if (blocksBehind != null) {
          if (blocksBehind > _maxBlocksBehind) _maxBlocksBehind = blocksBehind;
          _fireBlocksRemaining(blocksBehind);
          if (_maxBlocksBehind > 0) {
            _firePercent(1 - blocksBehind / _maxBlocksBehind);
          }
        }
        _fireSync(WalletSyncStatus.syncing);
      case BeamSyncConnecting():
        _firePercent(0);
        _fireSync(WalletSyncStatus.syncing);
      case BeamSyncNotConnected():
        _fireConnection(NodeConnectionStatus.disconnected);
        _fireSync(WalletSyncStatus.unableToSync);
      case BeamSyncStalled():
        _fireSync(WalletSyncStatus.unableToSync);
    }
    _publishScan();

    if (a.canSpend) {
      if (!_canSend.isCompleted) {
        _timings?.canSend = _timings?.since(DateTime.now());
        _canSend.complete();
      }
      _scheduleCoordinator(gen);
    }
    _watchPublicNode(a, gen);
  }

  void _publishScan() {
    if (!isScanningForCoins) return;
    final scan = _tracker?.scanProgress;
    final fraction = scan?.fraction;
    if (scan == null || fraction == null) return;
    _firePercent(fraction);
    _fireBlocksRemaining(scan.total - scan.done);
  }

  /// A public node that stays unreachable is swapped for the next public
  /// one (R11: a node problem falls back silently).
  void _watchPublicNode(BeamSyncAssessment a, int gen) {
    final session = _session;
    if (a is! BeamSyncNotConnected || session == null || session.node.isOwned) {
      _failoverTimer?.cancel();
      _failoverTimer = null;
      return;
    }
    _failoverTimer ??= Timer(const Duration(seconds: 20), () {
      _failoverTimer = null;
      final last = _lastFailover;
      if (gen != _generation ||
          _assessment is! BeamSyncNotConnected ||
          (last != null &&
              DateTime.now().difference(last) < const Duration(minutes: 1))) {
        return;
      }
      _lastFailover = DateTime.now();
      final candidates = _publicCandidates();
      final i = candidates.indexOf(session.node);
      final next = candidates[(i + 1) % candidates.length];
      environment.log('Node ${session.node} is not answering; trying $next');
      unawaited(_switchTo(next));
    });
  }

  void _scheduleCoordinator(int gen) {
    if (_coordinator != null ||
        _coordinatorTimer != null ||
        environment.createPrivateNode == null ||
        _session == null ||
        _session!.node.isOwned) {
      return;
    }
    _coordinatorTimer = Timer(environment.privateNodeStartDelay, () {
      _coordinatorTimer = null;
      unawaited(_startCoordinator(gen));
    });
  }

  Future<void> _startCoordinator(int gen) async {
    final builder = environment.createPrivateNode;
    final session = _session;
    final host = _host;
    final coordHost = _coordHost;
    if (gen != _generation ||
        builder == null ||
        session == null ||
        host == null ||
        coordHost == null ||
        _coordinator != null) {
      return;
    }
    if (!await _privateNodeWanted()) return;
    final root = await environment.beamRoot();
    final dir = await _walletDir();
    if (gen != _generation || _coordinator != null) return;
    final coordinator = BeamPrivateNodeCoordinator(
      host: coordHost,
      session: session,
      walletDir: dir,
      password: () async {
        final pw = await _secrets.readPassword();
        if (pw == null) throw StateError('wallet password missing');
        return pw;
      },
      explorer: environment.explorer,
      nodeFactory: () => builder(root, host),
      setting: environment.privateNodeSetting,
      publicNodes: _publicCandidates(),
      log: environment.log,
      // R11: the key stored at create/restore (no pause), no switch under
      // an open money flow, and body requests while a restore still scans.
      storedOwnerKey: _secrets.readOwnerKey,
      whenIdle: () => _gate.whenIdle(),
      requestBodies: () => isScanningForCoins,
    );
    _coordinator = coordinator;
    _coordinatorSessionSub = coordinator.sessions.listen(
      (s) => _onCoordinatorSession(s, gen),
    );
    _coordinatorStatusSub = coordinator.statuses.listen(
      (s) => _onCoordinatorStatus(s, gen),
    );
    // beam-node does not go through Tor: switching Tor on stops it unless
    // the user turned it on with Tor on (BeamPrivateNodePreference).
    _torSub = GlobalEventBus.instance.on<TorPreferenceChangedEvent>().listen((
      _,
    ) async {
      final c = _coordinator;
      if (c == null || gen != _generation) return;
      await c.setEnabled(await environment.privateNodeSetting.read());
    });
    unawaited(coordinator.start());
  }

  void _onCoordinatorSession(BeamSession? s, int gen) {
    if (gen != _generation) return;
    if (s == null) {
      // A switch is starting. Keep using the current session until the new
      // one arrives: a gated switch waits for any send in flight.
      _coordinatorReplacing = true;
      return;
    }
    final gated = _coordHost?.wrap(s);
    if (gated == null) return;
    unawaited(_attach(gated, gen));
  }

  void _onCoordinatorStatus(BeamPrivateNodeStatus status, int gen) {
    if (gen != _generation) return;
    _privateNodeStatus = status;
    if (status.phase == BeamPrivateNodePhase.active &&
        status.privateReceiveAvailable &&
        isScanningForCoins) {
      // The node holding the owner key has scanned the whole chain for this
      // wallet; body requests are no longer needed.
      unawaited(
        info.updateExtraBeamWalletInfo(
          beamData: (info.beamData ?? const ExtraBeamWalletInfo()).copyWith(
            restoreScanPending: false,
          ),
          isar: mainDB.isar,
        ),
      );
    }
    if (status.phase == BeamPrivateNodePhase.walletClosed) {
      environment.log('The private node left the wallet closed; reopening');
      _session = null;
      _api = null;
      unawaited(() async {
        await _disposeCoordinator();
        _coordHost?.close();
        _ensureOpening();
      }());
    }
  }

  Future<void> _disposeCoordinator() async {
    _coordinatorTimer?.cancel();
    _coordinatorTimer = null;
    final c = _coordinator;
    _coordinator = null;
    await _coordinatorSessionSub?.cancel();
    _coordinatorSessionSub = null;
    await _coordinatorStatusSub?.cancel();
    _coordinatorStatusSub = null;
    await _torSub?.cancel();
    _torSub = null;
    _coordinatorReplacing = false;
    if (c != null) {
      try {
        await c.dispose();
      } catch (e) {
        environment.log('Stopping the private node failed: $e');
      }
    }
  }

  /// Moves the open wallet to another public [node], around the private
  /// node (which is restarted afterwards).
  Future<void> _switchTo(BeamNodeEndpoint node) async {
    final session = _session;
    if (session == null) return;
    final gen = _generation;
    await _disposeCoordinator();
    try {
      final next = await session.switchNode(node);
      if (gen != _generation) {
        await next.close();
        return;
      }
      final gated = _coordHost?.wrap(next);
      if (gated != null) await _attach(gated, gen);
    } catch (e) {
      environment.log('Switching to $node failed: $e');
      if (gen != _generation) return;
      _session = null;
      _api = null;
      _ensureOpening();
    }
  }

  // ===========================================================================
  // Nodes

  BeamNodeEndpoint _preferredEndpoint() {
    final node = getCurrentNode();
    var host = node.host.trim();
    if (host.contains('://')) {
      host = Uri.tryParse(host)?.host ?? host;
    }
    return BeamNodeEndpoint(host, node.port);
  }

  /// The configured node first, then BEAM's public nodes.
  List<BeamNodeEndpoint> _publicCandidates() {
    final out = <BeamNodeEndpoint>[_preferredEndpoint()];
    for (final n in [...Beam.mainnetNodes, ...kBeamPublicWalletNodes]) {
      if (!out.contains(n)) out.add(n);
    }
    return out;
  }

  @override
  Future<void> updateNode() async {
    final next = _preferredEndpoint();
    final session = _session;
    // Not open: the next open uses it. On the private node: the public node
    // only matters as the fallback, picked up on the next open.
    if (session == null || session.node.isOwned || session.node == next) {
      return;
    }
    await _switchTo(next);
  }

  /// Whether the node answers. While open, the core's own view
  /// (`ev_connection_changed`); otherwise a TCP connect to the node.
  @override
  Future<bool> pingCheck() async {
    final connected = _tracker?.nodeConnected;
    if (_api != null && connected != null) return connected;
    final node = _preferredEndpoint();
    if (campfireTorEnabled()) {
      // With Tor on, never a direct connection (it would show this device's
      // address to the node outside Tor): through Tor's SOCKS proxy, with
      // the name resolved by Tor. Tor not up: getProxyInfo throws, "no".
      try {
        final result = await testBeamNodeConnection(
          host: node.host,
          port: node.port,
          proxyInfo: TorService.sharedInstance.getProxyInfo(),
          timeout: const Duration(seconds: 15),
        );
        return result == BeamNodeTestResult.beamNode;
      } catch (_) {
        return false;
      }
    }
    try {
      final socket = await Socket.connect(
        node.host,
        node.port,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // Refresh

  /// Reads everything from the core when it is open; starts it otherwise.
  /// Sync status events come from the honest sync verdict, not from this.
  @override
  Future<void> refresh() async {
    // recover() holds the mutex while it rebuilds wallet.db: never open the
    // core under it.
    if (refreshMutex.isLocked) return;
    if (_api == null) {
      final p = _problem;
      final retryable =
          p == null ||
          p.problem == BeamWalletProblem.nodeUnreachable ||
          p.problem == BeamWalletProblem.notOpen ||
          p.problem == BeamWalletProblem.other;
      if (retryable) _ensureOpening();
      if (p != null) {
        _fireConnection(NodeConnectionStatus.disconnected);
        _fireSync(WalletSyncStatus.unableToSync);
      }
      return;
    }
    if (refreshMutex.isLocked) return;
    await refreshMutex.protect(() async {
      await _syncFromCore(status: true, addresses: true, transactions: true);
    });
    final a = _assessment;
    if (a is BeamSynced) _fireSync(WalletSyncStatus.synced, force: true);
    ensurePeriodicRefreshTimer();
  }

  @override
  Future<void> updateChainHeight() async {
    final api = _api;
    if (api == null) return;
    final s = await api.walletStatus();
    _lastStatus = s;
    _tracker?.onStatus(s);
    if (s.currentHeight > 0) {
      await info.updateCachedChainHeight(
        newHeight: s.currentHeight,
        isar: mainDB.isar,
      );
    }
  }

  @override
  Future<void> updateBalance() => _syncFromCore(status: true);

  @override
  Future<void> updateTransactions() => _syncFromCore(transactions: true);

  @override
  Future<bool> updateUTXOs() async => false; // B-UTXO-1

  /// Saves the wallet's regular address. A new wallet already has one (the
  /// core makes a never-expiring "default" address with the file); one is
  /// created only if none is left.
  @override
  Future<void> checkSaveInitialReceivingAddress() async {
    final api = _api;
    if (api == null) return;
    if (await getCurrentReceivingAddress() != null) return;
    var own = await api.addrList(own: true);
    final usable = own.where(
      (a) => a.type == BeamAddressType.regular && !a.expired,
    );
    if (usable.isEmpty) {
      await api.createAddress(expiration: BeamAddressExpiration.never);
      own = await api.addrList(own: true);
    }
    await _storeAddresses(own);
  }

  // ===========================================================================
  // Fees and sending

  @override
  Future<FeeObject> get fees async => FeeObject(
    numberOfBlocksFast: 1,
    numberOfBlocksAverage: 1,
    numberOfBlocksSlow: 1,
    fast: kBeamDefaultFee,
    medium: kBeamDefaultFee,
    slow: kBeamDefaultFee,
  );

  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async {
    final api = _api;
    var fee = kBeamDefaultFee;
    if (api != null && amount.raw > BigInt.zero) {
      try {
        fee = (await api.calcChange(amount: amount.raw)).explicitFee;
      } catch (_) {
        // Not enough funds for that amount, or not open: the default fee.
      }
    }
    return Amount(rawValue: fee, fractionDigits: cryptoCurrency.fractionDigits);
  }

  BeamApi _requireApi() =>
      _api ??
      (throw _problem ??
          const BeamWalletException(
            BeamWalletProblem.notOpen,
            BeamWalletMessages.notOpen,
          ));

  static void _checkBeamOnly(TxData txData) {
    // Asset sends arrive with B-ASSET-2; refuse rather than send BEAM.
    final other = txData.otherData;
    if (other == null || other.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(other);
    } on FormatException {
      return;
    }
    final assetId = decoded is Map ? decoded['assetId'] : null;
    if (assetId != null && assetId != 0) {
      throw const BeamWalletException(
        BeamWalletProblem.other,
        'Sending Confidential Assets is not available yet.',
      );
    }
  }

  /// Validates and prices a send; never broadcasts. Campfire's PIN or
  /// password gate sits between this and [confirmSend].
  ///
  /// Holds the node switch until [confirmSend] finishes (or ten minutes
  /// pass), so the private node cannot restart wallet-api under the
  /// confirmation screen.
  @override
  Future<TxData> prepareSend({required TxData txData}) async {
    final lease = _gate.hold('send', maxHold: const Duration(minutes: 10));
    try {
      final recipients = txData.recipients;
      if (recipients == null || recipients.length != 1) {
        throw const BeamWalletException(
          BeamWalletProblem.other,
          'A BEAM payment goes to one address at a time.',
        );
      }
      _checkBeamOnly(txData);
      final recipient = recipients.first;
      final address = recipient.address.trim();
      BeamSendRules.checkAddress(address);
      final api = _requireApi();
      BeamSendRules.checkSynced(_assessment);

      final validation = await api.validateAddress(address);
      if (!validation.isValid) {
        throw const BeamWalletException(
          BeamWalletProblem.invalidAddress,
          "That address isn't valid or has expired. Ask for a new one.",
        );
      }
      BeamSendRules.checkAddressType(validation.type);
      final mode = BeamSendMode.forType(validation.type);

      final status = await api.walletStatus();
      _lastStatus = status;
      _tracker?.onStatus(status);
      final available = BeamBalanceMapper.totalsFor(status, 0).available;
      BigInt fee;
      try {
        fee = (await api.calcChange(amount: recipient.amount.raw)).explicitFee;
      } catch (_) {
        fee = kBeamDefaultFee;
      }
      if (fee < mode.minimumFee) fee = mode.minimumFee;
      final send = BeamSendRules.checkAmount(
        amount: recipient.amount.raw,
        fee: fee,
        available: available,
        fractionDigits: cryptoCurrency.fractionDigits,
      );

      _preparedSend?.release();
      _preparedSend = lease;
      return txData.copyWith(
        recipients: [
          recipient.copyWith(
            address: address,
            amount: Amount(
              rawValue: send,
              fractionDigits: cryptoCurrency.fractionDigits,
            ),
          ),
        ],
        fee: Amount(
          rawValue: fee,
          fractionDigits: cryptoCurrency.fractionDigits,
        ),
      );
    } catch (e) {
      lease.release();
      throw beamWalletExceptionFrom(e);
    }
  }

  /// Sends what [prepareSend] priced with `tx_send` and returns its tx id.
  ///
  /// The tx id is generated first, so a dropped connection can be checked
  /// (`tx_status`) instead of risking a second payment.
  @override
  Future<TxData> confirmSend({required TxData txData}) async {
    final lease = _gate.hold('confirm send');
    try {
      final recipient = txData.recipients?.singleOrNull;
      final fee = txData.fee;
      if (recipient == null || fee == null) {
        throw const BeamWalletException(
          BeamWalletProblem.other,
          'This payment was not prepared. Go back and review it again.',
        );
      }
      _checkBeamOnly(txData);
      final mode = BeamSendMode.forType(
        BeamSendRules.checkAddress(recipient.address),
      );
      if (fee.raw < mode.minimumFee) {
        throw const BeamWalletException(
          BeamWalletProblem.other,
          'The fee changed for this kind of address. Go back and review '
          'the payment again.',
        );
      }
      final api = _requireApi();
      BeamSendRules.checkSynced(_assessment);

      final txId = await api.generateTxId();
      final note = txData.noteOnChain;
      String sentId;
      try {
        sentId = await api.txSend(
          address: recipient.address.trim(),
          value: recipient.amount.raw,
          fee: fee.raw,
          assetId: 0,
          offline: mode.offlineFlag ? true : null,
          // Only an explicitly shared note goes to the other wallet;
          // Campfire's own notes stay local.
          comment: note == null || note.isEmpty ? null : note,
          txId: txId,
        );
      } on BeamRpcException catch (e) {
        throw BeamWalletException(
          e.message.toLowerCase().contains('funds')
              ? BeamWalletProblem.insufficientFunds
              : BeamWalletProblem.sendRejected,
          'The payment was not sent: ${e.message}',
        );
      } on BeamConnectionException {
        sentId = await _lookUpSent(api, txId);
      } on TimeoutException {
        sentId = await _lookUpSent(api, txId);
      }
      _markDirty(status: true, transactions: true);
      return txData.copyWith(txid: sentId);
    } catch (e) {
      throw beamWalletExceptionFrom(e);
    } finally {
      lease.release();
      _preparedSend?.release();
      _preparedSend = null;
    }
  }

  static Future<String> _lookUpSent(BeamApi api, String txId) async {
    try {
      return (await api.txStatus(txId)).txId;
    } catch (_) {
      throw const BeamWalletException(
        BeamWalletProblem.sendOutcomeUnknown,
        "The connection dropped while sending, so it's not certain whether "
        'the payment went out. Check your transaction history before '
        'sending again.',
      );
    }
  }

  // ===========================================================================
  // Campfire events

  void _fireSync(WalletSyncStatus status, {bool force = false}) {
    if (!force && status == _lastSyncStatus) return;
    _lastSyncStatus = status;
    if (doNotFireRefreshEvents) return;
    GlobalEventBus.instance.fire(
      WalletSyncStatusChangedEvent(status, walletId, cryptoCurrency),
    );
  }

  void _fireConnection(NodeConnectionStatus status) {
    xmrAndWowSyncSpecificFunctionThatShouldBeGottenRidOfInTheFuture(
      status == NodeConnectionStatus.connected,
    );
    if (status == _lastConnection) return;
    _lastConnection = status;
    if (doNotFireRefreshEvents) return;
    GlobalEventBus.instance.fire(
      NodeConnectionStatusChangedEvent(status, walletId, cryptoCurrency),
    );
  }

  void _firePercent(double percent) {
    if (doNotFireRefreshEvents) return;
    GlobalEventBus.instance.fire(
      RefreshPercentChangedEvent(percent.clamp(0.0, 1.0), walletId),
    );
  }

  void _fireBlocksRemaining(int blocks) {
    if (doNotFireRefreshEvents) return;
    GlobalEventBus.instance.fire(BlocksRemainingEvent(blocks, walletId));
  }

  void _cancelTimers() {
    _debounce?.cancel();
    _debounce = null;
    _statusPoll?.cancel();
    _statusPoll = null;
    _failoverTimer?.cancel();
    _failoverTimer = null;
    _coordinatorTimer?.cancel();
    _coordinatorTimer = null;
  }

  @visibleForTesting
  BeamWalletStatus? get lastStatus => _lastStatus;

  @visibleForTesting
  BeamNodeSwitchGate get nodeSwitchGate => _gate;

  @visibleForTesting
  BeamPrivateNodeCoordinator? get privateNodeCoordinator => _coordinator;
}

/// Deletes a BEAM wallet's file and secrets (`wallet.db` directory, wallet
/// password, owner key). Call after [BeamWallet.exit].
Future<void> deleteBeamWallet({
  required String walletId,
  required SecureStorageInterface secureStore,
}) => deleteBeamWalletData(walletId: walletId, secureStore: secureStore);
