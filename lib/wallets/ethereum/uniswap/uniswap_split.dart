/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How to share one swap between several routes.
//
// The amount is cut into equal steps (twentieths). Each route has been
// priced at every number of steps; giving a route k steps yields its price
// at k steps, less what using the route at all costs in gas. The best
// sharing is found exactly by dynamic programming over the routes (a
// knapsack: 20 steps, at most [maxParts] routes), which is cheap.
//
// Two routes that go through the same pool were priced as if each had the
// pool to itself, so they are never used together: when the best sharing
// uses both, it is worked out again without one, then without the other,
// and the better of the two is kept. Many routes can share one pool (every
// way on from the same first pool), so that search is capped; past the
// cap, the route with the smaller share is dropped until no two share a
// pool. A sharing that uses one pool twice is never returned.

/// One route's prices: [outs][k] is what k steps of the amount give
/// (outs[0] is zero; null where the route would not quote).
class UniSplitCurve {
  const UniSplitCurve({
    required this.pools,
    required this.outs,
    required this.cost,
  });

  /// The ids of the pools the route goes through.
  final Set<String> pools;
  final List<BigInt?> outs;

  /// Using the route at all, in the token received (its gas).
  final BigInt cost;
}

/// Steps per route ([steps][i] for curve i; zero when unused), and what
/// the sharing gives after gas.
class UniSplit {
  const UniSplit(this.steps, this.net);

  final List<int> steps;
  final BigInt net;

  int get parts => steps.where((s) => s > 0).length;
}

/// The best way to give all [steps] steps to [curves], using at most
/// [maxParts] of them and never two that share a pool; null if no sharing
/// is possible.
UniSplit? bestSplit(
  List<UniSplitCurve> curves, {
  required int steps,
  int maxParts = 6,
}) {
  (int, int)? clash(UniSplit split) {
    final used = [
      for (var i = 0; i < curves.length; i++)
        if (split.steps[i] > 0) i,
    ];
    for (var a = 0; a < used.length; a++) {
      for (var b = a + 1; b < used.length; b++) {
        final i = used[a];
        final j = used[b];
        if (curves[i].pools.intersection(curves[j].pools).isNotEmpty) {
          return (i, j);
        }
      }
    }
    return null;
  }

  // Past the cap: drop the smaller of each clashing pair until none clash.
  UniSplit? repair(Set<int> excluded) {
    final out = {...excluded};
    while (true) {
      final split = _knapsack(curves, out, steps, maxParts);
      if (split == null) return null;
      final c = clash(split);
      if (c == null) return split;
      out.add(split.steps[c.$1] < split.steps[c.$2] ? c.$1 : c.$2);
    }
  }

  final memo = <String, UniSplit?>{};
  var evaluations = 0;
  UniSplit? solve(Set<int> excluded) {
    final key = (excluded.toList()..sort()).join(',');
    if (memo.containsKey(key)) return memo[key];
    if (++evaluations > 64) return memo[key] = repair(excluded);
    final split = _knapsack(curves, excluded, steps, maxParts);
    final c = split == null ? null : clash(split);
    if (c == null) return memo[key] = split;
    final withoutI = solve({...excluded, c.$1});
    final withoutJ = solve({...excluded, c.$2});
    final UniSplit? best;
    if (withoutI == null) {
      best = withoutJ;
    } else if (withoutJ == null) {
      best = withoutI;
    } else {
      best = withoutI.net >= withoutJ.net ? withoutI : withoutJ;
    }
    return memo[key] = best;
  }

  return solve({});
}

UniSplit? _knapsack(
  List<UniSplitCurve> curves,
  Set<int> excluded,
  int steps,
  int maxParts,
) {
  // best[k][p]: the most k steps give over the routes so far, using p of
  // them; null when impossible.
  var best = List.generate(
    steps + 1,
    (_) => List<BigInt?>.filled(maxParts + 1, null),
  );
  best[0][0] = BigInt.zero;
  // took[i][k][p]: steps route i took in best[k][p] after route i.
  final took = <List<List<int>>>[];

  for (var i = 0; i < curves.length; i++) {
    final c = curves[i];
    final next = [
      for (final row in best) [...row],
    ];
    final choice = List.generate(
      steps + 1,
      (_) => List<int>.filled(maxParts + 1, 0),
    );
    if (!excluded.contains(i)) {
      for (var k = 1; k <= steps; k++) {
        for (var p = 1; p <= maxParts; p++) {
          for (var j = 1; j <= k && j < c.outs.length; j++) {
            final out = c.outs[j];
            final before = best[k - j][p - 1];
            if (out == null || before == null || out <= BigInt.zero) continue;
            final v = before + out - c.cost;
            final cur = next[k][p];
            if (cur == null || v > cur) {
              next[k][p] = v;
              choice[k][p] = j;
            }
          }
        }
      }
    }
    took.add(choice);
    best = next;
  }

  var bestP = -1;
  BigInt? bestV;
  for (var p = 1; p <= maxParts; p++) {
    final v = best[steps][p];
    if (v != null && (bestV == null || v > bestV)) {
      bestV = v;
      bestP = p;
    }
  }
  if (bestV == null) return null;

  final out = List<int>.filled(curves.length, 0);
  var k = steps;
  var p = bestP;
  for (var i = curves.length - 1; i >= 0; i--) {
    final j = took[i][k][p];
    if (j > 0) {
      out[i] = j;
      k -= j;
      p -= 1;
    }
  }
  return UniSplit(out, bestV);
}
