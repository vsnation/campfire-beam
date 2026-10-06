/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's add/edit node flow for a BEAM node (research/01 steps 19, 20):
// host and port instead of a URL, no SSL / failover / Tor rows, the port
// pre-filled, "host:port" pasted in one go, and "Test connection" saying
// what it found. The connection test itself is mocked here; its real
// network behaviour is in beam_node_connection_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/manage_nodes_views/add_edit_node_view.dart';
import 'package:stackwallet/providers/global/secure_store_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/utilities/test_beam_node_connection.dart';
import 'package:stackwallet/utilities/test_node_connection.dart';
import 'package:stackwallet/utilities/tor_plain_net_option_enum.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';

import 'node_ui_harness.dart';

const _name = Key('addCustomNodeNodeNameFieldKey');
const _host = Key('addCustomNodeNodeAddressFieldKey');
const _port = Key('addCustomNodeNodePortFieldKey');

class _Tester {
  _Tester(this.result);

  BeamNodeTestResult result;
  final seen = <(String, int)>[];

  Future<BeamNodeTestResult> call({
    required String host,
    required int port,
  }) async {
    seen.add((host, port));
    return result;
  }
}

Future<_Tester> _pumpAddNode(
  WidgetTester tester, {
  BeamNodeTestResult result = BeamNodeTestResult.beamNode,
}) async {
  final fake = _Tester(result);
  await pumpNodeUi(
    tester,
    Builder(
      builder: (context) => Scaffold(
        backgroundColor: Theme.of(context)
            .extension<StackColors>()!
            .background,
        // Centred, as its dialog route shows it on desktop.
        body: Center(
          child: AddEditNodeView(
            viewType: AddEditNodeViewType.add,
            coin: Beam(CryptoCurrencyNetwork.main),
            nodeId: null,
            routeOnSuccessOrDelete: '/',
          ),
        ),
      ),
    ),
    size: desktopWindow,
    pixelRatio: 1,
    overrides: [
      secureStoreProvider.overrideWithValue(FakeSecureStorage()),
      testBeamNodeConnectionProvider.overrideWithValue(fake.call),
    ],
  );
  return fake;
}

String fieldText(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

/// Taps "Test connection" and lets Campfire's toast slide in.
Future<void> testConnection(WidgetTester tester) async {
  await tester.tap(find.text('Test connection'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1100));
  await settle(tester);
}

/// Lets the toast finish and leave, so no timer outlives the test.
Future<void> dismissToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a BEAM node is host and port: port pre-filled, no SSL, '
      'failover or Tor rows, "host:port" pasted fills both', (tester) async {
    await _pumpAddNode(tester);
    expect(find.text('Node address'), findsOneWidget);
    expect(fieldText(tester, _port), '8100');
    expect(find.text('Use SSL'), findsNothing);
    expect(find.text('Use as failover'), findsNothing);
    expect(find.text('Only TOR traffic'), findsNothing);
    expect(
      find.byKey(const Key('addCustomNodeBeamFallbackNote')),
      findsOneWidget,
    );

    await tester.enterText(find.byKey(_name), 'My BEAM node');
    await tester.enterText(
      find.byKey(_host),
      'eu-nodes.mainnet.beam.mw:8100',
    );
    await tester.pump();
    expect(fieldText(tester, _host), 'eu-nodes.mainnet.beam.mw');
    expect(fieldText(tester, _port), '8100');
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/add_node_filled.png'),
    );
  });

  testWidgets('Test connection: a BEAM node answered', (tester) async {
    final fake = await _pumpAddNode(tester);
    await tester.enterText(find.byKey(_name), 'My BEAM node');
    await tester.enterText(
      find.byKey(_host),
      'tcp://us-nodes.mainnet.beam.mw:8100',
    );
    await tester.pump();
    await testConnection(tester);
    expect(fake.seen, [('us-nodes.mainnet.beam.mw', 8100)]);
    expect(
      find.text('BEAM node found at us-nodes.mainnet.beam.mw:8100'),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/add_node_test_found.png'),
    );
    await dismissToast(tester);
  });

  testWidgets('Test connection: something answers, but not a BEAM node',
      (tester) async {
    final fake = await _pumpAddNode(
      tester,
      result: BeamNodeTestResult.notBeamNode,
    );
    await tester.enterText(find.byKey(_host), '127.0.0.1:10000');
    await tester.pump();
    await testConnection(tester);
    expect(fake.seen, [('127.0.0.1', 10000)]);
    expect(
      find.text(
        "Something answers at 127.0.0.1:10000, but it isn't a BEAM node. "
        'BEAM nodes usually use port 8100.',
      ),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/add_node_test_not_beam.png'),
    );
    await dismissToast(tester);
  });

  testWidgets('a host the core cannot use is explained, and nothing is '
      'tested', (tester) async {
    final fake = await _pumpAddNode(tester);
    // Typed one key at a time: no jumping between fields mid-number.
    for (final text in [
      'n',
      'no',
      'node.example',
      'node.example:',
      'node.example:8',
      'node.example:81',
    ]) {
      await tester.enterText(find.byKey(_host), text);
      await tester.pump();
    }
    expect(fieldText(tester, _host), 'node.example:81');
    expect(fieldText(tester, _port), '8100');
    expect(find.text('Put the port number in the Port field'), findsOneWidget);

    await tester.enterText(find.byKey(_host), 'my node;rm');
    await tester.pump();
    expect(
      find.byKey(const Key('addCustomNodeBeamHostProblem')),
      findsOneWidget,
    );
    await tester.tap(find.text('Test connection'));
    await tester.pump();
    expect(fake.seen, isEmpty, reason: 'the button is disabled');
    // Let the field labels finish floating.
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/add_node_invalid_host.png'),
    );
  });

  testWidgets("Campfire's own test path: case Beam() passes for a BEAM node "
      'whatever the Tor flags, fails otherwise', (tester) async {
    final fake = _Tester(BeamNodeTestResult.beamNode);
    late WidgetRef widgetRef;
    late BuildContext ctx;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          testBeamNodeConnectionProvider.overrideWithValue(fake.call),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            widgetRef = ref;
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    NodeFormData form() => NodeFormData()
      ..host = ' eu-nodes.mainnet.beam.mw '
      ..port = 8100
      ..netOption = TorPlainNetworkOption.clear;
    final beam = Beam(CryptoCurrencyNetwork.main);
    expect(
      await testNodeConnection(
        context: ctx,
        nodeFormData: form(),
        cryptoCurrency: beam,
        read: widgetRef.read,
      ),
      isTrue,
    );
    expect(fake.seen.single, ('eu-nodes.mainnet.beam.mw', 8100));
    for (final r in [
      BeamNodeTestResult.notBeamNode,
      BeamNodeTestResult.noReply,
      BeamNodeTestResult.unreachable,
    ]) {
      fake.result = r;
      expect(
        await testNodeConnection(
          context: ctx,
          nodeFormData: form(),
          cryptoCurrency: beam,
          read: widgetRef.read,
        ),
        isFalse,
        reason: '$r',
      );
    }
  });
}
