/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The owner will add Ethereum (ETH, ERC-20, WBEAM) to this app with Stack
// Wallet's own Ethereum code. Every wiring change must therefore be a BEAM
// branch that leaves the Ethereum paths exactly as upstream has them: the
// token list with "Edit tokens" on desktop, the "Tokens" row in the phone's
// More, the ETH Transactions tab, the swap / buy entries, `hasTokenSupport`.
//
// An Ethereum wallet cannot be built in this test: Campfire is configured
// BEAM-only, and `WalletInfo` asserts that its coin is in `AppConfig.coins`
// (and `WalletInfo.coin` looks it up there). So this checks the menu code
// itself: every BEAM entry point sits behind a `BeamWallet` guard, and every
// Ethereum expression the menus had is still there, unchanged. The BEAM
// wallet's own menus are checked by running them in the other files here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_wallet_features.dart';
import 'package:stackwallet/widgets/beam/wiring/beam_features.dart';

/// [path]'s source with all whitespace collapsed to single spaces, so the
/// checks do not depend on line breaks or the formatter.
String _src(String path) =>
    File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

void _has(String src, String code, String why) =>
    expect(src.contains(_norm(code)), isTrue, reason: why);

int _count(String src, String code) =>
    RegExp(RegExp.escape(_norm(code))).allMatches(src).length;

const _wv = 'lib/pages/wallet_view/wallet_view.dart';
const _dwv =
    'lib/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
const _dwf =
    'lib/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_wallet_features.dart';
const _mw =
    'lib/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/my_wallet.dart';
const _wob =
    'lib/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/wallet_options_button.dart';
const _rg = 'lib/route_generator.dart';

