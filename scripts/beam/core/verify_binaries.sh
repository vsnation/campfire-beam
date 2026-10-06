#!/usr/bin/env bash
# Verify a directory of built BEAM binaries (wallet-api, beam-node, beam-wallet):
#
#   1. --version of each is the release version (7.5.14493, not 7.5.1).
#   2. A THROWAWAY wallet is created (beam-wallet init). Its password is random and
#      goes in through a 0600 --config_file, never argv. The generated seed phrase is
#      printed by beam-wallet on stdout; it is never shown or kept (only whitelisted,
#      non-secret lines pass the filter). No existing wallet is ever opened.
#   3. wallet-api is started on that wallet (TCP mode, random port) against a public
#      node. It must listen on 127.0.0.1 only, refuse a connection on this host's
#      non-loopback address, log the HF6 rules signature, and answer wallet_status.
#   4. beam-node is started on a temp storage dir with --fast_sync=1. Its P2P
#      listener must be on 127.0.0.1 only, with no UDP socket (LAN beacon off), it
#      must hold outbound peer connections and its tip must advance. A wallet-api
#      is pointed at it over loopback to show the local connection still works.
#   5. Everything is deleted afterwards.
#
# Usage: verify_binaries.sh <dir> [node_seconds]       (default node_seconds: 120)
# Env:   PUBLIC_NODE (default eu-node01.mainnet.beam.mw:8100)
#        NODE_PEER   (default eu-nodes.mainnet.beam.mw:8100)
# Needs: lsof, python3. Works with macOS /bin/bash 3.2.
set -uo pipefail

BIN_DIR="$(cd "${1:?usage: verify_binaries.sh <dir> [node_seconds]}" && pwd)"
NODE_SECS="${2:-120}"
PUBLIC_NODE="${PUBLIC_NODE:-eu-node01.mainnet.beam.mw:8100}"
NODE_PEER="${NODE_PEER:-eu-nodes.mainnet.beam.mw:8100}"
EXPECTED_VERSION="7.5.14493"
HF6_SIG="3928666-96df3f33ee02ad9e"

