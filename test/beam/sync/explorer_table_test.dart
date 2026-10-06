// Explorer TABLE-format parsing against trimmed real responses from
// explorer.0xmx.net (2026-10-06):
//   /contract?id=729fe098...9cbf&state=1&nMaxTxs=5 -> explorer_contract_dex.json
//   /asset?id=174&nMaxOps=5                        -> explorer_asset_174.json

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/explorer/explorer_table.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/beam/sync/fixtures/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  late Map<String, Object?> dex;
  late Map<String, Object?> asset;

  setUpAll(() {
    dex = _fixture('explorer_contract_dex.json');
    asset = _fixture('explorer_asset_174.json');
  });

  group('Calls history (groups, nested tables, cursor)', () {
    late ExplorerTable calls;
    setUp(() => calls = ExplorerTable.parse(dex['Calls history']));

    test('headers come from the th row', () {
      expect(calls.headers, [
        'Height',
        'Cid',
        'Kind',
        'Method',
        'Arguments',
        'Funds',
        'Keys',
      ]);
    });

    test('groups are flattened: lead row at depth 0, sub-calls nested', () {
      expect(calls.rows, hasLength(6));
      expect(calls.leadRows, hasLength(3));
      final g0 = calls.group(0);
      expect(g0, hasLength(2));
      expect(g0[0].depth, 0);
      expect(g0[0].isNested, isFalse);
      expect(g0[1].depth, 1);
      expect(g0[1].isNested, isTrue);
      expect(g0.map((r) => r.groupId), everyElement(0));
      expect(calls.group(2).first.intOf('Height'), 4067912);
    });

    test('lead row: height, method, arguments map with typed cells', () {
      final trade = calls.leadRows.first;
      expect(trade.intOf('Height'), 4067912);
      expect(trade['Method'], 'Trade');
      expect(trade.stringOf('Cid'), isNull, reason: '"" means no value');
      expect(trade.mapOf('Arguments'), {
        'Buy': 47,
        'Sell': 0,
        'Volatility': 'High',
      });
    });

    test('nested Funds table has no header row and signed string amounts', () {
      final funds = calls.leadRows.first.tableOf('Funds')!;
      expect(funds.headers, isEmpty);
      expect(funds.rows, hasLength(2), reason: 'first row is data');
      expect(parseExplorerInt(funds.rows[0].rawAt(0)), 0);
      expect(parseExplorerInt(funds.rows[0].rawAt(1)), 7876534611);
      expect(parseExplorerInt(funds.rows[1].rawAt(0)), 47);
      expect(parseExplorerInt(funds.rows[1].rawAt(1)), -77978275);
    });

    test('sub-call row carries the callee contract', () {
      final sub = calls.group(0)[1];
      expect(sub.intOf('Height'), isNull);
      expect(sub.typeOf('Cid'), 'cid');
      expect(
        sub['Cid'],
        '0066b12078623df132b691001b25d7eb94b207b42c018020c9e58152e21ecd25',
      );
      expect(sub['Kind'], 'DaoVault v0');
      expect(sub['Method'], 'Deposit');
    });

    test('paging cursor', () {
      expect(calls.moreHMax, 4067909);
    });
  });

  group('DEX State.Pools', () {
    late ExplorerTable pools;
    setUp(() {
      final state = dex['State'] as Map<String, Object?>;
      pools = ExplorerTable.parse(state['Pools']);
    });

    test('headers incl. hyphenated LP-Token and rate columns', () {
      expect(pools.headers, containsAll(['Aid1', 'Aid2', 'LP-Token']));
      expect(pools.headers, containsAll(['Rate 1:2', 'Rate 2:1']));
      expect(pools.rows, hasLength(5));
    });

    test('BEAM/FOMO pool row', () {
      final fomo = pools.rows.singleWhere((r) => r.intOf('Aid2') == 174);
      expect(fomo.intOf('Aid1'), 0);
      expect(fomo.typeOf('Aid1'), 'aid');
      expect(fomo.intOf('LP-Token'), 175);
      expect(fomo['Volatility'], 'High');
      expect(fomo.intOf('Amount1'), 637304113367);
      expect(fomo.intOf('Amount2'), 5173233681014);
      expect(fomo.doubleOf('Rate 1:2'), closeTo(8.1173706, 1e-9));
    });

    test('rates in "9.1558504 E-2" notation', () {
      final row = pools.rows.singleWhere(
        (r) => r.intOf('Aid2') == 2 && r['Volatility'] == 'High',
      );
      expect(row.doubleOf('Rate 2:1'), closeTo(0.091558504, 1e-12));
    });

    test('an empty pool has "" rates, read as null', () {
      final empty = pools.rows.first;
      expect(empty.intOf('Amount1'), 0);
      expect(empty.doubleOf('Rate 1:2'), isNull);
      expect(empty.stringOf('Rate 1:2'), isNull);
    });

    test('toMaps unwraps typed cells', () {
      final m = pools.toMaps().last;
      expect(m['Aid2'], 174);
      expect(m['LP-Token'], 175);
    });
  });

  group('other tables', () {
    test('Locked Funds: integer amounts beyond 2^32', () {
      final t = ExplorerTable.parse(dex['Locked Funds']);
      expect(t.headers, ['Asset ID', 'Amount']);
      expect(t.rows.first.intOf('Asset ID'), 0);
      expect(t.rows.first.intOf('Amount'), 210345454525519);
      expect(t.rows.first.bigIntOf('Amount'), BigInt.from(210345454525519));
    });

    test('Owned assets: raw metadata string next to typed cells', () {
      final t = ExplorerTable.parse(dex['Owned assets']);
      expect(t.rows.first.intOf('Asset ID'), 50);
      expect(t.rows.first.stringOf('Metadata'), startsWith('STD:SCH_VER=1;'));
    });

    test('Asset history: signed mint amount and Create extra map', () {
      final t = ExplorerTable.parse(asset['Asset history']);
      expect(t.headers, ['Height', 'Event', 'Amount', 'Total Amount', 'Extra']);
      final mint = t.rows.firstWhere((r) => r['Event'] == 'Mint');
      expect(mint.intOf('Amount'), 400000000000000);
      expect(mint.intOf('Total Amount'), 400000000000000);
      final create = t.rows.firstWhere((r) => r['Event'] == 'Create');
      final extra = create.mapOf('Extra')!;
      expect(extra['deposit'], 1000000000);
      final meta = extra['metadata'] as Map<String, Object?>;
      expect(meta['text'], contains('UN=FOMO'));
      expect(extra['owner'], hasLength(64));
    });

    test('Asset distribution', () {
      final t = ExplorerTable.parse(asset['Asset distribution']);
      expect(t.headers, ['Cid', 'Kind', 'Locked Value']);
      expect(t.rows.first.typeOf('Cid'), 'cid');
      expect(t.rows.first.intOf('Locked Value'), 3);
    });

    test('header-only table (unknown asset) has no rows', () {
      final t = ExplorerTable.parse({
        'type': 'table',
        'value': [
          [
            {'type': 'th', 'value': 'Cid'},
            {'type': 'th', 'value': 'Kind'},
          ],
        ],
      });
      expect(t.headers, ['Cid', 'Kind']);
      expect(t.rows, isEmpty);
      expect(t.moreHMax, isNull);
    });
  });

  group('shape edge cases', () {
    test('a group inside a group keeps one group id and nests deeper', () {
      final t = ExplorerTable.parse({
        'type': 'table',
        'value': [
          [
            {'type': 'th', 'value': 'Height'},
            {'type': 'th', 'value': 'Method'},
          ],
          [100, 'Plain'],
          {
            'type': 'group',
            'value': [
              [101, 'Outer'],
              {
                'type': 'group',
                'value': [
                  ['', 'Inner'],
                  ['', 'InnerChild'],
                ],
              },
            ],
          },
        ],
      });
      expect(t.rows.map((r) => r['Method']), [
        'Plain',
        'Outer',
        'Inner',
        'InnerChild',
      ]);
      expect(t.rows.map((r) => r.groupId), [null, 0, 0, 0]);
      expect(t.rows.map((r) => r.depth), [0, 0, 1, 2]);
    });

    test('short rows read missing columns as null', () {
      final t = ExplorerTable.parse({
        'type': 'table',
        'value': [
          [
            {'type': 'th', 'value': 'A'},
            {'type': 'th', 'value': 'B'},
          ],
          [1],
        ],
      });
      expect(t.rows.single['A'], 1);
      expect(t.rows.single['B'], isNull);
      expect(t.rows.single['C'], isNull);
    });

    test('non-tables are rejected', () {
      expect(() => ExplorerTable.parse(null), throwsFormatException);
      expect(() => ExplorerTable.parse(const [1]), throwsFormatException);
      expect(
        () => ExplorerTable.parse(const {'type': 'group', 'value': <int>[]}),
        throwsFormatException,
      );
      expect(ExplorerTable.tryParse('x'), isNull);
    });
  });

  group('value helpers', () {
    test('parseExplorerInt', () {
      expect(parseExplorerInt(5), 5);
      expect(parseExplorerInt(5.0), 5);
      expect(parseExplorerInt(5.5), isNull);
      expect(parseExplorerInt('+42'), 42);
      expect(parseExplorerInt('-42'), -42);
      expect(parseExplorerInt(' 7 '), 7);
      expect(parseExplorerInt(''), isNull);
      expect(parseExplorerInt('abc'), isNull);
      expect(parseExplorerInt({'type': 'amount', 'value': '+9'}), 9);
      expect(parseExplorerInt('99999999999999999999'), isNull);
    });

    test('parseExplorerBigInt handles values past 64 bits', () {
      expect(
        parseExplorerBigInt('+99999999999999999999'),
        BigInt.parse('99999999999999999999'),
      );
      expect(parseExplorerBigInt(''), isNull);
    });

    test('parseExplorerDecimal', () {
      expect(
        parseExplorerDecimal('9.8922602 E-3'),
        closeTo(0.0098922602, 1e-15),
      );
      expect(parseExplorerDecimal('101.08913'), closeTo(101.08913, 1e-9));
      expect(parseExplorerDecimal(3), 3.0);
      expect(parseExplorerDecimal(''), isNull);
    });

    test('parseExplorerTimestamp takes float seconds', () {
      expect(
        parseExplorerTimestamp(1791271756.0),
        DateTime.utc(2026, 10, 6, 7, 29, 16),
      );
      expect(
        parseExplorerTimestamp('1791271756'),
        DateTime.utc(2026, 10, 6, 7, 29, 16),
      );
      expect(parseExplorerTimestamp(0), isNull);
      expect(parseExplorerTimestamp(''), isNull);
    });

    test('unwrapCell leaves tables and plain maps alone', () {
      const table = {'type': 'table', 'value': <Object?>[]};
      expect(unwrapCell(table), same(table));
      expect(unwrapCell(const {'Buy': 1}), const {'Buy': 1});
      expect(unwrapCell(const {'type': 'aid', 'value': 7}), 7);
    });
  });
}
