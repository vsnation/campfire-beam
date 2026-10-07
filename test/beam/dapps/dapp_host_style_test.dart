/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The background dApps are shown on: the Qt wallet's, in the page (the
// server's host stylesheet) and around it (the Flutter surface), from the
// one style map dApps are also given.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_surface.dart';

void main() {
  test('the style is the Qt wallet\'s mainnet palette', () {
    // beam-ui ui/view/color_themes/Mainnet.qml
    expect(dappDefaultStyle['background_main'], '#042548');
    expect(dappDefaultStyle['background_main_top'], '#035b8f');
    expect(dappDefaultStyle['background_popup'], '#00446c');
    expect(dappDefaultStyle['content_main'], '#ffffff');
    expect(dappDefaultStyle['validator_error'], '#ff625c');
    expect(dappDefaultStyle['appsGradientOffset'], -95);
    expect(dappDefaultStyle['appsGradientTop'], 135);
  });

  test('the host stylesheet paints what the Qt wallet paints behind its '
      'transparent dApp view, on html only', () {
    expect(
      dappHostStylesheet(),
      '/* Campfire: the BEAM wallet background behind this dApp. */\n'
      'html {\n'
      '  background-color: #042548;\n'
      '  background-image: linear-gradient(to bottom, '
      '#035b8f -95px, #042548 135px, #042548);\n'
      '  background-repeat: no-repeat;\n'
      '  background-attachment: fixed;\n'
      '}\n',
    );
    // Nothing that could change a page's layout or text.
    final css = dappHostStylesheet();
    expect(css, isNot(contains('body')));
    expect(css, isNot(contains(RegExp(r'(^|[\s;{])color\s*:'))));
    expect(css, isNot(contains('!important')));
  });

  test('only plain colours and ints reach the stylesheet', () {
    for (final bad in [
      'red',
      '#04254',
      '#042548;}body{display:none',
      'url(https://example.com/x.png)',
      '#042548 ',
    ]) {
      expect(
        () => dappHostStylesheet({...dappDefaultStyle, 'background_main': bad}),
        throwsArgumentError,
        reason: bad,
      );
    }
    expect(
      () => dappHostStylesheet({...dappDefaultStyle, 'appsGradientTop': '1'}),
      throwsArgumentError,
    );
    final missing = Map.of(dappDefaultStyle)..remove('background_main_top');
    expect(() => dappHostStylesheet(missing), throwsArgumentError);
    expect(
      dappHostStylesheet({...dappDefaultStyle, 'background_main': '#0A0B0C'}),
      contains('background-color: #0a0b0c;'),
    );
  });

  test('CSS colours become Flutter colours', () {
    expect(dappBackgroundColour(), const Color(0xff042548));
    expect(
      dappCssColour('#035b8f', const Color(0x00000000)),
      const Color(0xff035b8f),
    );
    // CSS puts alpha last.
    expect(
      dappCssColour('#11223380', const Color(0x00000000)),
      const Color(0x80112233),
    );
    for (final bad in [null, 7, 'blue', '#12345', '#1234567']) {
      expect(
        dappCssColour(bad, const Color(0xff000001)),
        const Color(0xff000001),
      );
    }
  });
}
