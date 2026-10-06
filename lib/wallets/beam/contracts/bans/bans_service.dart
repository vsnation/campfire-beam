/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../api/beam_api.dart';
import '../../explorer/beam_explorer_client.dart';
import '../../explorer/explorer_table.dart';
import '../../models/beam_call_results.dart';
import '../../rpc/beam_transport.dart';
import '../common/asset_shader_source.dart';
import '../common/contract_args.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import 'bans_args.dart';
import 'bans_constants.dart';
import 'bans_exceptions.dart';
import 'bans_models.dart';
import 'bans_name.dart';
import 'bans_timeline.dart';

/// What a prepared BANS transaction does.
enum BansAction {
  register,
  extend,
  setOwner,
  setPrice,
  buy,
  pay,
  claimAll,
  claimSaleProceeds,
}

/// A name looked up through the wallet's own node session (`view_name`).
/// This is the only lookup a payment may rely on.
@immutable
class BansResolution {
  const BansResolution({
    required this.name,
    required this.domain,
    required this.tipHeight,
    required this.tipTime,
    required this.walletInSync,
  });

  final BansName name;

  /// Null when the name was never registered.
  final BansDomain? domain;

  /// The wallet's height and block time when this was read.
  final int tipHeight;
  final DateTime tipTime;

  /// `wallet_status.is_in_sync` at the time. A wallet that is behind reads
  /// old state; the caller decides whether to trust it (sync rules).
  final bool walletInSync;

  BansNameStatus get status =>
      domain?.statusAt(tipHeight) ?? BansNameStatus.available;

  String? get ownerKey => domain?.ownerKey;

  BansClock get clock => BansClock(tipHeight: tipHeight, tipTime: tipTime);

  /// Estimated end of the current term, or null when unregistered.
  DateTime? get expiresAt =>
      domain == null ? null : clock.dateOf(domain!.expireHeight);

  /// "Renew by" / "free again after": the end of the 90-day hold.
  DateTime? get holdEndsAt => domain == null
      ? null
      : clock.dateOf(BansTimeline.holdEndHeight(domain!.expireHeight));
}

/// A name looked up on a public explorer, with no wallet open.
///
/// **Display only.** It comes from a third party and is not proof of who
/// owns the name. There is deliberately no way to pay from it: payments go
/// through [BeamBansService.preparePay], which resolves the name again on
/// the wallet's own node.
@immutable
class BansUnverifiedLookup {
  const BansUnverifiedLookup({
    required this.name,
    required this.domain,
    required this.explorerHeight,
    this.explorerStatusLabel,
  });

  final BansName name;
  final BansDomain? domain;

  /// The explorer's height when it answered.
  final int explorerHeight;

  /// The explorer's own label: `""` (active), `On Hold` or `Expired`.
  final String? explorerStatusLabel;

  /// Always false: this result must never be used as a payee.
  bool get verified => false;

  BansNameStatus get status =>
      domain?.statusAt(explorerHeight) ?? BansNameStatus.available;
}

/// The names this wallet owns (`view_domain` filtered by `my_key`).
@immutable
class BansMyNames {
  const BansMyNames({
    required this.key,
    required this.names,
    required this.tipHeight,
    required this.tipTime,
  });

  /// This wallet's BANS key. Every name below shares it, so they are
  /// publicly linkable to each other.
  final String key;
  final List<BansDomain> names;
  final int tipHeight;
  final DateTime tipTime;
}

/// What a prepared transaction will do, read back from the transaction the
/// core built (never from the request), for the confirmation screen.
@immutable
class BansSummary {
  const BansSummary({
    required this.action,
    required this.youPay,
    required this.youReceive,
    required this.fee,
    required this.paidTo,
    required this.contractId,
    required this.comments,
    this.name,
    this.ownerKey,
    this.periods,
    this.expireHeight,
    this.usdTotal,
    this.usdPerBeamText,
    this.listPrice,
  });

  final BansAction action;
  final BansName? name;

  /// What leaves the wallet, fee excluded, per asset.
  final List<BansAmount> youPay;

  /// What arrives in the wallet (claims), per asset.
  final List<BansAmount> youReceive;

  /// The network fee in groth (BEAM), as the core will charge it.
  final BigInt fee;

  /// Who receives [youPay], in plain words.
  final String paidTo;

  /// The contract the call goes to (the Anon-Vault for payments and claims,
  /// the BANS contract otherwise).
  final String contractId;

