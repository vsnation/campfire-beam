#!/usr/bin/env python3
"""Turn real wallet-api responses into fixtures that are safe for a public repo.

    python3 -I scripts/beam/live/sanitize_fixtures.py            # write + verify
    python3 -I scripts/beam/live/sanitize_fixtures.py --verify   # verify only

Raw responses (default ~/beam-campfire-test/raw_fixtures/*.json) hold real
addresses, identities, tx ids, kernels, amounts and comments. They never enter
the repo. This script writes test/beam/fixtures/*.json with:

  * every address, identity, wallet id, tx id, kernel, state hash, owner id,
    contract id, coin id and commit hash replaced by synthetic text of the same
    length and alphabet (hex stays hex, base58 stays base58). One real value
    maps to one synthetic value across all files, so cross-references survive
    (a tx sender that is one of our addresses is still one of our addresses);
  * every other run of 20+ hex digits (inside URLs in asset metadata, say)
    replaced the same way;
  * comments replaced by neutral text;
  * amounts multiplied by a fixed factor in (0.4, 0.9) that is not in this file,
    with `X` and `X_str` kept consistent, `X` dropped above 2^53-1 the way
    wallet-api does it, and `available == available_regular + available_mp`
    kept true. Fees are left alone: they are protocol constants, not holdings;
  * heights and timestamps shifted by fixed offsets so a fixture tx cannot be
    matched to its block on an explorer. Differences (confirmations) survive.

Determinism: the factor, offsets and every synthetic value come from a seeded
RNG. The seed lives OUTSIDE the repo (~/.config/campfire-beam/fixture_sanitize
.seed, created 0600 on first run), so the published script cannot be used to
undo the scaling, and re-running gives byte-identical output.

The --verify step (always run after writing) fails if any 20+ char hex run, any
address/id value, any comment, any amount, height or timestamp from the raw
files appears in the output.
"""
import argparse, json, os, random, re, secrets, sys
from fractions import Fraction
from pathlib import Path

HOME = Path.home()
REPO = Path(__file__).resolve().parents[3]
DEFAULT_RAW = HOME / "beam-campfire-test/raw_fixtures"
DEFAULT_OUT = REPO / "test/beam/fixtures"
DEFAULT_SEED = HOME / ".config/campfire-beam/fixture_sanitize.seed"

MAX_JSON_INT = 2**53 - 1
HEX_RUN = re.compile(r"[0-9a-fA-F]{20,}")
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# Values that identify the wallet, its peers or its transactions.
ID_KEYS = {
    "address", "sender", "receiver", "wallet_id", "identity",
    "sender_identity", "receiver_identity", "txId", "txid", "kernel",
    "createTxId", "spentTxId", "ownerId", "contract_id", "beam_commit_hash",
    "current_state_hash", "prev_state_hash", "tip_state_hash",
    "tip_prev_state_hash", "payment_proof",
}
# Coin ids are under "id", which is also the JSON-RPC envelope id; handled by
# context (only inside get_utxo results).
COMMENT_KEYS = {"comment", "confirm_comment"}
AMOUNT_BASES = {
    "available", "available_regular", "available_mp",
    "receiving", "receiving_regular", "receiving_mp",
    "sending", "sending_regular", "sending_mp",
    "maturing", "maturing_regular", "maturing_mp",
    "change", "locked", "asset_change", "value", "amount", "emission",
}
HEIGHT_KEYS = {
    "current_height", "height", "lockHeight", "refreshHeight", "maturity",
    "tip_height",
}
TIME_KEYS = {"create_time", "current_state_timestamp", "tip_state_timestamp"}

ADDR_KEEP = 20
TX_KEEP = 25
ASSET_KEEP = 24


def load_seed(path):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(secrets.token_hex(32) + "\n")
    return path.read_text().strip()


