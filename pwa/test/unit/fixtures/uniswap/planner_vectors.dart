// One planner, two apps: runs the desktop app's Uniswap planner (and the
// split, pool-id, v2 and Permit2 code next to it) on fixed inputs and writes
// what it produced to planner_vectors.json beside this file. The PWA's
// test/unit/uniswap_planner.test.mjs rebuilds every case with the JS port
// and must produce the same bytes.
//
// Run from the repository root, with the package config of a Flutter
// checkout of this repository (after `flutter pub get`):
//
//   dart run --packages=<checkout>/.dart_tool/package_config.json \
//     pwa/test/unit/fixtures/uniswap/planner_vectors.dart
//
// Only the planner's own files are imported, by path, so the vectors come
// from this checkout's Dart code, whatever the package config points at.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../../../lib/wallets/ethereum/uniswap/abi.dart';
import '../../../../../lib/wallets/ethereum/uniswap/permit2.dart';
import '../../../../../lib/wallets/ethereum/uniswap/uniswap_constants.dart';
import '../../../../../lib/wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../../../lib/wallets/ethereum/uniswap/uniswap_planner.dart';
import '../../../../../lib/wallets/ethereum/uniswap/uniswap_quoter.dart';
import '../../../../../lib/wallets/ethereum/uniswap/uniswap_split.dart';

const _wbeam = '0xe5acbb03d73267c03349c76ead672ee4d941f499';
const _usdc = '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48';
const _usdt = '0xdac17f958d2ee523a2206206994597c13d831ec7';
const _kas = '0x112b08621e27e10773ec95d250604a041f36c582';
const _native = UniswapAddresses.nativeEth;
const _weth = UniswapAddresses.weth;

const wbeam = UniToken(address: _wbeam, symbol: 'WBEAM', decimals: 8);
const usdc = UniToken(address: _usdc, symbol: 'USDC', decimals: 6);
const usdt = UniToken(address: _usdt, symbol: 'USDT', decimals: 6);
const kas = UniToken(address: _kas, symbol: 'KAS', decimals: 8);
const wethToken = UniToken(address: _weth, symbol: 'WETH', decimals: 18);

final v4EthWbeam = UniV4Pool.key(
  currency0: _native,
  currency1: _wbeam,
  fee: 10000,
  tickSpacing: 200,
  hooks: _native,
);
const v2WethWbeam = UniV2Pool(
  pair: '0xc821395f890913b9ce7415b36db10ddc5281c53a',
  currency0: _weth,
  currency1: _wbeam,
);
const v3UsdcWbeam = UniV3Pool(
  pool: '0xe312b8dd9c7a29ece6ca4ab1493271cd4323c4c2',
  currency0: _usdc,
  currency1: _wbeam,
  fee: 10000,
  tickSpacing: 200,
);
const v3UsdtWbeam = UniV3Pool(
  pool: '0xe9614c2b70f3e5b62ebb4c76571e05cd41a65381',
  currency0: _usdt,
  currency1: _wbeam,
  fee: 10000,
  tickSpacing: 200,
);
const v3UsdcWeth = UniV3Pool(
  pool: '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
  currency0: _usdc,
  currency1: _weth,
  fee: 500,
  tickSpacing: 10,
);
final v4KasWbeam = UniV4Pool.key(
  currency0: _kas,
  currency1: _wbeam,
  fee: 10000,
  tickSpacing: 200,
  hooks: _native,
);
final v4UsdcWbeam = UniV4Pool.key(
  currency0: _usdc,
  currency1: _wbeam,
  fee: 3000,
  tickSpacing: 60,
  hooks: _native,
);

/// A dynamic-fee pool with a hook: the key carries both.
final v4EthUsdcHooked = UniV4Pool.key(
  currency0: _native,
  currency1: _usdc,
  fee: kV4DynamicFeeFlag,
  tickSpacing: 60,
  hooks: '0x0e6690b6bbcc55a8b7c7da2f0ee43e2e2bf840c0',
);

