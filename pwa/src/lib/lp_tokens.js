// Which Confidential Assets are BEAM DEX liquidity (LP) tokens, and of which pool.
// The desktop app's lib/wallets/beam/contracts/dex/beam_lp_tokens.dart, plus a
// snapshot so the names are right from the first frame.
//
// An LP token's own metadata is the contract's text ("Amm Liquidity Token
// 0-174-2", UN=AMML), but anyone can mint an asset with that text. So an asset
// is an LP token here only when the DEX contract says so: a row of its pool list
// (pools_view, learnt at run time by learnPools), or the snapshot below, which is
// that same list as read from the chain. Never from a name.
//
// The mapping is a fact of the chain: an LP token belongs to one pool for its
// whole life (a destroyed and re-created pool mints a new one), so it is kept
// once per page and the snapshot never goes stale; pools created after it are
// learnt from the DEX when a screen reads it (Home, Swap).

/**
 * Every pool of the DEX contract 729fe098…9cbf at mainnet height 4,074,459
 * (2026-10-10): LP token -> [aid1, aid2, kind]. Read from the contract's state,
 * and checked against the asset list: each of these 98 assets is owned by the
 * DEX contract and its metadata names the same pool ("Amm Liquidity Token
 * <aid1>-<aid2>-<kind>"); no other asset is.
 */
export const SNAPSHOT = Object.freeze({
  50: [0, 7, 2], 52: [0, 9, 0], 53: [0, 9, 2], 54: [0, 4, 0], 55: [0, 2, 2], 56: [0, 7, 1], 57: [0, 7, 0],
  58: [0, 37, 2], 59: [0, 3, 2], 60: [0, 47, 2], 61: [17, 47, 2], 62: [4, 9, 0], 63: [0, 36, 0],
  64: [7, 52, 0], 65: [7, 63, 0], 66: [7, 54, 0], 67: [0, 60, 2], 70: [0, 69, 2], 71: [0, 10, 2],
  72: [0, 1, 2], 73: [37, 47, 2], 74: [7, 23, 2], 75: [0, 74, 2], 76: [0, 40, 2], 77: [0, 36, 2],
  78: [2, 7, 2], 79: [9, 24, 2], 80: [47, 69, 2], 81: [0, 6, 2], 82: [7, 37, 2], 83: [7, 47, 2],
  85: [0, 26, 2], 88: [0, 87, 0], 89: [0, 37, 1], 91: [37, 47, 1], 92: [0, 90, 0], 95: [0, 38, 2],
  97: [87, 96, 0], 98: [0, 70, 2], 99: [0, 17, 2], 101: [0, 100, 2], 102: [0, 22, 0], 104: [0, 18, 2],
  105: [0, 39, 2], 106: [39, 47, 2], 107: [0, 18, 0], 109: [0, 108, 2], 110: [36, 38, 1], 112: [0, 111, 2],
  113: [0, 12, 0], 115: [0, 114, 2], 117: [0, 116, 2], 118: [0, 116, 1], 119: [7, 50, 1], 120: [9, 53, 1],
  121: [36, 77, 2], 124: [0, 122, 0], 126: [0, 125, 0], 128: [0, 127, 1], 129: [7, 127, 1], 130: [9, 47, 0],
  132: [0, 131, 2], 133: [0, 2, 0], 134: [0, 5, 2], 136: [0, 135, 0], 139: [0, 138, 2], 140: [0, 26, 1],
  142: [0, 141, 0], 143: [0, 141, 2], 144: [47, 108, 0], 146: [0, 145, 2], 147: [0, 50, 2], 148: [7, 108, 0],
  149: [0, 10, 0], 152: [0, 151, 2], 154: [0, 153, 0], 155: [7, 153, 0], 157: [0, 156, 2], 158: [0, 103, 0],
  160: [0, 159, 1], 162: [0, 161, 0], 164: [0, 163, 0], 166: [0, 165, 0], 168: [0, 167, 2], 170: [0, 169, 0],
  171: [7, 131, 2], 172: [0, 8, 1], 175: [0, 174, 2], 176: [7, 60, 2], 177: [0, 150, 2], 188: [0, 187, 2],
  189: [0, 186, 2], 192: [0, 190, 2], 193: [0, 191, 2], 197: [0, 18, 1], 199: [0, 198, 2], 201: [0, 200, 1],
  203: [0, 202, 1],
});

const byLp = new Map();
let version = 0;

/** Bumped whenever a pool is learnt: names that depend on it are worked out again. */
export const lpVersion = () => version;

const isId = (n) => Number.isSafeInteger(n) && n >= 0 && n <= 0xffffffff;

/**
 * Records one pool ({lpToken, aid1, aid2, kind}). Ignores anything malformed, as
 * the desktop does: the LP token must be a Confidential Asset distinct from the
 * pool's two assets, which must be in the contract's order (aid1 < aid2).
 */
export function learnPool(p) {
  if (!p) return;
  const lpToken = Number(p.lpToken);
  const aid1 = Number(p.aid1);
  const aid2 = Number(p.aid2);
  const kind = Number(p.kind);
  if (![lpToken, aid1, aid2].every(isId) || !Number.isInteger(kind)) return;
  if (lpToken <= 0 || aid1 >= aid2 || lpToken === aid1 || lpToken === aid2) return;
  const old = byLp.get(lpToken);
  if (old && old.aid1 === aid1 && old.aid2 === aid2 && old.kind === kind) return;
  byLp.set(lpToken, Object.freeze({ lpToken, aid1, aid2, kind }));
  version++;
}

/** Records the LP token of every pool of a pools_view (lib/dex.js parsePools). */
export function learnPools(pools) {
  for (const p of pools || []) if (p && p.lpToken != null) learnPool(p);
}

/** The pool `assetId` is the LP token of, or null when it is not one (or not known yet). */
export function lpPoolOf(assetId) {
  return byLp.get(Number(assetId)) || null;
}

/** Back to the snapshot alone (tests). */
export function resetLpTokens() {
  byLp.clear();
  for (const [lp, [aid1, aid2, kind]] of Object.entries(SNAPSHOT)) learnPool({ lpToken: Number(lp), aid1, aid2, kind });
  version++;
}

resetLpTokens();
