#!/usr/bin/env bash
# Verify wallet-api's --privileged_shader_sha256 (patch 0002) on a THROWAWAY wallet.
#
# The BANS app shader needs privilege 1 for `role=user,action=view` (get_PkEx). The
# runs below use one throwaway, zero-balance wallet, one wallet-api at a time:
#
#   A  no flag                    BANS user view -> must fail in get_PkEx (stock privilege 0)
#   B  flag = BANS hash           BANS user view -> must succeed; DEX pools_view must work
#                                 and must NOT be logged as privilege 1
#   C  flag = DEX hash only       BANS user view -> must fail in get_PkEx again: a shader that
#                                 is not listed stays at 0 even when the list is non-empty
#   D  flag = malformed hex       wallet-api must refuse to start (fail closed)
#   E  flag = BANS hash           process_invoke_data with forged invoke data that asks to
#                                 re-run an arbitrary app body at privilege 1 or 2 -> refused;
#                                 the same data at privilege 0 passes the guard (control)
#
# Usage: verify_privileged_shader.sh <bin dir> <bans app.wasm> <dex amm_app.wasm>
# Env:   PUBLIC_NODE (default eu-node01.mainnet.beam.mw:8100)
set -uo pipefail

BIN_DIR="$(cd "${1:?bin dir}" && pwd)"
BANS_WASM="${2:?bans app.wasm}"
DEX_WASM="${3:?dex amm_app.wasm}"
PUBLIC_NODE="${PUBLIC_NODE:-eu-node01.mainnet.beam.mw:8100}"
BANS_CID="af4550f1f8a6051ffeffea06e0cb978f8076fdfc2101d2273d4e62c86540bc5e"
DEX_CID="729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf"
BANS_PINNED="99eb1dfb023d30c338e3c4a4c536b7695b48ca25e27f9ce5f659b6567241736d"

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf '      %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

BANS_SHA="$(sha "$BANS_WASM")"; DEX_SHA="$(sha "$DEX_WASM")"
info "BANS shader $BANS_WASM sha256 $BANS_SHA"
info "DEX  shader $DEX_WASM sha256 $DEX_SHA"
[[ "$BANS_SHA" == "$BANS_PINNED" ]] && pass "BANS shader matches the pinned hash" || fail "BANS shader hash $BANS_SHA != pinned $BANS_PINNED"

T="$(mktemp -d "${TMPDIR:-/tmp}/beamcore-priv.XXXXXX")"; chmod 700 "$T"
API_PID=""
stop_api() {
    [[ -n "$API_PID" ]] || return 0
    kill -INT "$API_PID" 2>/dev/null; local i=0
    while kill -0 "$API_PID" 2>/dev/null && [[ $i -lt 20 ]]; do sleep 1; i=$((i + 1)); done
    kill -KILL "$API_PID" 2>/dev/null; wait "$API_PID" 2>/dev/null; API_PID=""
}
trap 'stop_api; rm -rf "$T"' EXIT

( umask 077; printf 'pass=%s\n' "$(python3 -c 'import secrets;print(secrets.token_hex(24))')" > "$T/secret.cfg" )
( cd "$T" && "$BIN_DIR/beam-wallet" init --wallet_path="$T/wallet.db" --config_file="$T/secret.cfg" >/dev/null 2>&1 )
[[ -f "$T/wallet.db" ]] && pass "throwaway wallet created (seed discarded, password in a 0600 file)" || { fail "beam-wallet init failed"; exit 1; }