  /// For [BansAction.pay]: the owner key the payment was built for. For
  /// register and buy: the key that will own the name (this wallet's). For
  /// setOwner: the new owner.
  final String? ownerKey;

  final int? periods;

  /// Estimated expiry after the transaction: new for register and extend,
  /// unchanged for buy.
  final int? expireHeight;

  /// The USD price the BEAM amount was derived from (register, extend).
  final int? usdTotal;

  /// The oracle median as `view_params` printed it, for display.
  final String? usdPerBeamText;

  /// For [BansAction.setPrice]: the new price; null or zero takes the name
  /// off sale.
  final BansAmount? listPrice;

  /// Kernel comments, e.g. `BANS: registering domain`.
  final List<String> comments;

  /// BEAM leaving the wallet including the fee, in groth.
  BigInt get totalBeam =>
      youPay
          .where((a) => a.assetId == 0)
          .fold(BigInt.zero, (s, a) => s + a.amount) +
      fee;

  /// Plain-text lines for logs and tests. The UI formats amounts itself,
  /// with each asset's own decimals.
  List<String> get lines => [
    _headline(),
    for (final a in youPay) 'You pay: ${formatAmount(a)}',
    for (final a in youReceive) 'You receive: ${formatAmount(a)}',
    'Network fee: ${formatAmount(BansAmount(0, fee))}',
    'Total BEAM out: ${formatAmount(BansAmount(0, totalBeam))}',
    'Paid to: $paidTo',
    if (ownerKey != null) 'Owner key: ${BansKey.fingerprint(ownerKey!)}',
    if (usdTotal != null && usdPerBeamText != null)
      'Priced at \$$usdTotal at about $usdPerBeamText USD per BEAM',
  ];

  String _headline() {
    final n = name?.value ?? '';
    final years = periods == 1 ? '1 year' : '$periods years';
    return switch (action) {
      BansAction.register => 'Register $n for $years',
      BansAction.extend => 'Renew $n for $years',
      BansAction.setOwner => 'Transfer $n',
      BansAction.setPrice =>
        listPrice == null || listPrice!.amount == BigInt.zero
            ? 'Take $n off sale'
            : 'List $n for sale at ${formatAmount(listPrice!)}',
      BansAction.buy => 'Buy $n',
      BansAction.pay => 'Send to $n.beam (anonymous name payment)',
      BansAction.claimAll => 'Claim payments sent to your names',
      BansAction.claimSaleProceeds => 'Claim the proceeds of names you sold',
    };
  }

  /// `1.5 BEAM` for BEAM; `150 units of asset 7` for anything else, since
  /// only the caller knows that asset's decimals.
  static String formatAmount(BansAmount a) {
    if (a.assetId != 0) return '${a.amount} units of asset ${a.assetId}';
    final whole = a.amount ~/ BigInt.from(100000000);
    final frac = (a.amount.remainder(BigInt.from(100000000))).toString();
    final f = frac.padLeft(8, '0').replaceFirst(RegExp(r'0+$'), '');
    return f.isEmpty ? '$whole BEAM' : '$whole.$f BEAM';
  }
}

/// A transaction built by the core and not yet signed. Pass it to
/// [BeamBansService.execute] after the user confirms [summary].
@immutable
class BansPrepared {
  const BansPrepared({
    required this.action,
    required this.args,
    required this.rawData,
    required this.invokeData,
    required this.summary,
  });

  final BansAction action;

  /// The shader arguments it was built from (no secrets).
  final String args;

  /// `raw_data` for `process_invoke_data`.
  final List<int> rawData;
  final BeamInvokeData invokeData;
  final BansSummary summary;
}

/// BANS for one BEAM wallet: resolve names, list mine, and build every
/// name transaction for confirmation before anything is signed.
///
/// Every call runs the pinned app shader with `create_tx: false`, so the
/// core returns the transaction instead of sending it. [execute] is the
/// only method that sends anything.
///
/// [shader] defaults to the bundled `assets/beam/shaders/bans_app.wasm`
/// (see [bansAppShader]); a file that is not the pinned build is never run
/// and surfaces as [BansShaderMismatch].
class BeamBansService {
  BeamBansService(
    this._api,
    this._explorer, {
    PinnedShader? shader,
    this.args = BansArgs.mainnet,
    this.callTimeout = const Duration(seconds: 90),
  }) : _shader = shader ?? bansAppShader(AssetShaderSource());