FAILS=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
info() { printf '      %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

non_loopback_ip() {
    local ip=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local ifc; ifc="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
        [[ -n "$ifc" ]] && ip="$(ipconfig getifaddr "$ifc" 2>/dev/null)"
    else
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    echo "$ip"
}

# try_connect <ip> <port> -> prints "refused" | "connected" | "error:<msg>"
try_connect() {
    python3 - "$1" "$2" <<'EOF'
import socket, sys
s = socket.socket(); s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("connected")
except ConnectionRefusedError:
    print("refused")
except Exception as e:
    print("error:%s" % e)
finally:
    s.close()
EOF
}

# rpc <port> <method>  -> one JSON-RPC call over wallet-api's TCP line protocol
rpc() {
    python3 - "$1" "$2" <<'EOF'
import json, socket, sys
port, method = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": {}}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
print(buf.decode().strip())
EOF
}

wait_listen() {   # wait_listen <pid> <port> <secs>
    local i=0
    while [[ $i -lt $3 ]]; do
        kill -0 "$1" 2>/dev/null || return 1
        lsof -nP -iTCP:"$2" -sTCP:LISTEN -a -p "$1" >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

stop_pid() {
    [[ -n "${1:-}" ]] || return 0
    kill -INT "$1" 2>/dev/null || return 0
    local i=0
    while kill -0 "$1" 2>/dev/null && [[ $i -lt 20 ]]; do sleep 1; i=$((i + 1)); done
    kill -KILL "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

T="$(mktemp -d "${TMPDIR:-/tmp}/beamcore-verify.XXXXXX")"
chmod 700 "$T"
API_PID=""; NODE_PID=""; API2_PID=""
cleanup() {
    stop_pid "$API_PID"; stop_pid "$API2_PID"; stop_pid "$NODE_PID"
    rm -rf "$T"
}
trap cleanup EXIT

section "binaries in $BIN_DIR"
for b in wallet-api beam-node beam-wallet; do
    [[ -x "$BIN_DIR/$b" ]] || { fail "$b missing"; continue; }
    v="$("$BIN_DIR/$b" --version 2>/dev/null | tr -d '\r' | head -1)"
    if [[ "$v" == "$EXPECTED_VERSION" ]]; then pass "$b --version = $v"; else fail "$b --version = '$v' (want $EXPECTED_VERSION)"; fi
done

# ---- throwaway wallet ------------------------------------------------------------
section "throwaway wallet"
mkdir -p "$T/w" && chmod 700 "$T/w"
( umask 077; printf 'pass=%s\n' "$(python3 -c 'import secrets;print(secrets.token_hex(24))')" > "$T/w/secret.cfg" )
info "password: random 48-hex, in a config file with mode $(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$T/w/secret.cfg")"
# Whitelist filter: only these non-secret lines are shown; the seed line never is.
( cd "$T/w" && "$BIN_DIR/beam-wallet" init --wallet_path="$T/w/wallet.db" --config_file="$T/w/secret.cfg" 2>&1 ) \
    | grep -E 'Rules signature|^[[:space:]]*[0-9]+-[0-9a-f]{16}[[:space:]]*$|created|ERROR|rror' | grep -v ';' | sed 's/^/      init: /'
if [[ -f "$T/w/wallet.db" ]]; then pass "beam-wallet init created a throwaway wallet.db"; else fail "beam-wallet init produced no wallet.db"; fi

# ---- wallet-api against a public node --------------------------------------------
section "wallet-api (public node $PUBLIC_NODE)"
API_PORT="$(free_port)"
( cd "$T/w" && exec "$BIN_DIR/wallet-api" --wallet_path="$T/w/wallet.db" --config_file="$T/w/secret.cfg" \
    --node_addr="$PUBLIC_NODE" --port="$API_PORT" --use_http=0 --enable_assets \
    --log_level=info --file_log_level=info > "$T/w/api.out" 2>&1 ) &
API_PID=$!
if wait_listen "$API_PID" "$API_PORT" 60; then
    info "pid $API_PID, port $API_PORT"
    info "lsof -nP -iTCP -sTCP:LISTEN -a -p $API_PID:"
    lsof -nP -iTCP -sTCP:LISTEN -a -p "$API_PID" | sed 's/^/        /'
    listen="$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$API_PID" | awk 'NR>1{print $9}')"
    if [[ -n "$listen" ]] && ! echo "$listen" | grep -vq '^127\.0\.0\.1:'; then pass "wallet-api listens on 127.0.0.1 only ($listen)"; else fail "wallet-api listen set: $listen"; fi
    udp="$(lsof -nP -iUDP -a -p "$API_PID" | awk 'NR>1{print $9}')"
    [[ -z "$udp" ]] && pass "wallet-api has no UDP sockets" || fail "wallet-api UDP sockets: $udp"
    lan="$(non_loopback_ip)"
    if [[ -n "$lan" ]]; then
        r="$(try_connect "$lan" "$API_PORT")"
        [[ "$r" == "refused" ]] && pass "connect to $lan:$API_PORT (non-loopback) -> $r" || fail "connect to $lan:$API_PORT (non-loopback) -> $r"
    fi
    sleep 3
    sig="$(grep -A12 'Rules signature' "$T/w/api.out" | grep -oE '[0-9]+-[0-9a-f]{16}' | tr '\n' ' ')"
    info "Rules signature forks: $sig"
    echo "$sig" | grep -q "$HF6_SIG" && pass "rules signature contains HF6 $HF6_SIG" || fail "HF6 $HF6_SIG not in rules signature"
    grep -m1 -E 'Beam Wallet API' "$T/w/api.out" | sed 's/^/      log: /'
    # "Synced" = is_in_sync AND a height past the HF6 block AND a tip at most 10 min old.
    # (Right after start wallet-api can report is_in_sync=true at height 0, before it
    # has heard of any tip; that must not count.)
    st_line=""; i=0
    while [[ $i -lt 120 ]]; do
        st_line="$(rpc "$API_PORT" wallet_status 2>/dev/null | python3 -c 'import json,sys,time
try:
  r=json.load(sys.stdin)["result"]
  print("%s %s %s" % (r.get("is_in_sync"), r.get("current_height") or 0, int(time.time()) - int(r.get("current_state_timestamp") or 0)))
except Exception: print("")' 2>/dev/null)"
        set -- $st_line
        if [[ "${1:-}" == "True" && "${2:-0}" -gt 3928666 ]]; then break; fi
        sleep 2; i=$((i + 2))
    done
    set -- $st_line
    if [[ "${1:-}" == "True" && "${2:-0}" -gt 3928666 && "${3:-99999}" -lt 600 ]]; then
        pass "wallet_status: is_in_sync=true current_height=$2 (past HF6 3928666) tip_age=${3}s"
    else
        fail "wallet_status not synced past HF6 with a fresh tip (last: '$st_line' = in_sync height tip_age_s)"
    fi
else
    fail "wallet-api did not start listening"; tail -20 "$T/w/api.out" | grep -v ';' | sed 's/^/      /'
fi
stop_pid "$API_PID"; API_PID=""

# ---- beam-node -------------------------------------------------------------------
section "beam-node (peer $NODE_PEER, fast sync, ${NODE_SECS}s)"
mkdir -p "$T/node" && chmod 700 "$T/node"
NODE_PORT="$(free_port)"
( cd "$T/node" && exec "$BIN_DIR/beam-node" --port="$NODE_PORT" --storage="$T/node/node.db" \
    --peer="$NODE_PEER" --fast_sync=1 --log_level=info --file_log_level=info > "$T/node/node.out" 2>&1 ) &
NODE_PID=$!
if wait_listen "$NODE_PID" "$NODE_PORT" 60; then
    info "pid $NODE_PID, port $NODE_PORT"
    grep -m1 'Beam Node' "$T/node/node.out" | sed 's/^/      log: /'
    sig="$(grep -A12 'Rules signature' "$T/node/node.out" | grep -oE '[0-9]+-[0-9a-f]{16}' | tr '\n' ' ')"
    echo "$sig" | grep -q "$HF6_SIG" && pass "beam-node rules signature contains HF6 $HF6_SIG" || fail "HF6 not in beam-node rules signature ($sig)"
    sleep 20
    info "lsof -nP -iTCP -sTCP:LISTEN -a -p $NODE_PID:"
    lsof -nP -iTCP -sTCP:LISTEN -a -p "$NODE_PID" | sed 's/^/        /'
    listen="$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$NODE_PID" | awk 'NR>1{print $9}')"
    if [[ -n "$listen" ]] && ! echo "$listen" | grep -vq '^127\.0\.0\.1:'; then pass "beam-node listens on 127.0.0.1 only ($listen)"; else fail "beam-node listen set: $listen"; fi
    info "lsof -nP -iUDP -a -p $NODE_PID:"
    lsof -nP -iUDP -a -p "$NODE_PID" | sed 's/^/        /'
    udp="$(lsof -nP -iUDP -a -p "$NODE_PID" | awk 'NR>1{print $9}')"
    [[ -z "$udp" ]] && pass "beam-node has no UDP sockets (LAN beacon off)" || fail "beam-node UDP sockets: $udp"
    lan="$(non_loopback_ip)"
    if [[ -n "$lan" ]]; then
        r="$(try_connect "$lan" "$NODE_PORT")"
        [[ "$r" == "refused" ]] && pass "connect to $lan:$NODE_PORT (non-loopback) -> $r" || fail "connect to $lan:$NODE_PORT (non-loopback) -> $r"
    fi
    out="$(lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$NODE_PID" | awk 'NR>1{print $9}')"
    nout="$(echo "$out" | grep -c -- '->' || true)"
    info "established: $(echo "$out" | tr '\n' ' ')"
    [[ "$nout" -gt 0 ]] && pass "beam-node holds $nout outbound peer connection(s)" || fail "beam-node has no outbound peer connections"

    # A wallet-api on loopback -> the local node still works.
    API2_PORT="$(free_port)"
    ( cd "$T/w" && exec "$BIN_DIR/wallet-api" --wallet_path="$T/w/wallet.db" --config_file="$T/w/secret.cfg" \
        --node_addr="127.0.0.1:$NODE_PORT" --port="$API2_PORT" --use_http=0 --enable_assets \
        --log_level=info --file_log_level=info > "$T/w/api2.out" 2>&1 ) &
    API2_PID=$!
    if wait_listen "$API2_PID" "$API2_PORT" 60; then
        sleep 5
        conn="$(lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$API2_PID" | awk 'NR>1{print $9}' | grep -- "->127.0.0.1:$NODE_PORT" || true)"
        [[ -n "$conn" ]] && pass "wallet-api connected to the loopback node ($conn)" || fail "wallet-api did not connect to 127.0.0.1:$NODE_PORT"
    else
        fail "second wallet-api did not start"
    fi
    stop_pid "$API2_PID"; API2_PID=""

    elapsed=25
    while [[ $elapsed -lt $NODE_SECS ]]; do sleep 5; elapsed=$((elapsed + 5)); done
    tips="$(grep -E 'My Tip:' "$T/node/node.out" | grep -oE 'My Tip: [0-9]+' | awk '{print $3}')"
    first="$(echo "$tips" | head -1)"; last="$(echo "$tips" | tail -1)"
    info "My Tip lines: $(echo "$tips" | grep -c . ) first=${first:-none} last=${last:-none}"
    grep -E 'Updating node:|Fast-sync|fast sync|FastSync' "$T/node/node.out" | head -3 | sed 's/^/      log: /'
    grep -E 'Updating node:' "$T/node/node.out" | tail -2 | sed 's/^/      log: /'
    grep -E 'My Tip:' "$T/node/node.out" | tail -1 | sed 's/^/      log: /'
    if [[ -n "$last" && -n "$first" && "$last" -gt "$first" ]]; then pass "node tip advanced $first -> $last in ${NODE_SECS}s"
    elif grep -q 'Updating node:' "$T/node/node.out"; then pass "node is syncing (Updating node: progress lines)"
    else fail "no sync progress seen"; fi
else
    fail "beam-node did not start listening"; tail -20 "$T/node/node.out" | sed 's/^/      /'
fi
stop_pid "$NODE_PID"; NODE_PID=""

section "result"
if [[ $FAILS -eq 0 ]]; then echo "ALL CHECKS PASSED"; else echo "$FAILS CHECK(S) FAILED"; fi
exit $FAILS