# start_api <log> [extra args...]  -> sets API_PID, API_PORT; returns 1 if it never listens
start_api() {
    local logf="$1"; shift
    API_PORT="$(free_port)"
    ( cd "$T" && exec "$BIN_DIR/wallet-api" --wallet_path="$T/wallet.db" --config_file="$T/secret.cfg" \
        --node_addr="$PUBLIC_NODE" --port="$API_PORT" --use_http=0 --tcp_max_line=16777216 \
        --enable_assets --log_level=info --file_log_level=info "$@" > "$logf" 2>&1 ) &
    API_PID=$!
    local i=0
    while [[ $i -lt 60 ]]; do
        kill -0 "$API_PID" 2>/dev/null || { API_PID=""; return 1; }
        lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN -a -p "$API_PID" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# invoke <wasm> <args> -> prints a one-line summary of the wallet-api answer
invoke() {
    python3 - "$API_PORT" "$1" "$2" <<'EOF'
import json, socket, sys
port, wasm, args = int(sys.argv[1]), sys.argv[2], sys.argv[3]
code = list(open(wasm, "rb").read())
req = {"jsonrpc": "2.0", "id": 1, "method": "invoke_contract",
       "params": {"contract": code, "args": args, "create_tx": False}}
s = socket.create_connection(("127.0.0.1", port), timeout=120)
s.sendall((json.dumps(req) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    c = s.recv(65536)
    if not c: break
    buf += c
r = json.loads(buf)
if "error" in r:
    e = r["error"]
    print("ERROR code=%s message=%s data=%s" % (e.get("code"), e.get("message"), str(e.get("data"))[:160]))
else:
    out = r["result"].get("output", "")
    print("OK output=%s" % out[:200].replace("\n", " "))
EOF
}

wait_synced() {
    python3 - "$API_PORT" <<'EOF'
import json, socket, sys, time
port = int(sys.argv[1])
for _ in range(60):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=10)
        s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"wallet_status"}\n')
        buf = b""
        while not buf.endswith(b"\n"):
            c = s.recv(65536)
            if not c: break
            buf += c
        r = json.loads(buf)["result"]
        if r.get("is_in_sync") and (r.get("current_height") or 0) > 3928666:
            print("in sync at height %s" % r.get("current_height")); sys.exit(0)
    except Exception:
        pass
    time.sleep(2)
print("not in sync"); sys.exit(1)
EOF
}

BANS_VIEW="role=user,action=view,cid=${BANS_CID}"
DEX_VIEW="action=pools_view,cid=${DEX_CID}"

section "A: no --privileged_shader_sha256 (stock)"
if start_api "$T/a.log"; then
    info "$(wait_synced)"
    r="$(invoke "$BANS_WASM" "$BANS_VIEW")"; info "BANS user view -> $r"
    [[ "$r" == ERROR*get_PkEx* ]] && pass "BANS user view fails in get_PkEx at privilege 0" || fail "expected get_PkEx failure, got: $r"
else fail "wallet-api A did not start"; fi
stop_api

section "B: --privileged_shader_sha256=<BANS>"
if start_api "$T/b.log" --privileged_shader_sha256="$BANS_SHA"; then
    info "$(wait_synced)"
    grep -m1 'Privileged app shader' "$T/b.log" | sed 's/^/      log: /'
    r="$(invoke "$BANS_WASM" "$BANS_VIEW")"; info "BANS user view -> $r"
    [[ "$r" == OK* ]] && pass "BANS user view succeeds at privilege 1" || fail "BANS user view: $r"
    r="$(invoke "$DEX_WASM" "$DEX_VIEW")"; info "DEX pools_view -> ${r:0:120}"
    [[ "$r" == OK* ]] && pass "DEX pools_view works" || fail "DEX pools_view: $r"
    grep 'runs at privilege 1' "$T/b.log" | sed 's/^/      log: /'
    grep -q "app shader $BANS_SHA runs at privilege 1" "$T/b.log" && pass "log: BANS shader routed to privilege 1" || fail "no privilege-1 log line for BANS"
    grep -q "app shader $DEX_SHA runs at privilege 1" "$T/b.log" && fail "DEX shader was routed to privilege 1" || pass "DEX shader not routed to privilege 1 (stays 0)"
else fail "wallet-api B did not start"; tail -5 "$T/b.log"; fi
stop_api

section "C: --privileged_shader_sha256=<DEX> (BANS not listed)"
if start_api "$T/c.log" --privileged_shader_sha256="$DEX_SHA"; then
    info "$(wait_synced)"
    r="$(invoke "$BANS_WASM" "$BANS_VIEW")"; info "BANS user view -> $r"
    [[ "$r" == ERROR*get_PkEx* ]] && pass "unlisted BANS shader stays at privilege 0 (get_PkEx fails)" || fail "expected get_PkEx failure, got: $r"
else fail "wallet-api C did not start"; fi
stop_api

section "D: malformed hash"
if start_api "$T/d.log" --privileged_shader_sha256="not-a-hash"; then
    fail "wallet-api started with a malformed hash"
else
    grep -m1 'privileged_shader_sha256' "$T/d.log" | sed 's/^/      log: /'
    pass "wallet-api refused to start with a malformed hash"
fi
stop_api

section "E: process_invoke_data with forged app privilege (flag = BANS)"
# A DEX trade's invoke data is a dependent call that already carries the app invocation
# to re-run on rebuild (flags SaveAppInvoke|Dependent, the DEX body, m_Privilege=0 as the
# last field). Rewrite only m_Privilege to 1 and 2. Stock wallet-api accepts that and
# re-runs the (non-allowlisted) DEX body at the forged privilege. The unmodified data
# (privilege 0) is the control; on this zero-balance wallet its tx fails for lack of funds.
if start_api "$T/e.log" --privileged_shader_sha256="$BANS_SHA"; then
    info "$(wait_synced)"
    invoke "$BANS_WASM" "$BANS_VIEW" >/dev/null     # populate the allowlisted-body set
    python3 - "$API_PORT" "$DEX_WASM" "$DEX_CID" > "$T/e.out" <<'EOF'
import json, socket, sys
port, wasm, cid = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def call(req):
    s = socket.create_connection(("127.0.0.1", port), timeout=120)
    s.sendall((json.dumps(req) + "\n").encode()); buf = b""
    while not buf.endswith(b"\n"):
        c = s.recv(65536)
        if not c: break
        buf += c
    return json.loads(buf)
def enc(v):                      # yas compacted unsigned
    if v < 0x80: return bytes([v | 0x80])
    n = max(1, (v.bit_length() + 7) // 8)
    return bytes([n]) + v.to_bytes(n, "little")
def dec(b, p):
    if b[p] & 0x80: return b[p] & 0x7f, p + 1
    n = b[p]; return int.from_bytes(b[p + 1:p + 1 + n], "little"), p + 1 + n
r = call({"jsonrpc": "2.0", "id": 1, "method": "invoke_contract", "params": {
    "contract": list(open(wasm, "rb").read()), "create_tx": False,
    "args": "role=user,action=pool_trade,cid=%s,aid1=0,aid2=174,kind=2,val1_buy=1000000" % cid}})
raw = bytes(r["result"]["raw_data"])
nvec, p = dec(raw, 0)
nval, q = dec(raw, p)
flags = (nval & 0x7fffffff) if (nval & 0x80000000) else 0
print("DEX trade invoke data: %d bytes, first entry flags=0x%02x" % (len(raw), flags))
if (flags & 0x20) and not (flags & 0x40) and raw[-1] == 0x80:
    # Already a dependent call with a saved app invocation (the real DEX body at
    # privilege 0); m_Privilege is the last field. Only that byte changes.
    def forged(priv):
        return list(raw[:-1] + enc(priv))
else:
    # No saved app invocation yet: set SaveAppInvoke and append one with a made-up body.
    if nval & 0x80000000:
        head = enc(nval | 0x20)
    else:
        head = enc(0x80000000 | 0x20) + enc(nval)
    base = raw[:p] + head + raw[q:]
    def forged(priv):
        app = b"campfire-forged-app-body"
        return list(base + enc(len(app)) + app + enc(0) + enc(0) + enc(priv))
for priv in (1, 2, 0):
    r = call({"jsonrpc": "2.0", "id": 10 + priv, "method": "process_invoke_data", "params": {"data": forged(priv)}})
    if "error" in r:
        print("priv=%d ERROR %s / %s" % (priv, r["error"].get("message"), r["error"].get("data")))
    else:
        print("priv=%d OK %s" % (priv, json.dumps(r["result"])[:120]))
EOF
    sed 's/^/      /' "$T/e.out"
    grep -q 'priv=1 ERROR.*not granted' "$T/e.out" && pass "forged privilege-1 invoke data refused" || fail "forged privilege-1 invoke data was not refused"
    grep -q 'priv=2 ERROR.*not granted' "$T/e.out" && pass "forged privilege-2 invoke data refused" || fail "forged privilege-2 invoke data was not refused"
    grep -q 'priv=0' "$T/e.out" && ! grep -q 'priv=0 ERROR.*not granted' "$T/e.out" && pass "same data at privilege 0 passes the guard (parsed, handed to the stock path)" || fail "privilege-0 control was refused or missing"
    grep 'process_invoke_data refused' "$T/e.log" | head -2 | sed 's/^/      log: /'
else fail "wallet-api E did not start"; fi
stop_api

section "result"
if [[ $FAILS -eq 0 ]]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit $FAILS