  final BeamApi _api;
  final BeamExplorerClient? _explorer;
  final PinnedShader _shader;
  final BansArgs args;

  /// Per shader call. `view_domain` over every name returns about 58 KB.
  final Duration callTimeout;

  String? _myKey;

  // ------------------------------------------------------------ reads

  /// This wallet's BANS key (cached: it is fixed per wallet and contract).
  Future<String> myKey() async =>
      _myKey ??= BansOutput.myKey(await _read(args.myKey()));

  /// Contract settings and the current oracle median.
  Future<BansParams> params() async =>
      BansOutput.viewParams(await _read(args.viewParams()));

  /// Looks [name] up on the wallet's own node. Authoritative.
  Future<BansResolution> resolve(BansName name) async {
    final status = await _api.walletStatus();
    final domain = BansOutput.viewName(await _read(args.viewName(name)), name);
    return BansResolution(
      name: name,
      domain: domain,
      tipHeight: status.currentHeight,
      tipTime: status.currentStateTime,
      walletInSync: status.isInSync,
    );
  }

  /// Looks [name] up on a public explorer, with no wallet needed. Display
  /// only (see [BansUnverifiedLookup]). Throws [StateError] when the
  /// service has no explorer, and [BeamExplorerException] when no explorer
  /// answers.
  Future<BansUnverifiedLookup> lookupWithoutWallet(BansName name) async {
    final explorer = _explorer;
    if (explorer == null) {
      throw StateError('no explorer configured for wallet-less lookups');
    }
    final json = await explorer.contract(args.cid, state: true, nMaxTxs: 0);
    return parseExplorerLookup(json, name);
  }

  /// Every name this wallet owns, expired ones included.
  Future<BansMyNames> myNames() async {
    final key = await myKey();
    final status = await _api.walletStatus();
    final names = BansOutput.viewDomain(
      await _read(args.viewDomain(ownerKey: key)),
    );
    return BansMyNames(
      key: key,
      names: names,
      tipHeight: status.currentHeight,
      tipTime: status.currentStateTime,
    );
  }

  /// My names plus payments and sale proceeds waiting to be claimed. Throws
  /// [BansClaimUnsupported] on a wallet-api without privilege 1.
  Future<BansInbox> inbox() async =>
      BansOutput.userView(await _read(args.userView()));

  // ----------------------------------------------------------- writes

  /// Builds a registration of [name] for [periods] years (1 to 50). The
  /// summary carries the exact BEAM price the kernel locks.
  Future<BansPrepared> prepareRegister(BansName name, int periods) async {
    final status = await _api.walletStatus();
    final p = await params();
    final a = args.register(name, periods);
    final built = await _build(a);
    final e = _single(built, args.cid, BansMethod.register);
    final r = BeamArgsReader(e.args);
    final owner = r.pubKey();
    _expect(r.u8() == periods, 'periods');
    _expectName(r, name);
    _expect(owner == await myKey(), 'the name is registered to this wallet');
    final pay = _onlyBeamSpend(e);
    return _prepared(BansAction.register, a, built, BansSummary(
      action: BansAction.register,
      name: name,
      youPay: [pay],
      youReceive: const [],
      fee: built.data.fee,
      paidTo: 'the BEAM DAO vault (name registration fee)',
      contractId: p.daoVaultCid,
      comments: built.data.comments,
      ownerKey: owner,
      periods: periods,
      expireHeight: BansTimeline.expiryAfterRegister(
        tipHeight: status.currentHeight,
        periods: periods,
      ),
      usdTotal: name.usdPerPeriod * periods,
      usdPerBeamText: p.usdPerBeamText,
    ));
  }

  /// Builds a renewal of a name this wallet owns.
  Future<BansPrepared> prepareExtend(BansName name, int periods) async {
    final res = await resolve(name);
    final p = await params();
    final a = args.extend(name, periods);
    final built = await _build(a);
    final e = _single(built, args.cid, BansMethod.extend);
    final r = BeamArgsReader(e.args);
    _expect(r.u8() == periods, 'periods');
    _expectName(r, name);
    final pay = _onlyBeamSpend(e);
    final expire = res.domain?.expireHeight;
    return _prepared(BansAction.extend, a, built, BansSummary(
      action: BansAction.extend,
      name: name,
      youPay: [pay],
      youReceive: const [],
      fee: built.data.fee,
      paidTo: 'the BEAM DAO vault (name renewal fee)',
      contractId: p.daoVaultCid,
      comments: built.data.comments,
      ownerKey: res.ownerKey,
      periods: periods,
      expireHeight: expire == null
          ? null
          : BansTimeline.expiryAfterExtend(
              expireHeight: expire,
              tipHeight: res.tipHeight,
              periods: periods,
            ),
      usdTotal: name.usdPerPeriod * periods,
      usdPerBeamText: p.usdPerBeamText,
    ));
  }