class Sanitizer:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        # Factor in (0.4, 0.9) with a large prime denominator so scaled values
        # never come out round.
        den = 1_000_003
        self.factor = Fraction(self.rng.randrange(400_001, 900_000, 2), den)
        self.height_shift = self.rng.randrange(150_000, 450_000)
        self.time_shift = self.rng.randrange(20_000_000, 60_000_000)
        self.map = {}
        self.comments = 0

    # -- synthetic values ----------------------------------------------------
    def _fresh(self, original):
        if re.fullmatch(r"[0-9a-f]+", original):
            alphabet = "0123456789abcdef"
        elif re.fullmatch(r"[0-9A-F]+", original):
            alphabet = "0123456789ABCDEF"
        elif re.fullmatch(r"[0-9a-fA-F]+", original):
            alphabet = "0123456789abcdef"
        elif all(c in B58 for c in original):
            alphabet = B58
        else:
            alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
        while True:
            out = "".join(self.rng.choice(alphabet) for _ in original)
            # Keep a leading non-zero nibble where the original had one, so
            # stripped-leading-zero hex lengths stay plausible.
            if original[:1] not in ("0", "") and out[0] == "0":
                continue
            if out != original and out not in self.map.values():
                return out

    def ident(self, value):
        if not isinstance(value, str) or value == "":
            return value
        if value not in self.map:
            self.map[value] = self._fresh(value)
        return self.map[value]

    def hex_runs(self, text):
        return HEX_RUN.sub(lambda m: self.ident(m.group(0)), text)

    def comment(self, value):
        if not value:
            return value
        self.comments += 1
        return f"Sample note {self.comments}"

    # -- numbers -------------------------------------------------------------
    def scale(self, n):
        sign = -1 if n < 0 else 1
        return sign * int(abs(n) * self.factor)

    def height(self, h):
        # MaxHeight (2^64-1) and other sentinels are not real heights.
        if isinstance(h, int) and 0 < h < 2**62:
            return max(1, h - self.height_shift)
        return h

    def time(self, t):
        if isinstance(t, int) and t > 0:
            return t - self.time_shift
        return t

    # -- tree walk -----------------------------------------------------------
    def amounts(self, obj):
        """Scale every amount field of one object, keeping X/X_str coherent."""
        for base in AMOUNT_BASES:
            s_key = base + "_str"
            if s_key in obj and isinstance(obj[s_key], str):
                scaled = self.scale(int(obj[s_key]))
                obj[s_key] = str(scaled)
                # wallet-api emits the plain number only up to 2^53-1.
                if scaled <= MAX_JSON_INT:
                    obj[base] = scaled
                else:
                    obj.pop(base, None)
            elif base in obj and isinstance(obj[base], int) \
                    and not isinstance(obj[base], bool):
                obj[base] = self.scale(obj[base])
        # A total is the sum of its regular and shielded parts.
        for base in ("available", "receiving", "sending", "maturing"):
            r, m = obj.get(base + "_regular_str"), obj.get(base + "_mp_str")
            if r is not None and m is not None:
                total = int(r) + int(m)
                obj[base + "_str"] = str(total)
                if total <= MAX_JSON_INT:
                    obj[base] = total
                else:
                    obj.pop(base, None)

    def walk(self, node, in_utxo=False):
        if isinstance(node, list):
            return [self.walk(x, in_utxo) for x in node]
        if not isinstance(node, dict):
            return self.hex_runs(node) if isinstance(node, str) else node
        out = {}
        for k, v in node.items():
            if k in ID_KEYS or (in_utxo and k == "id"):
                out[k] = self.ident(v)
            elif k in COMMENT_KEYS:
                out[k] = self.comment(v)
            elif k.endswith("_str") and k[:-4] in AMOUNT_BASES:
                # A 20+ digit amount is also a "hex run"; amounts() scales it.
                out[k] = v
            elif k in HEIGHT_KEYS:
                out[k] = self.height(v)
            elif k in TIME_KEYS:
                out[k] = self.time(v)
            elif k in ("own_id", "own_id_str"):
                # <wallet creation time in µs> + counter: shift the time part.
                n = int(v) - self.time_shift * 1_000_000
                out[k] = n if k == "own_id" else str(n)
            else:
                out[k] = self.walk(v, in_utxo)
        self.amounts(out)
        return out


# -- choosing a representative subset ----------------------------------------
def pick(items, key, keep):
    """Every distinct key first (in original order), then fill to `keep`."""
    seen, chosen = set(), []
    for i, it in enumerate(items):
        k = key(it)
        if k not in seen:
            seen.add(k)
            chosen.append(i)
    for i in range(len(items)):
        if len(chosen) >= keep:
            break
        if i not in chosen:
            chosen.append(i)
    return [items[i] for i in sorted(chosen)]


def tx_key(t):
    amounts = [a for d in t.get("invoke_data", []) for a in d["amounts"]]
    return (t["status"], t["tx_type"], t.get("income"), t.get("fee_only"),
            bool(amounts), "failure_reason" in t, "kernel" in t,
            "sender_identity" in t)


def addr_key(a):
    return (a["type"], a["expired"], a["duration"], bool(a["comment"]))


def subset_assets(assets, needed_ids):
    def key(a):
        pairs = a.get("metadata_pairs", {})
        return (pairs.get("NTH_RATIO"), a["metadata_std"], a["metadata_v60"],
                "emission" in a, "OPT_COLOR" in pairs, "OPT_LOGO_URL" in pairs)
    chosen = pick(assets, key, 0)
    have = {a["asset_id"] for a in chosen}
    for a in assets:
        if a["asset_id"] in needed_ids and a["asset_id"] not in have:
            chosen.append(a)
            have.add(a["asset_id"])
    for a in assets:
        if len(chosen) >= ASSET_KEEP:
            break
        if a["asset_id"] not in have:
            chosen.append(a)
            have.add(a["asset_id"])
    return sorted(chosen, key=lambda a: a["asset_id"])


