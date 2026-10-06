#!/usr/bin/env python3
"""Wait for a test wallet to be funded, then split its BEAM into many spendable UTXOs.

    prepare_utxos.py <label> [--min 0.3] [--timeout-h 24]

BEAM locks the coin a send spends until its change matures, so a wallet holding one
UTXO can only run one test at a time. This splits the balance into mostly 0.1 BEAM
coins plus up to four 0.25 (<= 20 coins, <= 90 % of the balance, the rest stays as change)
in one tx_split, with the minimum fee the core computes. The wallet must already be
running under scripts/beam/live/wapi.py. Prints a summary; never prints secrets.
"""
import importlib.util, json, pathlib, sys, time

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wapi", here / "wapi.py")
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
G = 100_000_000


def call(label, method, params=None):
    import subprocess
    out = subprocess.run([sys.executable, "-I", str(here / "wapi.py"), "call", label, method,
                          json.dumps(params or {})], capture_output=True, text=True, timeout=120)
    d = json.loads(out.stdout)
    if "error" in d:
        raise RuntimeError(f"{method}: {d['error']}")
    return d["result"]


def beam_available(label):
    st = call(label, "wallet_status")
    t = next((x for x in st["totals"] if x["asset_id"] == 0), {})
    return int(t.get("available_str", "0")), st


def plan(available):
    """Many coins first (0.1 BEAM, up to 12), then a few larger ones (0.25, up to 4)
    for contract tests, then more 0.1 coins; at most 20 coins and 90 % of the balance."""
    budget = available * 9 // 10
    coins = []
    for size, cap in ((10 * G // 100, 12), (25 * G // 100, 4), (10 * G // 100, 20)):
        while len(coins) < 20 and cap and sum(coins) + size <= budget:
            coins.append(size); cap -= 1
    return coins


def main():
    a = sys.argv[1:]
    label = a[0]
    min_beam = float(a[a.index("--min") + 1]) if "--min" in a else 0.3
    deadline = time.time() + 3600 * (float(a[a.index("--timeout-h") + 1]) if "--timeout-h" in a else 24)
    while True:
        avail, st = beam_available(label)
        if avail >= int(min_beam * G):
            break
        if time.time() > deadline:
            sys.exit(f"timed out waiting for funds (available {avail / G} BEAM)")
        time.sleep(30)
    print(f"funded: available {avail / G} BEAM at height {st['current_height']}", flush=True)
    coins = plan(avail)
    res = call(label, "tx_split", {"coins": coins})
    tx = res["txId"]
    print(f"tx_split {len(coins)} coins ({sum(coins) / G} BEAM), tx {tx[:12]}", flush=True)
    while True:
        s = call(label, "tx_status", {"txId": tx})
        if s["status_string"] in ("completed", "failed", "cancelled"):
            break
        time.sleep(20)
    utxos = call(label, "get_utxo", {"count": 100, "filter": {"asset_id": 0}})
    avail_now = sorted((u["amount"] for u in utxos if u.get("status_string") == "available"), reverse=True)
    print(json.dumps({"split_tx": tx[:12], "status": s["status_string"], "fee": s.get("fee"),
                      "height": s.get("height"), "available_utxos": len(avail_now),
                      "sizes_beam": [x / G for x in avail_now]}), flush=True)


if __name__ == "__main__":
    main()
