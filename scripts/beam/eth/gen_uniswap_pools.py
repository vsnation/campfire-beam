#!/usr/bin/env python3
# Regenerates lib/wallets/ethereum/uniswap/uniswap_known_pools.dart: every
# Uniswap v2/v3/v4 pool between the base tokens (ETH, WETH, USDC, USDT, DAI,
# WBTC, WBEAM) and every pool that holds WBEAM, read from the factories' and
# the PoolManager's own events. The app starts from this list and searches
# only the blocks after it, so the first price needs no long event search.
#
#   python3 scripts/beam/eth/gen_uniswap_pools.py [RPC_URL]
#
# The RPC must allow eth_getLogs over the whole history with topic filters
# (MEV Blocker's public RPC did on 2026-10-09). Read-only; no keys, no wallet.
import json, sys, time, urllib.request

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://rpc.mevblocker.io"
OUT = "lib/wallets/ethereum/uniswap/uniswap_known_pools.dart"

NATIVE = "0x0000000000000000000000000000000000000000"
WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
USDT = "0xdac17f958d2ee523a2206206994597c13d831ec7"
DAI = "0x6b175474e89094c44da98b954eedeac495271d0f"
WBTC = "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599"
WBEAM = "0xe5acbb03d73267c03349c76ead672ee4d941f499"
BASE = [NATIVE, WETH, USDC, USDT, DAI, WBTC, WBEAM]

V2F = "0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"
V3F = "0x1f98431c8ad98523631ae4a59f267346ea31f984"
PM = "0x000000000004444c5dc75cb358380d2e3de08a90"
T_V2 = "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9"
T_V3 = "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118"
T_V4 = "0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438"
DEPLOY = {V2F: 10000835, V3F: 12369621, PM: 21688329}

_id = 0
def rpc(method, params):
    global _id
    _id += 1
    for attempt in range(6):
        req = urllib.request.Request(RPC, data=json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode(),
                                     headers={"content-type": "application/json", "user-agent": "Mozilla/5.0"})
        try:
            d = json.load(urllib.request.urlopen(req, timeout=120))
        except Exception as e:
            time.sleep(3 + attempt * 3); continue
        if "error" in d:
            msg = d["error"].get("message", "")
            if "unavailable" in msg or "rate" in msg.lower():
                time.sleep(3 + attempt * 3); continue
            raise RuntimeError(f"{method}: {msg}")
        return d["result"]
    raise RuntimeError(f"{method}: no answer")

def topic(a): return "0x" + a[2:].rjust(64, "0")
def addr(t): return "0x" + t[-40:]

def logs(address, topics, frm, to):
    return rpc("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(frm), "toBlock": hex(to)}])

def word(data, i): return data[2 + 64 * i: 2 + 64 * (i + 1)]
def sint(h, bits=24):
    v = int(h, 16) & ((1 << bits) - 1)
    return v - (1 << bits) if v >= 1 << (bits - 1) else v

def scan(token_a, token_b, to):
    """Pools of the pair (a, b); b None = every pool holding a."""
    found = {}
    def v2(ts):
        for l in logs(V2F, [T_V2] + ts, DEPLOY[V2F], to):
            c0, c1 = addr(l["topics"][1]), addr(l["topics"][2])
            pair = "0x" + word(l["data"], 0)[24:]
            found[pair] = {"v": "v2", "pair": pair, "c0": c0, "c1": c1}
    def v3(ts):
        for l in logs(V3F, [T_V3] + ts, DEPLOY[V3F], to):
            c0, c1, fee = addr(l["topics"][1]), addr(l["topics"][2]), int(l["topics"][3], 16)
            spacing = sint(word(l["data"], 0)); pool = "0x" + word(l["data"], 1)[24:]
            found[pool] = {"v": "v3", "pool": pool, "c0": c0, "c1": c1, "fee": fee, "ts": spacing}
    def v4(ts):
        for l in logs(PM, [T_V4, None] + ts, DEPLOY[PM], to):
            c0, c1 = addr(l["topics"][2]), addr(l["topics"][3])
            fee = int(word(l["data"], 0), 16); spacing = sint(word(l["data"], 1)); hooks = "0x" + word(l["data"], 2)[24:]
            found[l["topics"][1]] = {"v": "v4", "c0": c0, "c1": c1, "fee": fee, "ts": spacing, "hooks": hooks}
    if token_b is None:
        a = topic(token_a)
        if token_a != NATIVE:
            v2([a]); v2([None, a]); v3([a]); v3([None, a])
        v4([a]); v4([None, a])
    else:
        x, y = sorted([token_a, token_b])
        if NATIVE not in (x, y):
            v2([topic(x), topic(y)]); v3([topic(x), topic(y)])
        v4([topic(x), topic(y)])
    return found

def main():
    to = int(rpc("eth_blockNumber", []), 16) - 64  # leave reorgs to the app's own search
    pools = {}
    for i, a in enumerate(BASE):
        for b in BASE[i + 1:]:
            if {a, b} == {NATIVE, WETH}: continue
            got = scan(a, b, to); pools.update(got)
            print(f"{a[:6]}/{b[:6]}: {len(got)}", file=sys.stderr)
    got = scan(WBEAM, None, to); pools.update(got)
    print(f"WBEAM (all): {len(got)}", file=sys.stderr)
    entries = sorted(pools.values(), key=lambda p: (p["v"], p["c0"], p["c1"], p.get("fee", 0), p.get("ts", 0), p.get("hooks", "")))
    lines = []
    for p in entries:
        lines.append("  {" + ", ".join(f"'{k}': " + (f"'{v}'" if isinstance(v, str) else str(v)) for k, v in p.items()) + "},")
    body = "\n".join(lines)
    dart = f"""/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// GENERATED by scripts/beam/eth/gen_uniswap_pools.py — do not edit.
//
// Every Uniswap pool between ETH, WETH, USDC, USDT, DAI, WBTC and WBEAM, and
// every pool holding WBEAM, created up to block {to}, read from Uniswap's own
// events. Campfire starts from this list and searches only later blocks.

/// The last block this list covers.
const int kUniKnownPoolsBlock = {to};

/// Pools as `UniPool.fromJson` reads them.
const List<Map<String, Object>> kUniKnownPools = [
{body}
];
"""
    open(OUT, "w").write(dart)
    print(f"{len(entries)} pools up to block {to} -> {OUT}", file=sys.stderr)

main()