  /// Builds a transfer of [name] to [newOwnerKey]. Irreversible once sent.
  Future<BansPrepared> prepareSetOwner(
    BansName name,
    String newOwnerKey,
  ) async {
    final key = BansKey.require(newOwnerKey);
    final a = args.setOwner(name, key);
    final built = await _build(a);
    final e = _single(built, args.cid, BansMethod.setOwner);
    final r = BeamArgsReader(e.args);
    _expect(r.pubKey() == key, 'new owner key');
    _expectName(r, name);
    _expect(e.spend.isEmpty, 'a transfer moves no funds');
    return _prepared(BansAction.setOwner, a, built, BansSummary(
      action: BansAction.setOwner,
      name: name,
      youPay: const [],
      youReceive: const [],
      fee: built.data.fee,
      paidTo: 'nobody: only the network fee is paid',
      contractId: args.cid,
      comments: built.data.comments,
      ownerKey: key,
    ));
  }

  /// Builds a listing of [name] at [amount] of [assetId]; an [amount] of
  /// zero takes it off sale.
  Future<BansPrepared> prepareSetPrice(
    BansName name,
    int assetId,
    BigInt amount,
  ) async {
    final a = args.setPrice(name, assetId, amount);
    final built = await _build(a);
    final e = _single(built, args.cid, BansMethod.setPrice);
    final r = BeamArgsReader(e.args);
    _expect(r.u32() == assetId, 'asset');
    _expect(r.u64() == amount, 'price');
    _expectName(r, name);
    _expect(e.spend.isEmpty, 'a listing moves no funds');
    final price = BansAmount(assetId, amount);
    return _prepared(BansAction.setPrice, a, built, BansSummary(
      action: BansAction.setPrice,
      name: name,
      youPay: const [],
      youReceive: const [],
      fee: built.data.fee,
      paidTo: amount == BigInt.zero
          ? 'nobody: this takes the name off sale'
          : 'nobody now. A buyer pays the price into the vault, and you '
                'claim it here',
      contractId: args.cid,
      comments: built.data.comments,
      listPrice: price,
    ));
  }

  /// Builds a purchase of a listed name. The buyer gets the time left on
  /// the name, not a new term.
  Future<BansPrepared> prepareBuy(BansName name) async {
    final res = await resolve(name);
    final listed = res.domain?.salePrice;
    final a = args.buy(name);
    final built = await _build(a);
    final e = _single(built, args.cid, BansMethod.buy);
    final r = BeamArgsReader(e.args);
    final newOwner = r.pubKey();
    _expectName(r, name);
    _expect(newOwner == await myKey(), 'the name goes to this wallet');
    final pays = _spends(e);
    _expect(
      listed != null && pays.length == 1 && pays.single == listed,
      'the kernel pays the listed price',
    );
    return _prepared(BansAction.buy, a, built, BansSummary(
      action: BansAction.buy,
      name: name,
      youPay: pays,
      youReceive: const [],
      fee: built.data.fee,
      paidTo: 'the current owner of $name, through the BEAM vault',
      contractId: args.cid,
      comments: built.data.comments,
      ownerKey: newOwner,
      expireHeight: res.domain?.expireHeight,
    ));
  }

