#!/usr/bin/env python3
# Verify the Windows build of Campfire's BEAM core, the way verify_binaries.sh
# does on macOS and Linux (that script needs lsof):
#
#   1. --version of each binary is the release version.
#   2. wallet-api offers --privileged_shader_sha256 (patch 0002).
#   3. A THROWAWAY wallet is created (beam-wallet init); its random password goes
#      in through a --config_file, never argv; the seed beam-wallet prints is never
#      shown (only whitelisted lines pass).
#   4. wallet-api runs on it against a public node: it must listen on 127.0.0.1 only
#      (patch 0001), refuse a connection on this host's non-loopback address, log
#      the HF6 rules signature, and answer wallet_status.
#
# Usage: verify_windows.py <dir with wallet-api.exe, beam-node.exe, beam-wallet.exe>
import json, os, re, secrets, shutil, socket, subprocess, sys, tempfile, time

EXPECTED_VERSION = "7.5.14493"
HF6_SIG = "3928666-96df3f33ee02ad9e"
PUBLIC_NODE = os.environ.get("PUBLIC_NODE", "eu-node01.mainnet.beam.mw:8100")

bins = sys.argv[1]
fails = 0


def ok(msg): print("PASS  " + msg)
def bad(msg):
    global fails
    fails += 1
    print("FAIL  " + msg)


def exe(name): return os.path.join(bins, name + ".exe")


for b in ("wallet-api", "beam-node", "beam-wallet"):
    if not os.path.isfile(exe(b)):
        bad(f"{b}.exe missing"); continue
    v = subprocess.run([exe(b), "--version"], capture_output=True, text=True, timeout=60)
    first = (v.stdout or v.stderr).strip().splitlines()[:1]
    if first == [EXPECTED_VERSION]: ok(f"{b} --version = {first[0]}")
    else: bad(f"{b} --version = {first!r} (want {EXPECTED_VERSION})")

h = subprocess.run([exe("wallet-api"), "--help"], capture_output=True, text=True, timeout=60)
if "privileged_shader_sha256" in h.stdout + h.stderr: ok("wallet-api offers --privileged_shader_sha256")
else: bad("wallet-api has no --privileged_shader_sha256")

t = tempfile.mkdtemp(prefix="beamcore-verify-")
api = None
try:
    w = os.path.join(t, "w"); os.makedirs(w)
    cfg = os.path.join(w, "secret.cfg")
    with open(cfg, "w") as f: f.write("pass=%s\n" % secrets.token_hex(24))
    db = os.path.join(w, "wallet.db")
    init = subprocess.run([exe("beam-wallet"), "init", f"--wallet_path={db}", f"--config_file={cfg}"],
                          cwd=w, capture_output=True, text=True, timeout=180)
    for line in (init.stdout + init.stderr).splitlines():
        if ";" in line: continue                 # the seed phrase line: never shown
        if re.search(r"Rules signature|created|rror", line): print("      init: " + line.strip())
    if os.path.isfile(db): ok("beam-wallet init created a throwaway wallet.db")
    else: bad("beam-wallet init produced no wallet.db")

    s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
    log = open(os.path.join(w, "api.out"), "w")
    api = subprocess.Popen([exe("wallet-api"), f"--wallet_path={db}", f"--config_file={cfg}",
                            f"--node_addr={PUBLIC_NODE}", f"--port={port}", "--use_http=0",
                            "--enable_assets", "--log_level=info", "--file_log_level=info"],
                           cwd=w, stdout=log, stderr=subprocess.STDOUT)
    listening = []
    for _ in range(60):
        out = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True).stdout
        listening = [l.split()[1] for l in out.splitlines()
                     if l.strip().startswith("TCP") and "LISTENING" in l and l.split()[-1] == str(api.pid)]
        if any(a.endswith(f":{port}") for a in listening): break
        if api.poll() is not None: break
        time.sleep(1)
    if listening and all(a.startswith("127.0.0.1:") for a in listening):
        ok(f"wallet-api listens on 127.0.0.1 only ({', '.join(listening)})")
    else:
        bad(f"wallet-api listen set: {listening}")

    ip = None
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.connect(("1.1.1.1", 53)); ip = u.getsockname()[0]; u.close()
    except OSError:
        pass
    if ip and ip != "127.0.0.1":
        c = socket.socket(); c.settimeout(3)
        try:
            c.connect((ip, port)); bad(f"a connection to {ip}:{port} was accepted")
        except (ConnectionRefusedError, socket.timeout, OSError):
            ok(f"a connection to {ip}:{port} is refused")
        finally:
            c.close()

    sig, status = False, None
    for _ in range(60):
        with open(os.path.join(w, "api.out")) as f: text = f.read()
        sig = sig or HF6_SIG in text
        try:
            r = socket.create_connection(("127.0.0.1", port), timeout=10)
            r.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": "wallet_status", "params": {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = r.recv(65536)
                if not chunk: break
                buf += chunk
            r.close()
            status = json.loads(buf.decode())
        except (OSError, ValueError):
            status = None
        if sig and status and "result" in status: break
        time.sleep(2)
    if sig: ok(f"wallet-api logs the HF6 rules signature {HF6_SIG}")
    else: bad("no HF6 rules signature in the wallet-api log")
    if status and "result" in status:
        ok("wallet_status answered (height %s)" % status["result"].get("current_height"))
    else:
        bad(f"wallet_status: {status}")
finally:
    if api and api.poll() is None:
        api.terminate()
        try: api.wait(20)
        except subprocess.TimeoutExpired: api.kill()
    shutil.rmtree(t, ignore_errors=True)

print("\n%s" % ("ALL CHECKS PASSED" if fails == 0 else f"{fails} CHECK(S) FAILED"))
sys.exit(1 if fails else 0)