BigInt b(num v) => BigInt.from(v);
BigInt big(String s) => BigInt.parse(s);
final eth = BigInt.from(10).pow(18);
final deadline = BigInt.from(1791557000);

UniPart part(List<UniHop> hops, BigInt amountIn, List<BigInt> outs) => UniPart(
  route: UniRoute(hops),
  amountIn: amountIn,
  amountOut: outs.last,
  hopOutputs: outs,
  gas: b(100000 * hops.length),
);

UniQuote quote(UniToken a, UniToken z, List<UniPart> parts, {BigInt? total}) =>
    UniQuote(
      tokenIn: a,
      tokenOut: z,
      amountIn: total ?? parts.fold(BigInt.zero, (s, p) => s + p.amountIn),
      parts: parts,
      gasEstimate: parts.fold(kRouterOverheadGas, (s, p) => s + p.gas),
      block: 1,
    );

SignedPermit permitFor(UniQuote q, {int nonce = 0}) => SignedPermit(
  PermitSingle(
    token: q.tokenIn.address,
    amount: q.amountIn,
    expiration: 1791557900,
    nonce: nonce,
    spender: UniswapAddresses.universalRouter,
    sigDeadline: BigInt.from(1791557900),
  ),
  Uint8List.fromList([...List.filled(32, 0x11), ...List.filled(32, 0x22), 27]),
);

Map<String, Object?> tokenJson(UniToken t) => {
  'address': t.address,
  'symbol': t.symbol,
  'decimals': t.decimals,
};

Map<String, Object?> quoteJson(UniQuote q) => {
  'tokenIn': tokenJson(q.tokenIn),
  'tokenOut': tokenJson(q.tokenOut),
  'amountIn': '${q.amountIn}',
  'gasEstimate': '${q.gasEstimate}',
  'parts': [
    for (final p in q.parts)
      {
        'hops': [
          for (final h in p.route.hops)
            {'pool': h.pool.toJson(), 'in': h.currencyIn, 'out': h.currencyOut},
        ],
        'amountIn': '${p.amountIn}',
        'amountOut': '${p.amountOut}',
        'hopOutputs': [for (final o in p.hopOutputs) '$o'],
        'gas': '${p.gas}',
      },
  ],
};

Map<String, Object?> permitJson(SignedPermit s) => {
  'token': s.permit.token,
  'amount': '${s.permit.amount}',
  'expiration': s.permit.expiration,
  'nonce': s.permit.nonce,
  'spender': s.permit.spender,
  'sigDeadline': '${s.permit.sigDeadline}',
  'signature': bytesToHex(s.signature),
};

Map<String, Object?> planCase(
  String name,
  UniQuote q, {
  required int slippageBips,
  SignedPermit? permit,
}) {
  Map<String, Object?> expect;
  try {
    final plan = const UniswapPlanner().build(
      quote: q,
      slippageBips: slippageBips,
      deadline: deadline,
      permit: permit,
    );
    expect = {
      'commands': bytesToHex(plan.commands),
      'value': '${plan.value}',
      'minimumOut': '${plan.minimumOut}',
      'to': plan.to,
      'calldata': bytesToHex(plan.calldata),
    };
  } on StateError catch (e) {
    expect = {'error': e.message};
  }
  return {
    'name': name,
    'quote': quoteJson(q),
    'slippageBips': slippageBips,
    'deadline': '$deadline',
    'permit': permit == null ? null : permitJson(permit),
    'expect': expect,
  };
}

List<BigInt?> curve(int steps, BigInt stepIn, BigInt rIn, BigInt rOut) => [
  BigInt.zero,
  for (var k = 1; k <= steps; k++)
    v2AmountOut(stepIn * BigInt.from(k), rIn, rOut),
];