# -- main --------------------------------------------------------------------
def sanitize(raw_dir, out_dir, seed):
    s = Sanitizer(seed)
    raw = {p.stem: json.loads(p.read_text()) for p in sorted(raw_dir.glob("*.json"))}
    needed = set()
    if "wallet_status" in raw:
        needed |= {t["asset_id"] for t in raw["wallet_status"]["result"].get("totals", [])}
    if "get_utxo" in raw:
        needed |= {u["asset_id"] for u in raw["get_utxo"]["result"]}
    if "tx_list" in raw:
        raw["tx_list"]["result"] = pick(raw["tx_list"]["result"], tx_key, TX_KEEP)
        for t in raw["tx_list"]["result"]:
            needed |= {a["asset_id"] for d in t.get("invoke_data", []) for a in d["amounts"]}
    if "addr_list" in raw:
        raw["addr_list"]["result"] = pick(raw["addr_list"]["result"], addr_key, ADDR_KEEP)
    if "assets_list" in raw:
        res = raw["assets_list"]["result"]
        res["assets"] = subset_assets(res["assets"], needed)

    out_dir.mkdir(parents=True, exist_ok=True)
    for name, doc in raw.items():
        clean = dict(doc)
        clean["result"] = s.walk(doc["result"], in_utxo=(name == "get_utxo"))
        text = json.dumps(clean, indent=2, ensure_ascii=False) + "\n"
        (out_dir / f"{name}.json").write_text(text)
        print(f"wrote {name}.json ({len(text)} bytes)")


def _values(node, keys, acc, in_utxo=False):
    if isinstance(node, list):
        for x in node:
            _values(x, keys, acc, in_utxo)
    elif isinstance(node, dict):
        for k, v in node.items():
            if (k in keys or (in_utxo and k == "id")) and not isinstance(v, (dict, list)):
                acc.add((k, v))
            _values(v, keys, acc, in_utxo)


def verify(raw_dir, out_dir):
    raw_text = {p.stem: p.read_text() for p in raw_dir.glob("*.json")}
    out_text = "\n".join(p.read_text() for p in sorted(out_dir.glob("*.json")))
    problems = []

    hex_tokens = set()
    for t in raw_text.values():
        hex_tokens.update(HEX_RUN.findall(t))
    leaked_hex = sorted(h for h in hex_tokens if h in out_text)
    if leaked_hex:
        problems.append(f"{len(leaked_hex)} raw hex runs survive")

    amount_keys = AMOUNT_BASES | {b + "_str" for b in AMOUNT_BASES}
    raw_ids, raw_comments, raw_amounts, raw_heights = set(), set(), set(), set()
    out_amounts, out_heights = set(), set()
    for name, t in raw_text.items():
        doc = json.loads(t)["result"]
        _values(doc, ID_KEYS | {"own_id_str"}, raw_ids, name == "get_utxo")
        _values(doc, COMMENT_KEYS, raw_comments)
        _values(doc, amount_keys, raw_amounts)
        _values(doc, HEIGHT_KEYS | TIME_KEYS, raw_heights)
    for p in out_dir.glob("*.json"):
        doc = json.loads(p.read_text())["result"]
        _values(doc, amount_keys, out_amounts)
        _values(doc, HEIGHT_KEYS | TIME_KEYS, out_heights)
    out_values = set(re.findall(r'"((?:[^"\\]|\\.)*)"', out_text))

    leaked_ids = [v for _, v in raw_ids if isinstance(v, str) and v and v in out_text]
    if leaked_ids:
        problems.append(f"{len(leaked_ids)} raw address/id values survive")
    leaked_comments = [v for _, v in raw_comments if v and v in out_values]
    if leaked_comments:
        problems.append(f"{len(leaked_comments)} raw comments survive")

    def nums(pairs, floor):
        return {int(v) for _, v in pairs
                if not isinstance(v, bool) and str(v).lstrip("-").isdigit()
                and abs(int(v)) >= floor}
    leaked_amounts = nums(raw_amounts, 1000) & nums(out_amounts, 1000)
    if leaked_amounts:
        problems.append(f"{len(leaked_amounts)} raw amounts survive")
    leaked_heights = nums(raw_heights, 1000) & nums(out_heights, 1000)
    if leaked_heights:
        problems.append(f"{len(leaked_heights)} raw heights/timestamps survive")

    print(f"verify: {len(hex_tokens)} raw hex runs (20+ chars), "
          f"{len(raw_ids)} raw address/id values, {len(raw_comments)} comments, "
          f"{len(nums(raw_amounts, 1000))} amounts, "
          f"{len(nums(raw_heights, 1000))} heights/timestamps checked "
          f"against {len(list(out_dir.glob('*.json')))} fixture files")
    if problems:
        print("verify: FAILED: " + "; ".join(problems))
        return False
    print("verify: clean (0 raw hex runs, 0 ids, 0 comments, 0 amounts, "
          "0 heights/timestamps in output)")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--raw", type=Path, default=DEFAULT_RAW)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--seed-file", type=Path, default=DEFAULT_SEED)
    ap.add_argument("--verify", action="store_true", help="only verify")
    a = ap.parse_args()
    if not a.verify:
        sanitize(a.raw, a.out, load_seed(a.seed_file))
    sys.exit(0 if verify(a.raw, a.out) else 1)


if __name__ == "__main__":
    main()
