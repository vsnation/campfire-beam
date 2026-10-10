// The DEX's pool list, read through the wallet's own node (a read-only call of
// the pinned AMM shader), shared by Swap and Home. Every read also teaches
// lp_tokens.js which assets are liquidity tokens, so a pool created after this
// release is named "BEAM/XYZ LP" like the ones in its snapshot.
import { wallet } from './wallet.js';
import { nativeApp } from './contracts.js';
import { loadShader } from './shaders.js';
import { poolsViewArgs, parsePools } from './dex.js';
import { learnPools, lpPoolOf } from './lp_tokens.js';
import { VERIFIED } from './meta.js';

const POOLS_TTL_MS = 30000;
let poolCache = null; // { at, pools, session }

export async function dexApp() {
  const [app, shader] = await Promise.all([nativeApp(), loadShader('amm')]);
  return { app, shader };
}

/** Every pool (lib/dex.js parsePools), at most 30 s old unless `force`. */
export async function loadPools(force = false) {
  if (!force && poolCache && poolCache.session === wallet.session && Date.now() - poolCache.at < POOLS_TTL_MS) return poolCache.pools;
  const { app, shader } = await dexApp();
  const pools = parsePools(await app.view(poolsViewArgs(), shader));
  learnPools(pools);
  poolCache = { at: Date.now(), pools, session: wallet.session };
  return pools;
}

// Ids already compared with a pool list in this session: no second read for them.
let checked = { session: null, ids: new Set(), tried: 0 };
const RETRY_MS = 5 * 60000;

/**
 * Whether any of `ids` (assets this wallet holds) is neither verified nor a known
 * LP token, and has not been compared with the DEX's pool list in this session:
 * one of them may be the LP token of a pool newer than the snapshot.
 */
export function needsPoolCheck(ids) {
  if (checked.session !== wallet.session) checked = { session: wallet.session, ids: new Set(), tried: 0 };
  if (Date.now() - checked.tried < RETRY_MS) return false;
  return ids.some((id) => id > 0 && !VERIFIED[id] && !lpPoolOf(id) && !checked.ids.has(id));
}

/**
 * Reads the pool list once for `ids` (see needsPoolCheck). True when it named a
 * new LP token among them. Failures are quiet: the asset keeps the name it has,
 * and the check is tried again after a while.
 */
export async function checkPools(ids) {
  checked.tried = Date.now();
  const before = ids.filter((id) => lpPoolOf(id)).length;
  try {
    await loadPools();
  } catch {
    return false;
  }
  for (const id of ids) checked.ids.add(id);
  checked.tried = 0;
  return ids.filter((id) => lpPoolOf(id)).length > before;
}