void main() {
  final cases = <Map<String, Object?>>[];

  // ETH → WBEAM on the v4 pool alone.
  cases.add(
    planCase(
      'eth_wbeam_v4_single',
      quote(UniToken.eth, wbeam, [
        part([UniHop(v4EthWbeam, _native, _wbeam)], eth ~/ b(100), [b(3214e8)]),
      ]),
      slippageBips: 100,
    ),
  );

  // The desktop test's shared purchase: wrap only the v2 share.
  cases.add(
    planCase(
      'eth_wbeam_v4_v2_split',
      quote(UniToken.eth, wbeam, [
        part(
          [UniHop(v4EthWbeam, _native, _wbeam)],
          eth * b(7) ~/ b(10),
          [b(220000e8)],
        ),
        part(
          [UniHop(v2WethWbeam, _weth, _wbeam)],
          eth * b(3) ~/ b(10),
          [b(93000e8)],
        ),
      ]),
      slippageBips: 50,
    ),
  );

  // Three shares: v4 (ETH), v2 (WETH), and WETH → (v3) USDC → (v4) WBEAM.
  cases.add(
    planCase(
      'eth_wbeam_three_way',
      quote(UniToken.eth, wbeam, [
        part(
          [UniHop(v4EthWbeam, _native, _wbeam)],
          eth * b(5) ~/ b(10),
          [b(160000e8)],
        ),
        part(
          [UniHop(v2WethWbeam, _weth, _wbeam)],
          eth * b(3) ~/ b(10),
          [b(94000e8)],
        ),
        part(
          [
            UniHop(v3UsdcWeth, _weth, _usdc),
            UniHop(v4UsdcWbeam, _usdc, _wbeam),
          ],
          eth * b(2) ~/ b(10),
          [b(780e6), b(61000e8)],
        ),
      ]),
      slippageBips: 300,
    ),
  );

  // The desktop test's sale: one permit, the WETH share unwrapped at the end.
  final sellSplit = quote(wbeam, UniToken.eth, [
    part([UniHop(v4EthWbeam, _wbeam, _native)], b(180000e8), [b(55e16)]),
    part([UniHop(v2WethWbeam, _wbeam, _weth)], b(120000e8), [b(36e16)]),
  ]);
  cases.add(
    planCase(
      'wbeam_eth_split_permit',
      sellSplit,
      slippageBips: 100,
      permit: permitFor(sellSplit),
    ),
  );

  final sellV2 = quote(wbeam, UniToken.eth, [
    part([UniHop(v2WethWbeam, _wbeam, _weth)], b(5000e8), [b(15e15)]),
  ]);
  cases.add(
    planCase(
      'wbeam_eth_v2_permit',
      sellV2,
      slippageBips: 500,
      permit: permitFor(sellV2, nonce: 3),
    ),
  );

  // USDC → (v3) WETH → unwrap → (v4) ETH → WBEAM.
  final usdcIn = quote(usdc, wbeam, [
    part(
      [
        UniHop(v3UsdcWeth, _usdc, _weth),
        UniHop(v4EthWbeam, _native, _wbeam),
      ],
      b(250e6),
      [b(6e16), b(19000e8)],
    ),
  ]);
  cases.add(
    planCase(
      'usdc_wbeam_v3_unwrap_v4',
      usdcIn,
      slippageBips: 100,
      permit: permitFor(usdcIn),
    ),
  );

  // WBEAM → (v4) ETH → wrap → (v3) USDC.
  final toUsdc = quote(wbeam, usdc, [
    part(
      [
        UniHop(v4EthWbeam, _wbeam, _native),
        UniHop(v3UsdcWeth, _weth, _usdc),
      ],
      b(30000e8),
      [b(9e16), b(370e6)],
    ),
  ]);
  cases.add(
    planCase(
      'wbeam_usdc_v4_wrap_v3',
      toUsdc,
      slippageBips: 100,
      permit: permitFor(toUsdc),
    ),
  );

  // ETH → (v4) WBEAM → (v4) KAS: two pools in one v4 command.
  cases.add(
    planCase(
      'eth_kas_two_v4',
      quote(UniToken.eth, kas, [
        part(
          [
            UniHop(v4EthWbeam, _native, _wbeam),
            UniHop(v4KasWbeam, _wbeam, _kas),
          ],
          eth ~/ b(1000),
          [b(320e8), b(41e8)],
        ),
      ]),
      slippageBips: 100,
    ),
  );

  // WETH the token → unwrap → (v4) WBEAM.
  final wethIn = quote(wethToken, wbeam, [
    part([UniHop(v4EthWbeam, _native, _wbeam)], eth ~/ b(100), [b(3200e8)]),
  ]);
  cases.add(
    planCase(
      'weth_wbeam_unwrap_v4',
      wethIn,
      slippageBips: 50,
      permit: permitFor(wethIn),
    ),
  );

  // WBEAM → (v4) ETH, WETH wanted: wrapped and swept at the end.
  final toWeth = quote(wbeam, wethToken, [
    part([UniHop(v4EthWbeam, _wbeam, _native)], b(3000e8), [b(9e15)]),
  ]);
  cases.add(
    planCase(
      'wbeam_weth_v4_wrap_sweep',
      toWeth,
      slippageBips: 100,
      permit: permitFor(toWeth),
    ),
  );

  // USDT → (v3) WBEAM, Permit2 already allowing it: no permit command.
  cases.add(
    planCase(
      'usdt_wbeam_v3_no_permit',
      quote(usdt, wbeam, [
        part([UniHop(v3UsdtWbeam, _usdt, _wbeam)], b(100e6), [b(29000e8)]),
      ]),
      slippageBips: 300,
    ),
  );

  // KAS → (v4) WBEAM → (v2) WETH → unwrapped for ETH.
  final kasOut = quote(kas, UniToken.eth, [
    part(
      [
        UniHop(v4KasWbeam, _kas, _wbeam),
        UniHop(v2WethWbeam, _wbeam, _weth),
      ],
      b(50e8),
      [b(390e8), b(118e13)],
    ),
  ]);
  cases.add(
    planCase(
      'kas_eth_v4_v2_unwrap',
      kasOut,
      slippageBips: 100,
      permit: permitFor(kasOut),
    ),
  );

  // A hooked dynamic-fee v4 pool beside a v3 pool: the key carries both.
  cases.add(
    planCase(
      'eth_usdc_hooked_and_v3',
      quote(UniToken.eth, usdc, [
        part(
          [UniHop(v4EthUsdcHooked, _native, _usdc)],
          eth * b(6) ~/ b(10),
          [b(2400e6)],
        ),
        part(
          [UniHop(v3UsdcWeth, _weth, _usdc)],
          eth * b(4) ~/ b(10),
          [b(1599e6)],
        ),
      ]),
      slippageBips: 50,
    ),
  );

  // Three ways to ETH; two end in WETH and are unwrapped once, minimums added.
  final mixed = quote(wbeam, UniToken.eth, [
    part([UniHop(v4EthWbeam, _wbeam, _native)], b(150000e8), [b(46e16)]),
    part([UniHop(v2WethWbeam, _wbeam, _weth)], b(90000e8), [b(27e16)]),
    part(
      [
        UniHop(v3UsdcWbeam, _wbeam, _usdc),
        UniHop(v3UsdcWeth, _usdc, _weth),
      ],
      b(60000e8),
      [b(700e6), b(18e16)],
    ),
  ]);
  cases.add(
    planCase(
      'wbeam_eth_three_forms',
      mixed,
      slippageBips: 100,
      permit: permitFor(mixed, nonce: 7),
    ),
  );

  // Refused: the shares do not add up to the amount.
  cases.add(
    planCase(
      'shares_short',
      quote(UniToken.eth, wbeam, [
        part([UniHop(v4EthWbeam, _native, _wbeam)], eth ~/ b(2), [b(1)]),
      ], total: eth),
      slippageBips: 50,
    ),
  );

  // Refused: the route ends in a token that was not asked for.
  cases.add(
    planCase(
      'route_ends_elsewhere',
      quote(UniToken.eth, wbeam, [
        part([UniHop(v4EthUsdcHooked, _native, _usdc)], eth, [b(4000e6)]),
      ]),
      slippageBips: 50,
    ),
  );

  // ------------------------------------------------------------ split
  // Each curve is a constant-product pool's output at every step (the JS
  // test rebuilds it with its own v2AmountOut, checked below).
  final splits = <Map<String, Object?>>[];
  final rnd = math.Random(11);
  const names = ['p', 'q', 'r', 's', 't'];
  for (var round = 0; round < 40; round++) {
    final steps = round < 20 ? 8 : 20;
    final n = 2 + rnd.nextInt(5);
    final specs = [
      for (var i = 0; i < n; i++)
        (
          pools: {
            names[rnd.nextInt(5)],
            if (rnd.nextBool()) names[rnd.nextInt(5)],
          },
          rIn: b((1 + rnd.nextInt(40)) * 1e17),
          rOut: b((1 + rnd.nextInt(40)) * 1e10),
          cost: b(rnd.nextInt(3) * 1e7),
        ),
    ];
    final stepIn = b(1e17);
    final curves = [
      for (final s in specs)
        UniSplitCurve(
          pools: s.pools,
          outs: curve(steps, stepIn, s.rIn, s.rOut),
          cost: s.cost,
        ),
    ];
    final maxParts = 1 + rnd.nextInt(6);
    final got = bestSplit(curves, steps: steps, maxParts: maxParts);
    splits.add({
      'steps': steps,
      'maxParts': maxParts,
      'stepIn': '$stepIn',
      'curves': [
        for (final s in specs)
          {
            'pools': s.pools.toList(),
            'rIn': '${s.rIn}',
            'rOut': '${s.rOut}',
            'cost': '${s.cost}',
          },
      ],
      'expect': got == null ? null : {'steps': got.steps, 'net': '${got.net}'},
    });
  }

  // ------------------------------------------------------------ odds and ends
  final pools = [
    v4EthWbeam,
    v4KasWbeam,
    v4UsdcWbeam,
    v4EthUsdcHooked,
    v2WethWbeam,
    v3UsdcWeth,
  ];
  final v2 = [
    for (final (a, r0, r1) in [
      ('10000000000000000', '403461114461472693', '13022386628314'),
      ('1', '1000', '1000'),
      ('123456789012345678901', '999999999999999999999999', '77777777777'),
      ('0', '1', '1'),
    ])
      {
        'amountIn': a,
        'reserveIn': r0,
        'reserveOut': r1,
        'out': '${v2AmountOut(big(a), big(r0), big(r1))}',
      },
  ];
  final permits = [
    for (final p in [permitFor(sellSplit), permitFor(mixed, nonce: 7)])
      {...permitJson(p), 'digest': bytesToHex(p.permit.digest())},
  ];

  final out = {
    'note':
        'Written by planner_vectors.dart from the desktop app\'s Uniswap code; do not edit.',
    'deadline': '$deadline',
    'plans': cases,
    'splits': splits,
    'poolIds': [
      for (final p in pools) {'pool': p.toJson(), 'id': p.id},
    ],
    'v2AmountOut': v2,
    'permits': permits,
    'v3Path': bytesToHex(v3Path([_wbeam, _weth, _usdc], [3000, 500])),
  };
  // One entry per line: readable diffs without a megabyte of indentation.
  final sb = StringBuffer('{\n');
  final keys = out.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    final v = out[keys[i]];
    sb.write(' ${jsonEncode(keys[i])}: ');
    if (v is List) {
      sb.write('[\n');
      for (var j = 0; j < v.length; j++) {
        sb.write('  ${jsonEncode(v[j])}${j < v.length - 1 ? ',' : ''}\n');
      }
      sb.write(' ]');
    } else {
      sb.write(jsonEncode(v));
    }
    sb.write(i < keys.length - 1 ? ',\n' : '\n');
  }
  sb.write('}\n');
  final file = File.fromUri(Platform.script.resolve('planner_vectors.json'));
  file.writeAsStringSync(sb.toString());
  stdout.writeln('wrote ${file.path}: ${cases.length} plans, ${splits.length} splits');
}