  /// Builds an anonymous payment of [amount] of [assetId] to [name].
  ///
  /// The name is resolved on the wallet's node right before and right
  /// after the core builds the payment; if the owner differs between the
  /// two, or from [expectedOwnerKey] (the key the user was shown), it
  /// throws [BansOwnerChanged]. [execute] checks once more before signing.
  Future<BansPrepared> preparePay(
    BansName name,
    int assetId,
    BigInt amount, {
    String? expectedOwnerKey,
  }) async {
    final p = await params();
    final before = await resolve(name);
    final key = before.ownerKey;
    if (expectedOwnerKey != null && key != expectedOwnerKey) {
      throw BansOwnerChanged(name.value, expectedOwnerKey, key);
    }
    final a = args.pay(name, assetId, amount);
    final built = await _build(a);
    final after = await resolve(name);
    if (key == null || after.ownerKey != key) {
      throw BansOwnerChanged(name.value, key ?? '', after.ownerKey);
    }
    final e = _single(built, p.vaultCid, BansMethod.vaultDeposit);
    final r = BeamArgsReader(e.args);
    _expect(r.u64() == amount, 'amount');
    final custom = r.u32();
    r.pubKey(); // one-time spend key
    _expect(r.u32() == assetId, 'asset');
    _expect(custom == 33 + kBansNameMaxLength && r.remaining == custom,
        'sender key and encrypted name');
    final pays = _spends(e);
    _expect(
      pays.length == 1 && pays.single == BansAmount(assetId, amount),
      'the kernel pays exactly the amount',
    );
    return _prepared(BansAction.pay, a, built, BansSummary(
      action: BansAction.pay,
      name: name,
      youPay: pays,
      youReceive: const [],
      fee: built.data.fee,
      paidTo: 'the owner of ${name.display}, anonymously. They claim it '
          'later; the amount is visible on the blockchain',
      contractId: p.vaultCid,
      comments: built.data.comments,
      ownerKey: key,
      expireHeight: after.domain?.expireHeight,
    ));
  }

  /// Builds a claim of up to 30 waiting payments and sale proceeds. Throws
  /// [BansClaimUnsupported] on a wallet-api without privilege 1.
  Future<BansPrepared> prepareClaimAll() async {
    final p = await params();
    final a = args.receiveAll();
    final built = await _build(a, claim: true);
    return _claim(BansAction.claimAll, a, built, p.vaultCid);
  }

  /// Builds a claim of the proceeds of sold names held in [assetId]. Works
  /// on stock wallet-api (privilege 0).
  Future<BansPrepared> prepareClaimSaleProceeds(int assetId) async {
    final p = await params();
    final a = args.receive(assetId: assetId);
    final built = await _build(a, claim: true);
    return _claim(BansAction.claimSaleProceeds, a, built, p.vaultCid);
  }

  /// Signs and sends [prepared]. For a payment, the name is resolved once
  /// more first and nothing is sent if its owner changed. Returns the tx id.
  Future<String> execute(BansPrepared prepared) async {
    if (prepared.action == BansAction.pay) {
      final name = prepared.summary.name!;
      final expected = prepared.summary.ownerKey!;
      final now = await resolve(name);
      if (now.ownerKey != expected) {
        throw BansOwnerChanged(name.value, expected, now.ownerKey);
      }
      if (!now.status.canReceivePayments) {
        throw BansShaderRefused(BansRefusal.domainExpired.wire);
      }
    }
    return _api.processInvokeData(prepared.rawData, timeout: callTimeout);
  }

  // --------------------------------------------------------- explorer

  /// Finds [name] in an explorer `/contract?id=<BANS>&state=1` answer.
  static BansUnverifiedLookup parseExplorerLookup(
    Map<String, Object?> json,
    BansName name,
  ) {
    final kind = json['kind'];
    if (kind is! String || !kind.startsWith('Bans')) {
      throw const FormatException('explorer: not a BANS contract');
    }
    final height = parseExplorerInt(json['h']);
    if (height == null) throw const FormatException('explorer: no height');
    final state = json['State'];
    if (state is! Map) throw const FormatException('explorer: no State');
    final table = ExplorerTable.parse(state['Domains']);
    for (final row in table.rows) {
      if (row['Name'] != name.value) continue;
      final owner = row['Owner'];
      final expire = row.intOf('Expiration height');
      if (owner is! String || !BansKey.isValid(owner) || expire == null) {
        throw const FormatException('explorer: malformed domain row');
      }
      return BansUnverifiedLookup(
        name: name,
        domain: BansDomain(
          name: name.value,
          ownerKey: owner,
          expireHeight: expire,
          salePrice: _explorerPrice(row.raw('Sell price')),
        ),
        explorerHeight: height,
        explorerStatusLabel: row.stringOf('Status') ?? '',
      );
    }
    return BansUnverifiedLookup(
      name: name,
      domain: null,
      explorerHeight: height,
    );
  }