void main() {
  test('phone wallet bar: BEAM items only behind a BeamWallet guard; '
      'Ethereum keeps Tokens in More, Swap and Buy', () {
    final s = _src(_wv);
    _has(
      s,
      'if (wallet is BeamWallet) ...beamWalletNavItems(context, wallet),',
      'the BEAM bar items are a BEAM branch',
    );
    _has(
      s,
      'if (wallet is BeamWallet) ...beamWalletMoreItems(context, wallet),',
      'the BEAM More rows are a BEAM branch',
    );
    expect(_count(s, 'beamWalletNavItems('), 1);
    expect(_count(s, 'beamWalletMoreItems('), 1);
    // Upstream, unchanged: the token list for coins with tokens (Ethereum).
    _has(
      s,
      '''
      .hasTokenSupport, ), )) WalletNavigationBarItemData( label: "Tokens",
      icon: const CoinControlNavIcon(), onTap: () {
      Navigator.of(context).pushNamed( MyTokensView.routeName,
      arguments: walletId, ); }, ),''',
      'Ethereum keeps its Tokens row in More',
    );
    _has(
      s,
      '''
      WalletNavigationBarItemData( label: "Swap", icon: const ExchangeNavIcon(),
      onTap: () => _onExchangePressed(context), ),''',
      'the exchange Swap is untouched',
    );
    _has(s, '''
      WalletNavigationBarItemData( label: "Buy", icon: const BuyNavIcon(),
      onTap: () => _onBuyPressed(context), ),''', 'Buy is untouched');
  });

  test('desktop feature row: BEAM returns its own list first; the other '
      'coins\' rules are untouched', () {
    final s = _src(_dwf);
    _has(
      s,
      'if (wallet is BeamWallet) return beamDesktopWalletFeatures(context, '
          'wallet);',
      'a BEAM wallet gets only its own features',
    );
    expect(_count(s, 'beamDesktopWalletFeatures('), 1);
    for (final upstream in const [
      '(WalletFeature.swap, Assets.svg.swap, _onSwapPressed),',
      '(WalletFeature.buy, Assets.svg.swap, _onBuyPressed),',
      '(WalletFeature.sign, Assets.svg.pencil, _onSignPressed),',
      '(WalletFeature.paynym, Assets.svg.robotHead, _onPaynymPressed),',
    ]) {
      _has(s, upstream, '$upstream is still built for other coins');
    }
    // The BEAM values of Campfire's WalletFeature are BEAM's alone.
    for (final f in WalletFeature.values) {
      expect(
        f.name.startsWith('beam'),
        kBeamWalletFeatures.containsValue(f),
        reason: f.name,
      );
    }
  });

  test('desktop wallet screen: Assets for BEAM; Ethereum keeps "Tokens", '
      '"Edit" and its token list', () {
    final s = _src(_dwv);
    _has(s, '''
      wallet is BeamWallet ? "Assets" : wallet.cryptoCurrency.hasTokenSupport
      ? "Tokens" : "Recent activity",''', 'the header');
    _has(
      s,
      '''
      if (wallet is! BeamWallet) CustomTextButton( text:
      wallet.cryptoCurrency.hasTokenSupport ? "Edit" : "See all",''',
      'Edit / See all',
    );
    _has(s, '''
      if (wallet.cryptoCurrency.hasTokenSupport) { final result = await
      showDialog<int?>( context: context, builder: (context) =>
      EditWalletTokensView( walletId: widget.walletId, isDesktopPopup: true,
      ), );''', 'Ethereum\'s "Edit tokens" dialog');
    _has(s, '''
      wallet.cryptoCurrency.hasTokenSupport ?
      MyTokensView(walletId: widget.walletId) : wallet.isarTransactionVersion
      == 2 ? TransactionsV2List(walletId: widget.walletId) :
      TransactionsList(walletId: widget.walletId),''', 'the right column');
    // BEAM's page (it scrolls as one) is a branch of its own; every other
    // coin keeps Campfire's padded column with MyWallet scrolling itself.
    _has(
      s,
      'body: wallet is BeamWallet ? BeamDesktopWalletPage(',
      'BEAM page behind a BeamWallet guard',
    );
    _has(s, '''
      : Padding( padding: const EdgeInsets.all(24), child: Column( children:
      [ DesktopWalletHeaderRow(wallet, monke), const SizedBox(height: 24),
      _columnTitles(context, wallet), const SizedBox(height: 14), Expanded(
      child: Row( crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox( width: sendReceiveColumnWidth, child: MyWallet(walletId:
      widget.walletId), ),''', 'other coins: the upstream layout');
  });

  test('desktop My wallet tabs: BEAM tabs and BEAM history tab are BEAM '
      'branches; Ethereum keeps its Transactions tab', () {
    final s = _src(_mw);
    _has(s, 'isBeam = wallet is BeamWallet;', 'isBeam is a type check');
    _has(s, '''
      isBeam ? BeamDesktopWalletTabs( walletId: widget.walletId, titles:
      titles, children: children, ) : CustomTabView(titles: titles,
      children: children);''', 'other coins keep CustomTabView');
    _has(s, '''
      if ((isEth || isSolana || isBeam) && widget.contractAddress == null) {
      titles.add("Transactions"); }''', 'the Transactions tab title');
    _has(s, 'isEth = coin is Ethereum;', 'isEth unchanged');
  });

  test('desktop Address list: BEAM opens its own list, others Campfire\'s', () {
    final s = _src(_wob);
    _has(
      s,
      '''
      case _WalletOptions.addressList: // BEAM: its own list (address types,
      expiry, labels). if (ref.read(pWallets).getWallet(walletId) is
      BeamWallet) { unawaited(showBeamAddressListDialog(context, walletId));
      break; } unawaited( Navigator.of(context).pushNamed(
      DesktopWalletAddressesView.routeName, arguments: walletId, ), );''',
      'the generic list stays for other coins',
    );
  });

  test('routes: every BEAM route takes a BeamWallet; MyTokensView\'s route '
      'is unchanged', () {
    final s = _src(_rg);
    for (final name in const [
      'BeamFeatureRoutes.dex',
      'BeamNamesHomeView.routeName',
      'BeamClaimVoucherView.routeName',
      'BeamAirdropBatchesView.routeName',
      'BeamCreateAirdropView.routeName',
      'BeamMintTokenView.routeName',
      'BeamMyTokensView.routeName',
      'BeamBurnView.routeName',
    ]) {
      _has(s, 'case $name: if (args is BeamWallet) {', name);
    }
    _has(s, '''
      case MyTokensView.routeName: if (args is String) { return getRoute(
      shouldUseMaterialRoute: useMaterialPageRoute, builder: (_) =>
      MyTokensView(walletId: args),''', 'MyTokensView (Ethereum) route');
  });
}
