#!/usr/bin/env python3
"""Drive a hardened wallet-api for live mainnet tests, with no secrets in this repo.

Credentials come from ~/.config/campfire-beam/test_wallets.env (mode 0600):
    <LABEL>_WALLET_DB=/abs/path/wallet.db
    <LABEL>_WALLET_PASS=...

    wapi.py start <label> [--port 10100] [--node eu-node01.mainnet.beam.mw:8100] [--tcp]
    wapi.py call  <label> <method> ['{"json": "params"}']
    wapi.py wait-sync <label> [--timeout 900]
    wapi.py stop  <label>

--tcp starts wallet-api in TCP line mode (--use_http=0 --tcp_max_line=16777216), the
mode Campfire's TcpLineTransport speaks and the only one that carries ev_* push events.
The mode is recorded in the state file; call/wait-sync pick the matching client.

The launch mirrors LightWallet's serve.py hardening: password via a 0600 --config_file
deleted after start, --ip_whitelist=127.0.0.1 (wallet-api binds 0.0.0.0 and has no bind
flag), and a per-launch ACL key required in every JSON-RPC body.
"""
import json, os, secrets, signal, socket, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

CONF = Path.home() / ".config/campfire-beam/test_wallets.env"
RUN = Path.home() / "beam-campfire-test/run"
BIN = Path(os.environ.get("BEAM_BIN_DIR",
          str(Path.home() / "Desktop/Beam/LightWallet/binaries/macos")))
DEFAULT_NODE = "eu-node01.mainnet.beam.mw:8100"


def env():
    out = {}
    for line in CONF.read_text().splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def state_path(label):
    return RUN / f"{label}.json"


def secret_file(content, suffix):
    RUN.mkdir(parents=True, exist_ok=True)
    os.chmod(RUN, 0o700)
    fd, p = tempfile.mkstemp(dir=RUN, prefix=".s-", suffix=suffix)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.chmod(p, 0o600)
    return p


def start(label, port=10100, node=DEFAULT_NODE, tcp=False):
    e = env()
    db, pw = e[f"{label.upper()}_WALLET_DB"], e[f"{label.upper()}_WALLET_PASS"]
    if state_path(label).exists():
        sys.exit(f"{label} already running per {state_path(label)}; stop it first")
    key = secrets.token_hex(24)
    cfg = secret_file(f"pass={pw}\n", ".cfg")
    acl = secret_file(f"{key}:write\n", ".acl")
    log = open(RUN / f"{label}.log", "w")
    os.chmod(RUN / f"{label}.log", 0o600)
    mode = "tcp" if tcp else "http"
    transport = (["--use_http=0", "--tcp_max_line=16777216"] if tcp
                 else ["--use_http=1"])
    p = subprocess.Popen([
        str(BIN / "wallet-api"), f"--wallet_path={db}", f"--config_file={cfg}",
        f"--node_addr={node}", f"--port={port}", *transport,
        "--ip_whitelist=127.0.0.1", "--use_acl=1", f"--acl_path={acl}",
        "--enable_assets", "--enable_lelantus",
    ], stdout=log, stderr=subprocess.STDOUT, cwd=str(RUN), start_new_session=True)
    try:
        for _ in range(30):
            time.sleep(1)
            try:
                r = _rpc(port, key, "wallet_status", {}, mode=mode)
                if "result" in r or "error" in r:
                    break
            except Exception:
                if p.poll() is not None:
                    sys.exit(f"wallet-api exited with {p.returncode}; see {RUN}/{label}.log")
    finally:
        for f in (cfg, acl):
            try:
                os.remove(f)
            except OSError:
                pass
    # Create the state file 0600 from the start: it holds the ACL key.
    fd = os.open(state_path(label), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps({"pid": p.pid, "port": port, "key": key, "node": node,
                            "mode": mode}))
    print(json.dumps({"label": label, "pid": p.pid, "port": port, "node": node,
                      "mode": mode}))


def _rpc(port, key, method, params, timeout=60, mode="http"):
    if mode == "tcp":
        return _rpc_tcp(port, key, method, params, timeout)
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params, "key": key}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/api/wallet", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _rpc_tcp(port, key, method, params, timeout=60):
    """One request on a fresh TCP connection; ev_* lines are skipped."""
    req = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params, "key": key}
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                raise ConnectionError("wallet-api closed the connection")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                msg = json.loads(line)
                if msg.get("id") == 1:
                    return msg


def _state(label):
    s = json.loads(state_path(label).read_text())
    s.setdefault("mode", "http")
    return s


def call(label, method, params="{}"):
    s = _state(label)
    print(json.dumps(_rpc(s["port"], s["key"], method, json.loads(params),
                          mode=s["mode"]), indent=1))


def wait_sync(label, timeout=900):
    s = _state(label)
    t0 = time.time()
    while time.time() - t0 < timeout:
        st = _rpc(s["port"], s["key"], "wallet_status", {},
                  mode=s["mode"]).get("result", {})
        age = time.time() - st.get("current_state_timestamp", 0)
        print(f"height={st.get('current_height')} in_sync={st.get('is_in_sync')} tip_age={age:.0f}s", flush=True)
        if st.get("is_in_sync") and age < 600:
            return
        time.sleep(10)
    sys.exit("timed out waiting for sync")


def stop(label):
    sp = state_path(label)
    if not sp.exists():
        return print(f"{label} not running")
    s = json.loads(sp.read_text())
    try:
        os.kill(s["pid"], signal.SIGTERM)
        for _ in range(20):
            time.sleep(0.5)
            os.kill(s["pid"], 0)
        os.kill(s["pid"], signal.SIGKILL)
    except ProcessLookupError:
        pass
    sp.unlink()
    print(f"{label} stopped")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    opt = lambda name, d: (a[a.index(name) + 1] if name in a else d)
    if a[0] == "start":
        start(a[1], int(opt("--port", 10100)), opt("--node", DEFAULT_NODE),
              tcp="--tcp" in a)
    elif a[0] == "call":
        call(a[1], a[2], a[3] if len(a) > 3 else "{}")
    elif a[0] == "wait-sync":
        wait_sync(a[1], int(opt("--timeout", 900)))
    elif a[0] == "stop":
        stop(a[1])
    else:
        sys.exit(__doc__)