  static BansAmount? _explorerPrice(Object? cell) {
    if (cell is! List || cell.length != 2) return null;
    final aid = parseExplorerInt(cell[0]);
    final amount = parseExplorerBigInt(cell[1]);
    if (aid == null || amount == null || amount <= BigInt.zero) return null;
    return BansAmount(aid, amount);
  }

  // ---------------------------------------------------------- helpers

  /// Whether [e] is the core refusing a privilege-1 shader operation.
  static bool isPrivilegeFailure(BeamRpcException e) {
    final data = e.data;
    final text = '${e.message} ${data is String ? data : jsonEncode(data)}';
    return text.contains('get_PkEx') || text.contains('get_BlindSk');
  }

  Future<BeamInvokeResult> _invoke(String a) async {
    final Uint8List shader;
    try {
      shader = await _shader.load();
    } on PinnedShaderException catch (e) {
      throw BansShaderMismatch(e.actualSha256 ?? '', e.actualSize ?? 0);
    }
    try {
      return await _api.invokeContract(
        createTx: false,
        args: a,
        contractBytes: shader,
        timeout: callTimeout,
      );
    } on BeamRpcException catch (e) {
      if (isPrivilegeFailure(e)) throw BansClaimUnsupported(e.data);
      rethrow;
    }
  }

  Future<String> _read(String a) async => (await _invoke(a)).output;

  /// Builds [a] and decodes the result. Only a [claim] may contain
  /// advanced entries: claims withdraw from the Anon-Vault with kernels the
  /// shader co-signs (`vault_anon/app_impl.h:430-440`); nothing else BANS
  /// builds is one, so anywhere else an advanced entry is refused.
  Future<_Built> _build(String a, {bool claim = false}) async {
    final r = await _invoke(a);
    BansOutput.decode(r.output); // throws BansShaderRefused
    final raw = r.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BansUnexpectedTransaction('no transaction was built');
    }
    final BeamInvokeData data;
    try {
      data = BeamInvokeData.decode(raw, allowAdvanced: claim);
    } on FormatException catch (e) {
      throw BansUnexpectedTransaction('undecodable: ${e.message}');
    }
    return _Built(raw, data);
  }

  BansPrepared _prepared(
    BansAction action,
    String a,
    _Built built,
    BansSummary summary,
  ) => BansPrepared(
    action: action,
    args: a,
    rawData: built.raw,
    invokeData: built.data,
    summary: summary,
  );

  BansPrepared _claim(BansAction action, String a, _Built built, String vault) {
    final d = built.data;
    _expect(d.entries.isNotEmpty, 'at least one claim');
    for (final e in d.entries) {
      _expect(
        e.contractId == vault && e.method == BansMethod.vaultWithdraw,
        'claims withdraw from the BANS vault',
      );
    }
    final spend = d.spend;
    _expect(spend.values.every((v) => v < BigInt.zero), 'claims only receive');
    return _prepared(action, a, built, BansSummary(
      action: action,
      youPay: const [],
      youReceive: [
        for (final s in spend.entries) BansAmount(s.key, -s.value),
      ],
      fee: d.fee,
      paidTo: 'this wallet',
      contractId: vault,
      comments: d.comments,
    ));
  }

  static BeamInvokeEntry _single(_Built b, String cid, int method) {
    final d = b.data;
    _expect(d.entries.length == 1, 'one contract call');
    final e = d.entries.single;
    _expect(e.contractId == cid, 'contract $cid');
    _expect(e.method == method, 'method $method');
    _expect(!e.isMultisigned, 'not multisig');
    return e;
  }

  static List<BansAmount> _spends(BeamInvokeEntry e) => [
    for (final s in e.spend.entries)
      if (s.value != BigInt.zero) BansAmount(s.key, s.value),
  ];

  static BansAmount _onlyBeamSpend(BeamInvokeEntry e) {
    final s = _spends(e);
    _expect(
      s.length == 1 && s.single.assetId == 0 && s.single.amount > BigInt.zero,
      'the fee is paid in BEAM',
    );
    return s.single;
  }

  static void _expectName(BeamArgsReader r, BansName name) {
    final len = r.u8();
    final bytes = r.bytes(len);
    _expect(
      String.fromCharCodes(bytes) == name.value && r.atEnd,
      'name ${name.value}',
    );
  }

  static void _expect(bool ok, String what) {
    if (!ok) throw BansUnexpectedTransaction('expected $what');
  }
}

class _Built {
  const _Built(this.raw, this.data);

  final List<int> raw;
  final BeamInvokeData data;
}
