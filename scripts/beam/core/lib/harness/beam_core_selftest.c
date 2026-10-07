// Self-test for libbeam_core, run by scripts/beam/core/lib/verify_lib.sh. Not shipped.
//
//   beam_core_selftest <workdir> <direct wallet node> <direct node peers>
//                      <socks port|0> <tor wallet node ip:port|-> <tor node peers|->
//                      <lan ip|-> <node seconds>
//
// One process, as the app: wallet-api and the integrated node run inside it at the
// same time, against BEAM mainnet, with a throwaway wallet in <workdir> (which
// holds 0600 phrase.txt and pass.txt written by verify_lib.sh; both are deleted
// here once read). Phases:
//
//   1 basic     version, rules, wallet create / password check / owner key export
//   2 direct    wallet-api + node without a proxy; loopback-only listening; no child
//               process; node stop while wallet-api runs; node restart; stop both
//   3 tor       the same through the SOCKS5 proxy (Tor) at 127.0.0.1:<socks port>
//   4 dead      the proxy port closed: nothing may go anywhere else
//   5 names     with a proxy a host name is refused and never looked up;
//   6 control   without a proxy the same name IS looked up (the canary works)
//   7 multi     three wallets as concurrent instances (beam_wallet_api_start) plus
//               the node; stop / restart the middle one; 20x start/stop under load;
//               the instance API's error paths
//   8 multi-tor the three instances and the node through Tor
//   end         nothing left running, no child process, logs clean, no leaks
//               (macOS `leaks` on this process)
//
// With net_canary.dylib inserted (DYLD_INSERT_LIBRARIES) every name lookup,
// connect() and UDP send of the process is recorded, so "nothing but 127.0.0.1"
// is checked for every call, not only for the sockets lsof happens to see.
//
// Prints heights, flags, counts and return codes: never a balance, an address of
// the wallet, the phrase, the password or the owner key.
#include <arpa/inet.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "beam_core.h"

extern char** environ;

static int failures = 0;
#define CHECK(cond, ...) do { if (cond) { printf("PASS  "); } else { printf("FAIL  "); failures++; } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
#define INFO(...) do { printf("      "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec / 1e9;
}

static void sleep_s(double s) { usleep((useconds_t)(s * 1e6)); }

// ---- canary --------------------------------------------------------------------------
static void (*canary_set_phase)(int);
static void (*canary_count)(int, int*, int*, int*, int*, int);
static int (*canary_looked_up)(const char*);

static void canary_phase(int phase) { if (canary_set_phase) canary_set_phase(phase); }

// ---- files ---------------------------------------------------------------------------
static char* read_secret(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    static char buf[1024];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
    buf[n] = 0;
    char* out = strdup(buf);
    memset(buf, 0, sizeof(buf));
    return out;
}

static int write_private(const char* path, const char* text)
{
    unlink(path);
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    chmod(path, 0600);
    fputs(text, f);
    fclose(f);
    return 0;
}

static long long dir_bytes(const char* dir)
{
    DIR* d = opendir(dir);
    if (!d) return 0;
    long long total = 0;
    struct dirent* e;
    char p[2048];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof(p), "%s/%s", dir, e->d_name);
        struct stat st;
        if (lstat(p, &st) == 0) total += S_ISDIR(st.st_mode) ? dir_bytes(p) : (long long)st.st_size;
    }
    closedir(d);
    return total;
}

// ---- sockets ---------------------------------------------------------------------------
static int free_port(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof(a);
    bind(s, (struct sockaddr*)&a, sizeof(a));
    getsockname(s, (struct sockaddr*)&a, &len);
    int port = ntohs(a.sin_port);
    close(s);
    return port;
}

// A listener on 127.0.0.1:port held by this process (to make the port busy).
static int hold_port(int* port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    socklen_t len = sizeof(a);
    if (bind(s, (struct sockaddr*)&a, sizeof(a)) || listen(s, 1)) { close(s); return -1; }
    getsockname(s, (struct sockaddr*)&a, &len);
    *port = ntohs(a.sin_port);
    return s;
}

static int connect_to(const char* ip, int port, int* err)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    inet_pton(AF_INET, ip, &a.sin_addr);
    a.sin_port = htons((uint16_t)port);
    struct timeval tv = {5, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { if (err) *err = errno; close(s); return -1; }
    tv.tv_sec = 20;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return s;
}

// One request line, one response line.
static int rpc(int s, const char* acl, int id, const char* method, char* out, size_t cap)
{
    char req[512];
    snprintf(req, sizeof(req), "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"%s\",\"params\":{},\"key\":\"%s\"}\n", id, method, acl);
    if (send(s, req, strlen(req), 0) < 0) return -1;
    size_t n = 0;
    while (n + 1 < cap) {
        ssize_t r = recv(s, out + n, 1, 0);
        if (r <= 0) return -1;
        if (out[n] == '\n') break;
        n++;
    }
    out[n] = 0;
    return (int)n;
}

static long long json_int(const char* json, const char* key)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char* p = strstr(json, pat);
    return p ? strtoll(p + strlen(pat), NULL, 10) : -1;
}

static int json_bool(const char* json, const char* key)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char* p = strstr(json, pat);
    if (!p) return -1;
    p += strlen(pat);
    while (*p == ' ') p++;
    return strncmp(p, "true", 4) == 0 ? 1 : 0;
}

// ---- child processes (only lsof and pgrep, started by this test) -------------------------
static int spawn_capture(char* const argv[], char* out, size_t cap)
{
    int fds[2];
    if (pipe(fds)) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 0, 0);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    size_t n = 0;
    if (rc == 0) {
        ssize_t r;
        while (n + 1 < cap && (r = read(fds[0], out + n, cap - 1 - n)) > 0) n += (size_t)r;
    }
    out[n] = 0;
    close(fds[0]);
    if (rc != 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int no_children(void)
{
    char pid[32], out[4096];
    snprintf(pid, sizeof(pid), "%d", (int)getpid());
    char* argv[] = {"pgrep", "-P", pid, NULL};
    spawn_capture(argv, out, sizeof(out)); // pgrep never lists itself
    return out[0] == 0;
}

static int is_loopback_ep(const char* ep)
{
    return strncmp(ep, "127.", 4) == 0 || strncmp(ep, "[::1]", 5) == 0 || strncmp(ep, "localhost", 9) == 0;
}

struct sockets {
    int listen_total, listen_nonloop;
    int tcp_total, tcp_external;   // connections; external = remote end not loopback
    int udp;
};

// lsof of this process's internet sockets. Prints them with the local end of
// external connections masked (it would be this machine's LAN address).
static void lsof_self(const char* label, struct sockets* s)
{
    memset(s, 0, sizeof(*s));
    char pid[32], out[65536];
    snprintf(pid, sizeof(pid), "%d", (int)getpid());
    char* argv[] = {"lsof", "-nP", "-a", "-p", pid, "-i", NULL};
    spawn_capture(argv, out, sizeof(out));
    printf("      lsof (%s):\n", label);
    char* save = NULL;
    for (char* line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (strncmp(line, "COMMAND", 7) == 0) continue;
        // ... TYPE DEVICE SIZE/OFF NODE NAME [STATE]: NODE is TCP or UDP
        char* tcp = strstr(line, " TCP ");
        char* udp = strstr(line, " UDP ");
        char* name = tcp ? tcp + 5 : udp ? udp + 5 : NULL;
        if (!name) continue;
        char shown[512];
        if (udp) {
            s->udp++;
            snprintf(shown, sizeof(shown), "UDP %s", name);
        } else if (strstr(name, "(LISTEN)")) {
            s->listen_total++;
            if (!is_loopback_ep(name)) s->listen_nonloop++;
            snprintf(shown, sizeof(shown), "TCP %s", name);
        } else {
            s->tcp_total++;
            char* arrow = strstr(name, "->");
            const char* remote = arrow ? arrow + 2 : name;
            int external = !is_loopback_ep(remote);
            if (external) s->tcp_external++;
            if (arrow && !is_loopback_ep(name)) snprintf(shown, sizeof(shown), "TCP <local>%s", arrow);
            else snprintf(shown, sizeof(shown), "TCP %s", name);
        }
        printf("        %s\n", shown);
    }
    printf("        => listening %d (not loopback %d), connections %d (to non-loopback %d), UDP %d\n",
           s->listen_total, s->listen_nonloop, s->tcp_total, s->tcp_external, s->udp);
    fflush(stdout);
}

// ---- wallet-api ------------------------------------------------------------------------
struct wapi {
    char dir[1024], db[1100], cfg[1100], acl[1100], aclKey[65];
    char a[16][1400];
    char* argv[32];
    int argc, port, rc, done, sock;
    pthread_t th;
    double started;
};

static void* wapi_thread(void* p)
{
    struct wapi* w = (struct wapi*)p;
    w->rc = beam_wallet_api_run(w->argc, w->argv);
    __atomic_store_n(&w->done, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

// Starts wallet-api as in_process_host.dart does; with proxy ("ip:port") through it.
// wait_listen: wait until it accepts (0 = return once the thread runs).
static int wapi_start(struct wapi* w, const char* pass, const char* node, const char* proxy, int wait_listen)
{
    char line[600];
    snprintf(w->cfg, sizeof(w->cfg), "%s/run.cfg", w->dir);
    snprintf(w->acl, sizeof(w->acl), "%s/run.acl", w->dir);
    snprintf(line, sizeof(line), "pass=%s\n", pass);
    write_private(w->cfg, line);
    memset(line, 0, sizeof(line));
    for (int i = 0; i < 64; i++) w->aclKey[i] = "0123456789abcdef"[arc4random_uniform(16)];
    w->aclKey[64] = 0;
    snprintf(line, sizeof(line), "%s:write\n", w->aclKey);
    write_private(w->acl, line);
    w->port = free_port();
    int n = 0;
    w->argv[n++] = "wallet-api";
    snprintf(w->a[0], sizeof(w->a[0]), "--wallet_path=%s", w->db); w->argv[n++] = w->a[0];
    snprintf(w->a[1], sizeof(w->a[1]), "--config_file=%s", w->cfg); w->argv[n++] = w->a[1];
    snprintf(w->a[2], sizeof(w->a[2]), "--node_addr=%s", node); w->argv[n++] = w->a[2];
    snprintf(w->a[3], sizeof(w->a[3]), "--port=%d", w->port); w->argv[n++] = w->a[3];
    w->argv[n++] = "--use_http=0";
    w->argv[n++] = "--tcp_max_line=16777216";
    w->argv[n++] = "--ip_whitelist=127.0.0.1";
    w->argv[n++] = "--use_acl=1";
    snprintf(w->a[4], sizeof(w->a[4]), "--acl_path=%s", w->acl); w->argv[n++] = w->a[4];
    w->argv[n++] = "--enable_assets";
    w->argv[n++] = "--enable_lelantus";
    w->argv[n++] = "--api_version=7.4";
    w->argv[n++] = "--log_level=warning";
    w->argv[n++] = "--file_log_level=warning";
    if (proxy) {
        w->argv[n++] = "--proxy=1";
        snprintf(w->a[5], sizeof(w->a[5]), "--proxy_addr=%s", proxy); w->argv[n++] = w->a[5];
    }
    w->argv[n] = NULL;
    w->argc = n;
    w->rc = 12345;
    w->done = 0;
    w->sock = -1;
    w->started = now();
    pthread_create(&w->th, NULL, wapi_thread, w);
    int ok = 0;
    if (wait_listen) {
        while (now() - w->started < 30 && !__atomic_load_n(&w->done, __ATOMIC_SEQ_CST)) {
            int s = connect_to("127.0.0.1", w->port, NULL);
            if (s >= 0) { w->sock = s; ok = 1; break; }
            usleep(150 * 1000);
        }
    } else {
        while (now() - w->started < 15 && !__atomic_load_n(&w->done, __ATOMIC_SEQ_CST)) usleep(50 * 1000);
    }
    unlink(w->cfg);
    unlink(w->acl);
    return ok;
}

static double wapi_stop(struct wapi* w)
{
    if (w->sock >= 0) { close(w->sock); w->sock = -1; }
    double t = now();
    beam_wallet_api_stop();
    pthread_join(w->th, NULL);
    return now() - t;
}

// wallet_status until in sync past HF6 and above minHeight, or max seconds.
// Returns the height.
static long long wapi_wait_sync(struct wapi* w, int maxSeconds, long long minHeight, int* synced)
{
    char resp[16384];
    double t0 = now();
    long long height = -1;
    *synced = 0;
    for (int id = 100; now() - t0 < maxSeconds; id++) {
        if (rpc(w->sock, w->aclKey, id, "wallet_status", resp, sizeof(resp)) < 0) { INFO("wallet_status: connection lost"); break; }
        height = json_int(resp, "current_height");
        int inSync = json_bool(resp, "is_in_sync");
        long long ts = json_int(resp, "current_state_timestamp");
        long long age = ts > 0 ? (long long)time(NULL) - ts : -1;
        INFO("t+%5.1fs wallet_status: current_height=%lld is_in_sync=%d tip_age=%llds", now() - t0, height, inSync, age);
        if (inSync == 1 && height > 3928666 && height > minHeight && age >= 0 && age < 900) { *synced = 1; break; }
        sleep(minHeight > 0 ? 10 : 3);
    }
    return height;
}

// ---- node --------------------------------------------------------------------------------
static const char* state_name(int s)
{
    static const char* names[] = {"IDLE", "STARTING", "RUNNING", "STOPPING", "STOPPED", "FAILED"};
    return (s >= 0 && s <= 5) ? names[s] : "?";
}

static void node_get(beam_node_status* s)
{
    memset(s, 0, sizeof(*s));
    s->size = sizeof(*s);
    beam_node_get_status(s);
}

static char g_nodeDir[1100];

static void node_print(const beam_node_status* s, double t)
{
    INFO("t+%5.1fs node %s tip=%llu best=%llu peers=%d/%d known=%d sync=%d%% (%llu/%llu) synced=%d repl=%d fast=%d target=%llu done=%d retries=%u step=%d/%d%% owners=%d db=%.1fMB%s%s",
         t, state_name(s->state), (unsigned long long)s->tip_height, (unsigned long long)s->best_peer_height,
         s->peers_connected, s->peers_with_tip, s->peers_known, s->sync_percent,
         (unsigned long long)s->sync_done, (unsigned long long)s->sync_total, s->synced, s->tx_replication_on,
         s->fast_sync_active, (unsigned long long)s->fast_sync_target, s->fast_sync_done, s->fast_sync_retries,
         s->long_step, s->long_step_percent, s->owner_accounts, dir_bytes(g_nodeDir) / 1048576.0,
         s->error ? " error=" : "", s->error ? s->error_detail : "");
}

static int node_wait_state(int want, double maxSeconds, beam_node_status* s)
{
    double t0 = now();
    while (now() - t0 < maxSeconds) {
        node_get(s);
        if (s->state == want) return 1;
        if (s->state == BEAM_NODE_STATE_FAILED && want != BEAM_NODE_STATE_FAILED) return 0;
        usleep(100 * 1000);
    }
    node_get(s);
    return s->state == want;
}

struct progress {
    int sawStarting, sawRunning;
    unsigned long long tip0, best0, done0, tipMax, bestMax, doneMax;
    int peersMax, owners, fastSeen;
};

// Polls the node for up to maxSeconds (printing every 10 s) until it has peers
// and its heights or sync work moved; returns 1 then.
static int node_watch(double maxSeconds, struct progress* p, long long maxDbBytes)
{
    memset(p, 0, sizeof(*p));
    beam_node_status s;
    double t0 = now(), lastPrint = -100;
    int first = 1, moved = 0;
    while (now() - t0 < maxSeconds) {
        node_get(&s);
        if (s.state == BEAM_NODE_STATE_STARTING) p->sawStarting = 1;
        if (s.state == BEAM_NODE_STATE_RUNNING) p->sawRunning = 1;
        if (s.state == BEAM_NODE_STATE_FAILED || s.state == BEAM_NODE_STATE_STOPPED) { node_print(&s, now() - t0); return 0; }
        if (s.state == BEAM_NODE_STATE_RUNNING) {
            if (first && s.updated_from_peers) { p->tip0 = s.tip_height; p->best0 = s.best_peer_height; p->done0 = s.sync_done; first = 0; }
            if (s.tip_height > p->tipMax) p->tipMax = s.tip_height;
            if (s.best_peer_height > p->bestMax) p->bestMax = s.best_peer_height;
            if (s.sync_done > p->doneMax) p->doneMax = s.sync_done;
            if (s.peers_connected > p->peersMax) p->peersMax = s.peers_connected;
            if (s.fast_sync_active) p->fastSeen = 1;
            p->owners = s.owner_accounts;
        }
        if (now() - t0 - lastPrint >= 10) { node_print(&s, now() - t0); lastPrint = now() - t0; }
        if (!first && p->peersMax > 0 && p->bestMax > 0 &&
            (p->tipMax > p->tip0 || p->doneMax > p->done0 + 1000 || p->bestMax > p->best0) &&
            now() - t0 > 45) { moved = 1; break; }
        if (dir_bytes(g_nodeDir) > maxDbBytes) { INFO("node storage passed %lld MB; ending this watch", maxDbBytes / 1048576); break; }
        usleep(250 * 1000);
    }
    node_get(&s);
    node_print(&s, now() - t0);
    return moved;
}

static void canary_expect_clean(int phase, const char* label, int expectLoopback)
{
    if (!canary_count) { CHECK(0, "%s: network canary not loaded (DYLD_INSERT_LIBRARIES)", label); return; }
    int lookups = 0, ext = 0, udp = 0, loop = 0;
    canary_count(phase, &lookups, &ext, &udp, &loop, 1);
    CHECK(lookups == 0, "%s: no host name was looked up (canary: %d)", label, lookups);
    CHECK(ext == 0, "%s: no connect() to anything but 127.0.0.1 (canary: %d external, %d loopback)", label, ext, loop);
    CHECK(udp == 0, "%s: no UDP datagram left the machine (canary: %d)", label, udp);
    if (expectLoopback) CHECK(loop > 0, "%s: connections went to the proxy on 127.0.0.1 (canary: %d)", label, loop);
}

// ---- wallet-api instances (beam_wallet_api_start) ----------------------------------------
struct inst {
    char name[8];
    char db[1100], cfg[1100], acl[1100], aclKey[65];
    char a[8][1400];
    char* argv[32];
    int argc, port, sock;
    int64_t handle;
    double startSecs;
};

static void inst_init(struct inst* x, const char* name, const char* dir, const char* db)
{
    memset(x, 0, sizeof(*x));
    snprintf(x->name, sizeof(x->name), "%s", name);
    snprintf(x->db, sizeof(x->db), "%s", db);
    snprintf(x->cfg, sizeof(x->cfg), "%s/inst-%s.cfg", dir, name);
    snprintf(x->acl, sizeof(x->acl), "%s/inst-%s.acl", dir, name);
    x->sock = -1;
}

// Command line as in_process_host.dart builds it; extra: one more raw argument.
static void inst_args(struct inst* x, const char* pass, const char* node, const char* proxy, int port, const char* extra)
{
    char line[600];
    snprintf(line, sizeof(line), "pass=%s\n", pass);
    write_private(x->cfg, line);
    memset(line, 0, sizeof(line));
    for (int i = 0; i < 64; i++) x->aclKey[i] = "0123456789abcdef"[arc4random_uniform(16)];
    x->aclKey[64] = 0;
    snprintf(line, sizeof(line), "%s:write\n", x->aclKey);
    write_private(x->acl, line);
    x->port = port ? port : free_port();
    int n = 0;
    x->argv[n++] = "wallet-api";
    snprintf(x->a[0], sizeof(x->a[0]), "--wallet_path=%s", x->db); x->argv[n++] = x->a[0];
    snprintf(x->a[1], sizeof(x->a[1]), "--config_file=%s", x->cfg); x->argv[n++] = x->a[1];
    snprintf(x->a[2], sizeof(x->a[2]), "--node_addr=%s", node); x->argv[n++] = x->a[2];
    snprintf(x->a[3], sizeof(x->a[3]), "--port=%d", x->port); x->argv[n++] = x->a[3];
    x->argv[n++] = "--use_http=0";
    x->argv[n++] = "--tcp_max_line=16777216";
    x->argv[n++] = "--ip_whitelist=127.0.0.1";
    x->argv[n++] = "--use_acl=1";
    snprintf(x->a[4], sizeof(x->a[4]), "--acl_path=%s", x->acl); x->argv[n++] = x->a[4];
    x->argv[n++] = "--enable_assets";
    x->argv[n++] = "--enable_lelantus";
    if (!extra || strncmp(extra, "--api_version", 13) != 0) x->argv[n++] = "--api_version=7.4";
    x->argv[n++] = "--log_level=warning";
    x->argv[n++] = "--file_log_level=warning";
    if (proxy) {
        x->argv[n++] = "--proxy=1";
        snprintf(x->a[5], sizeof(x->a[5]), "--proxy_addr=%s", proxy); x->argv[n++] = x->a[5];
    }
    if (extra) {
        snprintf(x->a[6], sizeof(x->a[6]), "%s", extra); x->argv[n++] = x->a[6];
    }
    x->argv[n] = NULL;
    x->argc = n;
}

// beam_wallet_api_start(); on success connects to it. Deletes the secret files.
static int64_t inst_start(struct inst* x)
{
    double t0 = now();
    x->handle = beam_wallet_api_start(x->argc, x->argv);
    x->startSecs = now() - t0;
    unlink(x->cfg);
    unlink(x->acl);
    if (x->handle > 0) x->sock = connect_to("127.0.0.1", x->port, NULL);
    return x->handle;
}

static void* inst_start_thread(void* p) { inst_start((struct inst*)p); return NULL; }

// Asks it to stop and waits for STOPPED / FAILED. Returns the state; seconds in *secs.
static int inst_stop_wait(struct inst* x, double maxSeconds, int* exitStatus, double* secs)
{
    if (x->sock >= 0) { close(x->sock); x->sock = -1; }
    double t0 = now();
    beam_wallet_api_stop_instance(x->handle);
    int st = BEAM_WALLET_API_INSTANCE_UNKNOWN, es = -999;
    while (now() - t0 < maxSeconds) {
        st = beam_wallet_api_instance_state(x->handle, &es);
        if (st == BEAM_WALLET_API_INSTANCE_STOPPED || st == BEAM_WALLET_API_INSTANCE_FAILED) break;
        usleep(20 * 1000);
    }
    if (exitStatus) *exitStatus = es;
    if (secs) *secs = now() - t0;
    return st;
}

// wallet_status of an instance: height, in sync, tip age. -1 if it does not answer.
static long long inst_status(struct inst* x, int* inSync, long long* age)
{
    static int id = 1000;
    char resp[16384];
    *inSync = -1; *age = -1;
    if (x->sock < 0 || rpc(x->sock, x->aclKey, id++, "wallet_status", resp, sizeof(resp)) < 0) return -1;
    long long h = json_int(resp, "current_height");
    *inSync = json_bool(resp, "is_in_sync");
    long long ts = json_int(resp, "current_state_timestamp");
    *age = ts > 0 ? (long long)time(NULL) - ts : -1;
    return h;
}

// Polls the instances until each is in sync above minHeight (and past HF6).
static int insts_wait_sync(struct inst** xs, int n, long long minHeight, int maxSeconds, long long* heights)
{
    double t0 = now(), lastPrint = -100;
    int done = 0;
    while (now() - t0 < maxSeconds) {
        done = 1;
        char line[512] = "";
        for (int i = 0; i < n; i++) {
            int ins; long long age;
            long long h = inst_status(xs[i], &ins, &age);
            heights[i] = h;
            if (!(ins == 1 && h > 3928666 && h > minHeight && age >= 0 && age < 900)) done = 0;
            char part[96];
            snprintf(part, sizeof(part), "%s%s: height=%lld in_sync=%d age=%llds", i ? ", " : "", xs[i]->name, h, ins, age);
            strncat(line, part, sizeof(line) - strlen(line) - 1);
        }
        if (done || now() - t0 - lastPrint >= 10) { INFO("t+%5.1fs %s", now() - t0, line); lastPrint = now() - t0; }
        if (done) break;
        sleep(2);
    }
    return done;
}

// ---- main -------------------------------------------------------------------------------
int main(int argc, char** argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN);
    if (argc != 9) {
        fprintf(stderr, "usage: %s <workdir> <direct wallet node> <direct peers> <socks port|0> <tor wallet node|-> <tor peers|-> <lan ip|-> <node seconds>\n", argv[0]);
        return 2;
    }
    const char* dir = argv[1];
    const char* directNode = argv[2];
    const char* directPeers = argv[3];
    int socksPort = atoi(argv[4]);
    const char* torNode = argv[5];
    const char* torPeers = argv[6];
    const char* lanIp = argv[7];
    int nodeSeconds = atoi(argv[8]);
    double tMain = now();

    canary_set_phase = (void (*)(int))dlsym(RTLD_DEFAULT, "net_canary_set_phase");
    canary_count = (void (*)(int, int*, int*, int*, int*, int))dlsym(RTLD_DEFAULT, "net_canary_count");
    canary_looked_up = (int (*)(const char*))dlsym(RTLD_DEFAULT, "net_canary_looked_up");
    INFO("network canary %s", canary_count ? "loaded" : "NOT loaded");

    // ---------------------------------------------------------------- 1 basic
    canary_phase(1);
    printf("== 1. basic\n");
    char logDir[1100];
    snprintf(logDir, sizeof(logDir), "%s/logs", dir);
    int rc = beam_core_init(logDir, BEAM_LOG_LEVEL_WARNING, BEAM_LOG_LEVEL_INFO);
    CHECK(rc == BEAM_CORE_OK, "beam_core_init(logs, console warning, file info) -> %d", rc);
    rc = beam_core_init(logDir, BEAM_LOG_LEVEL_INFO, BEAM_LOG_LEVEL_INFO);
    CHECK(rc == BEAM_CORE_ALREADY_INITIALIZED, "beam_core_init again -> %d (ALREADY_INITIALIZED)", rc);
    struct stat st;
    CHECK(stat(logDir, &st) == 0 && (st.st_mode & 0777) == 0700, "log directory created 0700 (mode %o)", st.st_mode & 0777);

    const char* v = beam_wallet_api_version();
    INFO("version: %s", v);
    CHECK(strncmp(v, "7.5.14493 ", 10) == 0, "version is 7.5.14493");
    const char* rules = beam_wallet_api_rules_signature();
    INFO("rules signature: %s", rules);
    CHECK(strstr(rules, "network=mainnet") && strstr(rules, "3928666-96df3f33ee02ad9e"), "rules are mainnet with HF6 (3928666-96df3f33ee02ad9e)");
    {
        char* vargv[] = {"wallet-api", "--version", NULL};
        rc = beam_wallet_api_run(2, vargv);
        CHECK(rc == 0, "beam_wallet_api_run(--version) -> %d", rc);
    }

    char path[1100];
    snprintf(path, sizeof(path), "%s/phrase.txt", dir);
    char* phrase = read_secret(path);
    unlink(path);
    snprintf(path, sizeof(path), "%s/pass.txt", dir);
    char* pass = read_secret(path);
    unlink(path);
    if (!phrase || !pass) { printf("FAIL  phrase.txt / pass.txt missing\n"); return 1; }

    char* phrase2 = NULL;
    char* phrase3 = NULL;
    snprintf(path, sizeof(path), "%s/phrase2.txt", dir);
    phrase2 = read_secret(path);
    unlink(path);
    snprintf(path, sizeof(path), "%s/phrase3.txt", dir);
    phrase3 = read_secret(path);
    unlink(path);

    struct wapi w;
    memset(&w, 0, sizeof(w));
    snprintf(w.dir, sizeof(w.dir), "%s", dir);
    snprintf(w.db, sizeof(w.db), "%s/wallet.db", dir);
    double t0 = now();
    rc = beam_wallet_api_init_wallet(w.db, pass, phrase);
    CHECK(rc == BEAM_WALLET_OK, "init_wallet(12 generated BIP39 words) -> %d (%.2f s)", rc, now() - t0);
    rc = beam_wallet_api_init_wallet(w.db, pass, phrase);
    CHECK(rc == BEAM_WALLET_EXISTS, "init_wallet again -> %d (EXISTS)", rc);
    memset(phrase, 0, strlen(phrase));
    free(phrase);
    char db2[1100], db3[1100];
    snprintf(db2, sizeof(db2), "%s/wallet2.db", dir);
    snprintf(db3, sizeof(db3), "%s/wallet3.db", dir);
    if (phrase2 && phrase3) {
        rc = beam_wallet_api_init_wallet(db2, pass, phrase2);
        int rc3 = beam_wallet_api_init_wallet(db3, pass, phrase3);
        CHECK(rc == BEAM_WALLET_OK && rc3 == BEAM_WALLET_OK, "two more throwaway wallets (own BIP39 phrases) -> %d, %d", rc, rc3);
        memset(phrase2, 0, strlen(phrase2));
        memset(phrase3, 0, strlen(phrase3));
    } else {
        CHECK(0, "phrase2.txt / phrase3.txt missing");
    }
    free(phrase2);
    free(phrase3);
    snprintf(path, sizeof(path), "%s/other.db", dir);
    rc = beam_wallet_api_init_wallet(path, pass, "not a phrase");
    CHECK(rc == BEAM_WALLET_INVALID_PHRASE, "init_wallet(bad phrase) -> %d (INVALID_PHRASE)", rc);
    rc = beam_wallet_api_check_wallet(w.db, "definitely-not-the-password");
    CHECK(rc == BEAM_WALLET_WRONG_PASSWORD, "check_wallet(wrong password) -> %d (WRONG_PASSWORD)", rc);
    rc = beam_wallet_api_check_wallet(w.db, pass);
    CHECK(rc == BEAM_WALLET_OK, "check_wallet(right password) -> %d", rc);
    rc = beam_wallet_api_check_wallet(path, pass);
    CHECK(rc == BEAM_WALLET_NOT_FOUND, "check_wallet(no wallet) -> %d (NOT_FOUND)", rc);

    char ownerKey[512], tiny[8];
    rc = beam_wallet_api_export_owner_key(w.db, "definitely-not-the-password", ownerKey, sizeof(ownerKey));
    CHECK(rc == BEAM_WALLET_WRONG_PASSWORD && ownerKey[0] == 0, "export_owner_key(wrong password) -> %d (WRONG_PASSWORD), out empty", rc);
    rc = beam_wallet_api_export_owner_key(path, pass, ownerKey, sizeof(ownerKey));
    CHECK(rc == BEAM_WALLET_NOT_FOUND, "export_owner_key(no wallet) -> %d (NOT_FOUND)", rc);
    rc = beam_wallet_api_export_owner_key(w.db, pass, tiny, sizeof(tiny));
    CHECK(rc == BEAM_WALLET_FAILED && tiny[0] == 0, "export_owner_key(8-byte buffer) -> %d (FAILED), out empty", rc);
    t0 = now();
    rc = beam_wallet_api_export_owner_key(w.db, pass, ownerKey, sizeof(ownerKey));
    size_t keyLen = strlen(ownerKey);
    CHECK(rc == BEAM_WALLET_OK && keyLen > 40, "export_owner_key -> %d, a %zu-character key (%.2f s; not printed)", rc, keyLen, now() - t0);
    char ownerKey2[512];
    beam_wallet_api_export_owner_key(w.db, pass, ownerKey2, sizeof(ownerKey2));

    snprintf(g_nodeDir, sizeof(g_nodeDir), "%s/node", dir);
    mkdir(g_nodeDir, 0700);
    char nodeDb[1200];
    snprintf(nodeDb, sizeof(nodeDb), "%s/node.db", g_nodeDir);

    // Argument checks of beam_node_start (nothing starts).
    rc = beam_node_start(nodeDb, 0, directPeers, ownerKey, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_INVALID_ARGUMENT, "node_start(port 0) -> %d (INVALID_ARGUMENT)", rc);
    rc = beam_node_start(nodeDb, 10005, "", ownerKey, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_INVALID_ARGUMENT, "node_start(no peers) -> %d (INVALID_ARGUMENT)", rc);
    t0 = now();
    rc = beam_node_start(nodeDb, 10005, directPeers, ownerKey, "definitely-not-the-password", -1, NULL);
    CHECK(rc == BEAM_NODE_BAD_OWNER_KEY, "node_start(owner key, wrong password) -> %d (BAD_OWNER_KEY, %.2f s)", rc, now() - t0);
    rc = beam_node_start(nodeDb, 10005, directPeers, "bm90IGEga2V5", pass, -1, NULL);
    CHECK(rc == BEAM_NODE_BAD_OWNER_KEY, "node_start(garbage key) -> %d (BAD_OWNER_KEY)", rc);
    rc = beam_node_start(nodeDb, 10005, directPeers, "", pass, -1, NULL);
    CHECK(rc == BEAM_NODE_BAD_OWNER_KEY, "node_start(no key) -> %d (BAD_OWNER_KEY: a keyless node is never started)", rc);
    beam_node_status s;
    node_get(&s);
    CHECK(s.state == BEAM_NODE_STATE_IDLE && s.version == BEAM_NODE_STATUS_VERSION, "status: IDLE, version %u, size %u", s.version, s.size);
    beam_node_stop(); // no-op

    // ---------------------------------------------------------------- 2 direct
    canary_phase(2);
    printf("== 2. direct: wallet-api and the node in this process, no proxy\n");
    int ok = wapi_start(&w, pass, directNode, NULL, 1);
    CHECK(ok, "wallet-api listening on 127.0.0.1:%d after %.2f s (node %s)", w.port, now() - w.started, directNode);
    if (!ok) { INFO("run() returned %d", w.rc); return 1; }
    CHECK(beam_wallet_api_is_running() == 1, "is_running() == 1");
    char resp[16384];
    {
        int s2 = connect_to("127.0.0.1", w.port, NULL);
        rpc(s2, "not-the-key", 1, "get_version", resp, sizeof(resp));
        close(s2);
        CHECK(strstr(resp, "\"error\"") != NULL, "a request with a wrong ACL key is refused: %.100s", resp);
    }
    rpc(w.sock, w.aclKey, 2, "get_version", resp, sizeof(resp));
    CHECK(strstr(resp, "7.5.14493") && (strstr(resp, "\"api_version\":\"7.4\"") || strstr(resp, "\"api_version\": \"7.4\"")), "get_version: %.160s", resp);
    int synced = 0;
    long long h = wapi_wait_sync(&w, 120, 0, &synced);
    CHECK(synced, "wallet_status: in sync past HF6 (height %lld)", h);

    struct sockets sk;
    lsof_self("wallet-api running", &sk);
    CHECK(sk.listen_total >= 1 && sk.listen_nonloop == 0, "wallet-api listens on 127.0.0.1 only (%d listening, %d elsewhere)", sk.listen_total, sk.listen_nonloop);
    if (strcmp(lanIp, "-") != 0) {
        int err = 0;
        int s3 = connect_to(lanIp, w.port, &err);
        if (s3 >= 0) close(s3);
        CHECK(s3 < 0 && err == ECONNREFUSED, "a connection to the LAN address <lan>:%d is refused (%s)", w.port, s3 < 0 ? strerror(err) : "accepted!");
    } else {
        INFO("SKIP  no LAN address on this machine; LAN refusal not checked");
    }

    // Port in use: the node fails with PORT_IN_USE and nothing stays running.
    int busyPort = 0, busy = hold_port(&busyPort);
    rc = beam_node_start(nodeDb, busyPort, directPeers, ownerKey, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_OK, "node_start on a port this process already listens on -> %d", rc);
    int failed = node_wait_state(BEAM_NODE_STATE_FAILED, 60, &s);
    CHECK(failed && s.error == BEAM_NODE_ERR_PORT_IN_USE, "status FAILED, error %d (PORT_IN_USE): \"%s\"", s.error, s.error_detail);
    close(busy);

    int nodePort = free_port();
    t0 = now();
    rc = beam_node_start(nodeDb, nodePort, directPeers, ownerKey, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_OK, "node_start(127.0.0.1:%d, peers %s, owner key) -> %d (%.2f s)", nodePort, directPeers, rc, now() - t0);
    rc = beam_node_start(nodeDb, nodePort, directPeers, ownerKey, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_ALREADY_RUNNING, "node_start again -> %d (ALREADY_RUNNING)", rc);
    struct progress pr;
    int moved = node_watch(nodeSeconds, &pr, 1200ll * 1048576);
    CHECK(pr.sawRunning, "node state went %sRUNNING", pr.sawStarting ? "STARTING -> " : "");
    CHECK(pr.peersMax > 0 && pr.bestMax > 0, "node connected to peers (max %d) that announced tip %llu", pr.peersMax, pr.bestMax);
    CHECK(moved, "node heights / sync work moved (tip %llu -> %llu, best %llu -> %llu, sync work %llu -> %llu, fast sync seen %d)",
          pr.tip0, pr.tipMax, pr.best0, pr.bestMax, pr.done0, pr.doneMax, pr.fastSeen);
    CHECK(pr.owners == 1, "node holds the owner key: %d owned account", pr.owners);
    lsof_self("wallet-api + node running", &sk);
    CHECK(sk.listen_total >= 2 && sk.listen_nonloop == 0, "wallet-api and node listen on 127.0.0.1 only (%d listening, %d elsewhere)", sk.listen_total, sk.listen_nonloop);
    CHECK(sk.udp == 0, "no UDP socket (LAN beacon off): %d", sk.udp);
    if (strcmp(lanIp, "-") != 0) {
        int err = 0;
        int s3 = connect_to(lanIp, nodePort, &err);
        if (s3 >= 0) close(s3);
        CHECK(s3 < 0 && err == ECONNREFUSED, "a connection to the node port on the LAN address is refused (%s)", s3 < 0 ? strerror(err) : "accepted!");
    }
    CHECK(no_children(), "no child process (pgrep -P %d is empty)", (int)getpid());
    if (canary_count) {
        int l = 0, c = 0, u = 0, lc = 0;
        canary_count(2, &l, &c, &u, &lc, 0);
        INFO("canary, direct phase: %d name lookups, %d external connects, %d external UDP (expected: direct mode)", l, c, u);
        CHECK(u == 0, "direct: no UDP broadcast / datagram left the machine (canary: %d)", u);
    }

    // Stop the node while wallet-api keeps running.
    t0 = now();
    beam_node_stop();
    node_get(&s);
    CHECK(s.state == BEAM_NODE_STATE_STOPPING || s.state == BEAM_NODE_STATE_STOPPED, "node_stop() returns at once (%.3f s), state %s", now() - t0, state_name(s.state));
    ok = node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
    CHECK(ok, "node STOPPED after %.2f s", now() - t0);
    rc = rpc(w.sock, w.aclKey, 50, "wallet_status", resp, sizeof(resp));
    CHECK(rc > 0 && json_int(resp, "current_height") > 3928666, "wallet-api still answers with the node stopped (height %lld)", json_int(resp, "current_height"));

    // Restart the node on the same storage.
    nodePort = free_port();
    rc = beam_node_start(nodeDb, nodePort, directPeers, ownerKey2, pass, -1, NULL);
    CHECK(rc == BEAM_NODE_OK, "node restart -> %d", rc);
    ok = node_wait_state(BEAM_NODE_STATE_RUNNING, 60, &s);
    CHECK(ok && s.has_initial_tip, "restarted node RUNNING, initial tip %llu, owners %d", (unsigned long long)s.initial_tip_height, s.owner_accounts);
    {
        double tw = now();
        while (now() - tw < 30) { node_get(&s); if (s.peers_connected > 0 && s.best_peer_height > 0) break; usleep(250 * 1000); }
        node_print(&s, now() - tw);
        CHECK(s.peers_connected > 0, "restarted node has peers (%d)", s.peers_connected);
    }

    // Stop both.
    t0 = now();
    beam_node_stop();
    double wstop = wapi_stop(&w);
    CHECK(w.rc == 0, "wallet-api stopped while the node stops: run() returned %d after %.2f s", w.rc, wstop);
    ok = node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
    CHECK(ok && now() - t0 < 30, "both stopped after %.2f s", now() - t0);
    CHECK(beam_wallet_api_is_running() == 0, "is_running() == 0");
    rc = beam_wallet_api_check_wallet(w.db, pass);
    CHECK(rc == BEAM_WALLET_OK, "wallet.db opens again (closed cleanly) -> %d", rc);

    // ---------------------------------------------------------------- 3 tor
    char socks[64];
    snprintf(socks, sizeof(socks), "127.0.0.1:%d", socksPort);
    if (socksPort > 0 && strcmp(torNode, "-") != 0) {
        canary_phase(3);
        printf("== 3. tor: every connection through the SOCKS5 proxy %s\n", socks);
        ok = wapi_start(&w, pass, torNode, socks, 1);
        CHECK(ok, "wallet-api --proxy=1 --proxy_addr=%s --node_addr=%s listening after %.2f s", socks, torNode, now() - w.started);
        if (ok) {
            // Its database already holds the tip of phase 2; a NEW block proves the
            // node connection through Tor works (blocks come about once a minute).
            long long h0 = h;
            h = wapi_wait_sync(&w, 300, h0, &synced);
            CHECK(synced, "wallet_status via Tor: a new block arrived (height %lld -> %lld), in sync", h0, h);
        }
        nodePort = free_port();
        rc = beam_node_start(nodeDb, nodePort, torPeers, ownerKey, pass, -1, socks);
        CHECK(rc == BEAM_NODE_OK, "node_start(peers %s, socks5 %s) -> %d", torPeers, socks, rc);
        node_get(&s);
        CHECK(s.via_proxy == 1, "status.via_proxy == 1");
        moved = node_watch(nodeSeconds, &pr, 1500ll * 1048576);
        CHECK(pr.peersMax > 0 && pr.bestMax > 0, "node via Tor connected to peers (max %d), best tip %llu", pr.peersMax, pr.bestMax);
        CHECK(moved, "node via Tor: heights / sync work moved (tip %llu -> %llu, best %llu -> %llu, sync work %llu -> %llu)",
              pr.tip0, pr.tipMax, pr.best0, pr.bestMax, pr.done0, pr.doneMax);
        lsof_self("tor: wallet-api + node running", &sk);
        CHECK(sk.tcp_external == 0, "lsof: no TCP connection to anything but 127.0.0.1 (%d of %d)", sk.tcp_external, sk.tcp_total);
        CHECK(sk.listen_nonloop == 0 && sk.udp == 0, "lsof: listening on loopback only, no UDP (%d, %d)", sk.listen_nonloop, sk.udp);
        CHECK(no_children(), "no child process");
        t0 = now();
        beam_node_stop();
        wapi_stop(&w);
        ok = node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
        CHECK(ok && w.rc == 0, "tor: both stopped after %.2f s (run() %d)", now() - t0, w.rc);
        canary_expect_clean(3, "tor", 1);
    } else {
        printf("SKIP  3. tor: no Tor SOCKS port given\n");
    }

    // ---------------------------------------------------------------- 4 dead proxy
    {
        canary_phase(4);
        int deadPort = free_port(); // bound once, now closed: nothing listens
        char dead[64];
        snprintf(dead, sizeof(dead), "127.0.0.1:%d", deadPort);
        const char* ipNode = strcmp(torNode, "-") != 0 ? torNode : "188.245.67.33:8100";
        const char* ipPeers = strcmp(torPeers, "-") != 0 ? torPeers : "188.245.67.32:8100";
        printf("== 4. dead proxy: %s accepts nothing; nothing may go anywhere else\n", dead);
        ok = wapi_start(&w, pass, ipNode, dead, 1);
        CHECK(ok, "wallet-api --proxy_addr=%s (dead) still starts and listens", dead);
        nodePort = free_port();
        rc = beam_node_start(nodeDb, nodePort, ipPeers, ownerKey, pass, -1, dead);
        CHECK(rc == BEAM_NODE_OK, "node_start(socks5 %s, dead) -> %d", dead, rc);
        double tw = now();
        int peersMax = 0;
        while (now() - tw < 30) {
            node_get(&s);
            if (s.peers_connected > peersMax) peersMax = s.peers_connected;
            usleep(500 * 1000);
        }
        node_print(&s, now() - tw);
        if (ok) {
            rpc(w.sock, w.aclKey, 60, "wallet_status", resp, sizeof(resp));
            INFO("wallet_status with the proxy dead: current_height=%lld is_in_sync=%d (from its database)",
                 json_int(resp, "current_height"), json_bool(resp, "is_in_sync"));
        }
        CHECK(peersMax == 0, "node behind the dead proxy has no peer in 30 s (max %d)", peersMax);
        lsof_self("dead proxy: wallet-api + node running", &sk);
        CHECK(sk.tcp_external == 0, "lsof: no TCP connection to anything but 127.0.0.1 (%d)", sk.tcp_external);
        beam_node_stop();
        wapi_stop(&w);
        node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
        canary_expect_clean(4, "dead proxy", 1);
    }

    // ---------------------------------------------------------------- 5 names behind a proxy
    {
        canary_phase(5);
        char canaryName[128], canaryNode[160], canaryName2[128], canaryNode2[160];
        snprintf(canaryName, sizeof(canaryName), "dns-canary-%08x.invalid", arc4random());
        snprintf(canaryNode, sizeof(canaryNode), "%s:8100", canaryName);
        printf("== 5. a host name behind a proxy is refused, never looked up (%s)\n", canaryName);
        const char* proxy = socksPort > 0 ? socks : "127.0.0.1:9";
        ok = wapi_start(&w, pass, canaryNode, proxy, 0);
        double tj = now();
        while (!__atomic_load_n(&w.done, __ATOMIC_SEQ_CST) && now() - tj < 10) usleep(50 * 1000);
        int finished = __atomic_load_n(&w.done, __ATOMIC_SEQ_CST);
        if (!finished) beam_wallet_api_stop();
        pthread_join(w.th, NULL);
        CHECK(finished && w.rc == -1, "wallet-api --proxy=1 --node_addr=%s: run() returned %d at once, without listening", canaryNode, w.rc);
        rc = beam_node_start(nodeDb, free_port(), canaryNode, ownerKey, pass, -1, proxy);
        CHECK(rc == BEAM_NODE_HOSTNAME_REFUSED, "node_start(peer %s, proxy) -> %d (HOSTNAME_REFUSED)", canaryNode, rc);
        char mixed[400];
        snprintf(mixed, sizeof(mixed), "188.245.67.32:8100,%s", canaryNode);
        rc = beam_node_start(nodeDb, free_port(), mixed, ownerKey, pass, -1, proxy);
        CHECK(rc == BEAM_NODE_HOSTNAME_REFUSED, "node_start(an IP and a host name, proxy) -> %d (HOSTNAME_REFUSED)", rc);
        rc = beam_node_start(nodeDb, free_port(), "188.245.67.32:8100", ownerKey, pass, -1, "localhost:9050");
        CHECK(rc == BEAM_NODE_INVALID_ARGUMENT, "node_start(proxy given as a host name) -> %d (INVALID_ARGUMENT)", rc);
        ok = wapi_start(&w, pass, "188.245.67.33:8100", "localhost:9050", 0);
        tj = now();
        while (!__atomic_load_n(&w.done, __ATOMIC_SEQ_CST) && now() - tj < 10) usleep(50 * 1000);
        finished = __atomic_load_n(&w.done, __ATOMIC_SEQ_CST);
        if (!finished) beam_wallet_api_stop();
        pthread_join(w.th, NULL);
        CHECK(finished && w.rc == -1, "wallet-api --proxy_addr=localhost:9050: run() returned %d", w.rc);
        if (canary_looked_up) {
            CHECK(!canary_looked_up(canaryName), "canary: %s was never looked up", canaryName);
            CHECK(!canary_looked_up("localhost"), "canary: localhost was never looked up");
        }
        canary_expect_clean(5, "names behind a proxy", 0);

        // 6 control: without a proxy the same kind of name IS looked up, so the
        // canary sees lookups when they happen.
        canary_phase(6);
        snprintf(canaryName2, sizeof(canaryName2), "dns-canary-%08x.invalid", arc4random());
        snprintf(canaryNode2, sizeof(canaryNode2), "%s:8100", canaryName2);
        printf("== 6. control: without a proxy the name is looked up (%s)\n", canaryName2);
        ok = wapi_start(&w, pass, canaryNode2, NULL, 0);
        tj = now();
        while (!__atomic_load_n(&w.done, __ATOMIC_SEQ_CST) && now() - tj < 15) usleep(50 * 1000);
        finished = __atomic_load_n(&w.done, __ATOMIC_SEQ_CST);
        if (!finished) beam_wallet_api_stop();
        pthread_join(w.th, NULL);
        CHECK(finished && w.rc == -1, "wallet-api --node_addr=%s (no proxy): run() returned %d (unable to resolve)", canaryNode2, w.rc);
        if (canary_looked_up)
            CHECK(canary_looked_up(canaryName2), "canary: %s WAS looked up without a proxy (the canary sees lookups)", canaryName2);
    }

    // ---------------------------------------------------------------- 7 multi
    {
        canary_phase(7);
        printf("== 7. multi: three wallets as concurrent wallet-api instances + the node\n");
        struct inst A, B, C, X;
        inst_init(&A, "A", dir, w.db);
        inst_init(&B, "B", dir, db2);
        inst_init(&C, "C", dir, db3);
        inst_args(&A, pass, directNode, NULL, 0, NULL);
        inst_args(&B, pass, directNode, NULL, 0, NULL);
        inst_args(&C, pass, directNode, NULL, 0, NULL);
        pthread_t ta, tb, tc;
        double t0m = now();
        pthread_create(&ta, NULL, inst_start_thread, &A);
        pthread_create(&tb, NULL, inst_start_thread, &B);
        pthread_create(&tc, NULL, inst_start_thread, &C);
        pthread_join(ta, NULL); pthread_join(tb, NULL); pthread_join(tc, NULL);
        CHECK(A.handle > 0 && B.handle > 0 && C.handle > 0 && A.handle != B.handle && B.handle != C.handle && A.handle != C.handle,
              "3 instances started at once from 3 threads: handles %lld, %lld, %lld (%.2f / %.2f / %.2f s; all in %.2f s)",
              (long long)A.handle, (long long)B.handle, (long long)C.handle, A.startSecs, B.startSecs, C.startSecs, now() - t0m);
        CHECK(A.sock >= 0 && B.sock >= 0 && C.sock >= 0, "each listens on its own port (%d, %d, %d)", A.port, B.port, C.port);
        CHECK(beam_wallet_api_instance_count() == 3, "instance_count() == %d", beam_wallet_api_instance_count());
        int es = 0;
        CHECK(beam_wallet_api_instance_state(A.handle, &es) == BEAM_WALLET_API_INSTANCE_RUNNING, "state(A) == RUNNING");
        CHECK(beam_wallet_api_instance_state(987654, &es) == BEAM_WALLET_API_INSTANCE_UNKNOWN, "state(unknown handle) == UNKNOWN");
        struct inst* all[3] = {&A, &B, &C};
        long long hs[3];
        int ok3 = insts_wait_sync(all, 3, 0, 120, hs);
        CHECK(ok3, "A, B, C all answer wallet_status in sync (heights %lld, %lld, %lld)", hs[0], hs[1], hs[2]);

        nodePort = free_port();
        rc = beam_node_start(nodeDb, nodePort, directPeers, ownerKey, pass, -1, NULL);
        CHECK(rc == BEAM_NODE_OK, "the node starts next to the three instances -> %d", rc);
        ok = node_wait_state(BEAM_NODE_STATE_RUNNING, 60, &s);
        {
            double tw = now();
            while (now() - tw < 30) { node_get(&s); if (s.peers_connected > 0) break; usleep(250 * 1000); }
            node_print(&s, now() - tw);
        }
        CHECK(ok && s.peers_connected > 0, "node RUNNING with %d peers while A, B, C run", s.peers_connected);
        lsof_self("A, B, C + node", &sk);
        CHECK(sk.listen_total == 4 && sk.listen_nonloop == 0, "4 listening sockets, all on 127.0.0.1 (%d, %d elsewhere)", sk.listen_total, sk.listen_nonloop);

        // Stop the middle one; the others keep answering.
        double secs = 0;
        int st = inst_stop_wait(&B, 30, &es, &secs);
        CHECK(st == BEAM_WALLET_API_INSTANCE_STOPPED && es == 0, "stop_instance(B): STOPPED, exit status %d, after %.2f s", es, secs);
        CHECK(beam_wallet_api_instance_count() == 2, "instance_count() == %d", beam_wallet_api_instance_count());
        {
            int i1, i2; long long a1, a2;
            long long ha = inst_status(&A, &i1, &a1), hc = inst_status(&C, &i2, &a2);
            CHECK(ha > 3928666 && hc > 3928666 && i1 == 1 && i2 == 1, "A and C still answer, in sync (%lld, %lld)", ha, hc);
        }
        rc = beam_wallet_api_check_wallet(B.db, pass);
        CHECK(rc == BEAM_WALLET_OK, "wallet2.db closed cleanly by B's stop (check_wallet -> %d)", rc);

        // Start it again.
        inst_args(&B, pass, directNode, NULL, 0, NULL);
        inst_start(&B);
        CHECK(B.handle > 0, "B started again: handle %lld (%.2f s)", (long long)B.handle, B.startSecs);
        struct inst* oneB[1] = {&B};
        long long hb;
        CHECK(insts_wait_sync(oneB, 1, 0, 60, &hb), "B in sync again (height %lld)", hb);

        // Stress: 20 start/stop cycles of B while A, C (and the node) run.
        {
            int okCycles = 0, othersOk = 1;
            double tmax = 0, tsum = 0, smax = 0;
            int s2 = inst_stop_wait(&B, 30, &es, &secs);
            if (s2 != BEAM_WALLET_API_INSTANCE_STOPPED) othersOk = 0;
            double ts0 = now();
            for (int i = 0; i < 20; i++) {
                inst_args(&B, pass, directNode, NULL, 0, NULL);
                inst_start(&B);
                char resp2[4096];
                int good = B.handle > 0 && B.sock >= 0 && rpc(B.sock, B.aclKey, 5000 + i, "get_version", resp2, sizeof(resp2)) > 0 && strstr(resp2, "7.5.14493");
                if (B.startSecs > tmax) tmax = B.startSecs;
                tsum += B.startSecs;
                st = inst_stop_wait(&B, 30, &es, &secs);
                if (secs > smax) smax = secs;
                if (good && st == BEAM_WALLET_API_INSTANCE_STOPPED && es == 0) okCycles++;
                int i1, i2; long long a1, a2;
                if (inst_status(&A, &i1, &a1) <= 3928666 || inst_status(&C, &i2, &a2) <= 3928666) othersOk = 0;
            }
            CHECK(okCycles == 20, "20 x (start B, get_version, stop B): %d clean cycles in %.1f s (start avg %.3f s, max %.3f s; stop max %.3f s)",
                  okCycles, now() - ts0, tsum / 20, tmax, smax);
            CHECK(othersOk, "A and C answered wallet_status after every cycle");
            CHECK(beam_wallet_api_instance_count() == 2, "instance_count() == %d after the loop (A, C)", beam_wallet_api_instance_count());
            node_get(&s);
            CHECK(s.state == BEAM_NODE_STATE_RUNNING, "node still RUNNING (%s, %d peers)", state_name(s.state), s.peers_connected);
        }

        // Error paths of beam_wallet_api_start().
        {
            int busyPort2 = 0, busy2 = hold_port(&busyPort2);
            inst_init(&X, "X", dir, db2);
            inst_args(&X, pass, directNode, NULL, busyPort2, NULL);
            inst_start(&X);
            CHECK(X.handle == BEAM_WALLET_API_START_NO_LISTEN, "start on a port in use -> %lld (NO_LISTEN)", (long long)X.handle);
            {
                // The tracked start names the instance even when it fails, so the
                // caller can wait for it to let go of wallet.db.
                int64_t tracked = 0;
                inst_args(&X, pass, directNode, NULL, busyPort2, NULL);
                int64_t trc = beam_wallet_api_start_tracked(X.argc, X.argv, &tracked);
                unlink(X.cfg);
                unlink(X.acl);
                CHECK(trc == BEAM_WALLET_API_START_NO_LISTEN && tracked > 0,
                      "start_tracked on a port in use -> %lld, instance %lld", (long long)trc, (long long)tracked);
                int tes = 0, tst = BEAM_WALLET_API_INSTANCE_UNKNOWN;
                for (int i = 0; i < 300; i++)
                {
                    tst = beam_wallet_api_instance_state(tracked, &tes);
                    if (tst == BEAM_WALLET_API_INSTANCE_STOPPED || tst == BEAM_WALLET_API_INSTANCE_FAILED)
                        break;
                    usleep(100 * 1000);
                }
                CHECK(tst == BEAM_WALLET_API_INSTANCE_STOPPED || tst == BEAM_WALLET_API_INSTANCE_FAILED,
                      "that instance ends (state %d)", tst);
                int64_t none = -7;
                CHECK(beam_wallet_api_start_tracked(0, NULL, &none) == BEAM_WALLET_API_START_FAILED && none == 0,
                      "start_tracked with no arguments -> START_FAILED, instance 0");
            }
            close(busy2);
            inst_args(&X, "definitely-not-the-password", directNode, NULL, 0, NULL);
            inst_start(&X);
            CHECK(X.handle == BEAM_WALLET_API_START_FAILED, "start with a wrong password -> %lld (START_FAILED)", (long long)X.handle);
            inst_args(&X, pass, directNode, NULL, 0, "--version");
            inst_start(&X);
            CHECK(X.handle == BEAM_WALLET_API_START_NOT_SERVING, "start --version -> %lld (NOT_SERVING)", (long long)X.handle);
            inst_args(&X, pass, directNode, NULL, 0, "--api_version=9.9");
            inst_start(&X);
            CHECK(X.handle == BEAM_WALLET_API_START_BAD_API_VERSION, "start --api_version=9.9 -> %lld (BAD_API_VERSION)", (long long)X.handle);
            inst_args(&X, pass, "dns-canary-instance.invalid:8100", "127.0.0.1:9", 0, NULL);
            inst_start(&X);
            CHECK(X.handle == BEAM_WALLET_API_START_FAILED, "start --proxy=1 with a host name -> %lld (START_FAILED)", (long long)X.handle);
            if (canary_looked_up) CHECK(!canary_looked_up("dns-canary-instance.invalid"), "canary: that host name was never looked up");
            CHECK(beam_wallet_api_instance_count() == 2, "instance_count() == %d after the failed starts", beam_wallet_api_instance_count());
        }

        // The single run() interface still works next to the instances.
        {
            char* vargv[] = {"wallet-api", "--version", NULL};
            rc = beam_wallet_api_run(2, vargv);
            CHECK(rc == 0 && beam_wallet_api_is_running() == 0, "beam_wallet_api_run(--version) next to the instances -> %d", rc);
        }

        // Stop everything.
        double tstop = now();
        beam_node_stop();
        beam_wallet_api_stop_instance(A.handle);
        beam_wallet_api_stop_instance(C.handle);
        int sa = inst_stop_wait(&A, 30, &es, &secs);
        int sc = inst_stop_wait(&C, 30, NULL, NULL);
        ok = node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
        CHECK(sa == BEAM_WALLET_API_INSTANCE_STOPPED && sc == BEAM_WALLET_API_INSTANCE_STOPPED && ok,
              "A, C and the node stopped after %.2f s", now() - tstop);
        CHECK(beam_wallet_api_instance_count() == 0, "instance_count() == 0");
        int r1 = beam_wallet_api_check_wallet(w.db, pass), r2 = beam_wallet_api_check_wallet(db2, pass), r3 = beam_wallet_api_check_wallet(db3, pass);
        CHECK(r1 == 0 && r2 == 0 && r3 == 0, "all three wallet.db files open again (%d, %d, %d)", r1, r2, r3);
        int l = 0, c = 0, u = 0, lc = 0;
        if (canary_count) { canary_count(7, &l, &c, &u, &lc, 0); CHECK(u == 0, "multi: no UDP datagram left the machine (canary: %d)", u); }

        // ------------------------------------------------------------ 8 multi-tor
        if (socksPort > 0 && strcmp(torNode, "-") != 0) {
            canary_phase(8);
            printf("== 8. multi-tor: the three instances and the node through Tor (%s)\n", socks);
            long long h0 = hs[0] > hs[1] ? hs[0] : hs[1];
            if (hs[2] > h0) h0 = hs[2];
            if (hb > h0) h0 = hb;
            inst_args(&A, pass, torNode, socks, 0, NULL);
            inst_args(&B, pass, torNode, socks, 0, NULL);
            inst_args(&C, pass, torNode, socks, 0, NULL);
            t0m = now();
            pthread_create(&ta, NULL, inst_start_thread, &A);
            pthread_create(&tb, NULL, inst_start_thread, &B);
            pthread_create(&tc, NULL, inst_start_thread, &C);
            pthread_join(ta, NULL); pthread_join(tb, NULL); pthread_join(tc, NULL);
            CHECK(A.handle > 0 && B.handle > 0 && C.handle > 0, "3 instances with --proxy started at once (%.2f s)", now() - t0m);
            nodePort = free_port();
            rc = beam_node_start(nodeDb, nodePort, torPeers, ownerKey, pass, -1, socks);
            CHECK(rc == BEAM_NODE_OK, "the node through Tor next to them -> %d", rc);
            // Their databases hold the tip of phase 7: a NEW block for each proves the
            // path through Tor (blocks come about once a minute).
            ok3 = insts_wait_sync(all, 3, h0, 300, hs);
            CHECK(ok3, "A, B, C in sync through Tor, each past height %lld (now %lld, %lld, %lld)", h0, hs[0], hs[1], hs[2]);
            {
                double tw = now();
                while (now() - tw < 60) { node_get(&s); if (s.peers_connected > 0 && s.best_peer_height > 0) break; usleep(250 * 1000); }
                node_print(&s, now() - tw);
                CHECK(s.peers_connected > 0 && s.best_peer_height > 0, "node through Tor: %d peers, best tip %llu", s.peers_connected, (unsigned long long)s.best_peer_height);
            }
            lsof_self("multi-tor: A, B, C + node", &sk);
            CHECK(sk.tcp_external == 0 && sk.listen_nonloop == 0 && sk.udp == 0,
                  "lsof: no TCP to anything but 127.0.0.1 (%d of %d), loopback-only listening, no UDP", sk.tcp_external, sk.tcp_total);
            CHECK(no_children(), "no child process");
            tstop = now();
            beam_node_stop();
            sa = inst_stop_wait(&A, 30, NULL, NULL);
            int sb = inst_stop_wait(&B, 30, NULL, NULL);
            sc = inst_stop_wait(&C, 30, NULL, NULL);
            ok = node_wait_state(BEAM_NODE_STATE_STOPPED, 60, &s);
            CHECK(sa == BEAM_WALLET_API_INSTANCE_STOPPED && sb == BEAM_WALLET_API_INSTANCE_STOPPED && sc == BEAM_WALLET_API_INSTANCE_STOPPED && ok,
                  "multi-tor: everything stopped after %.2f s", now() - tstop);
            canary_expect_clean(8, "multi-tor", 1);
        } else {
            printf("SKIP  8. multi-tor: no Tor SOCKS port given\n");
        }
    }

    // ---------------------------------------------------------------- end
    printf("== end\n");
    node_get(&s);
    CHECK(s.state == BEAM_NODE_STATE_STOPPED || s.state == BEAM_NODE_STATE_FAILED, "node not running at the end (%s)", state_name(s.state));
    CHECK(beam_wallet_api_is_running() == 0, "wallet-api not running at the end");
    CHECK(no_children(), "no child process at the end");

    // Secrets never reach the log; the owned-accounts listing is a count.
    {
        int files = 0, private = 1, hasPass = 0, hasKey = 0;
        char owned[200] = "";
        DIR* d = opendir(logDir);
        struct dirent* e;
        while (d && (e = readdir(d))) {
            if (strncmp(e->d_name, "beam_core_", 10) != 0) continue;
            char fp[2048];
            snprintf(fp, sizeof(fp), "%s/%s", logDir, e->d_name);
            struct stat fs;
            if (stat(fp, &fs) != 0) continue;
            files++;
            if ((fs.st_mode & 0777) != 0600) private = 0;
            FILE* f = fopen(fp, "rb");
            if (!f) continue;
            char* buf = malloc((size_t)fs.st_size + 1);
            size_t n = fread(buf, 1, (size_t)fs.st_size, f);
            fclose(f);
            buf[n] = 0;
            if (memmem(buf, n, pass, strlen(pass))) hasPass = 1;
            if (memmem(buf, n, ownerKey, strlen(ownerKey))) hasKey = 1;
            char* o = strstr(buf, "Owned accounts :");
            if (o && !owned[0]) { snprintf(owned, sizeof(owned), "%s", o); char* nl = strchr(owned, '\n'); if (nl) *nl = 0; }
            free(buf);
        }
        if (d) closedir(d);
        CHECK(files > 0 && private, "%d log file(s) in logs/, all 0600", files);
        CHECK(!hasPass, "the password is in no log file");
        CHECK(!hasKey, "the owner key is in no log file");
        CHECK(strstr(owned, "endpoints withheld") != NULL, "file log: \"%s\"", owned);
    }
    CHECK(beam_wallet_api_instance_count() == 0, "no wallet-api instance left");
    // macOS leaks(1) on this process: unreachable allocations only (the library's
    // process-wide objects stay reachable by design).
    {
        char pid[32], out[65536];
        snprintf(pid, sizeof(pid), "%d", (int)getpid());
        char* argvl[] = {"leaks", pid, NULL};
        int lrc = spawn_capture(argvl, out, sizeof(out));
        char* save = NULL;
        for (char* line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
            if (strstr(line, "leaks for") || strstr(line, "leak for") || strstr(line, "nodes malloced") || strstr(line, "ROOT LEAK") || strstr(line, "ROOT CYCLE"))
                INFO("leaks: %s", line);
        }
        CHECK(lrc == 0, "leaks(1): no leaked memory (exit %d)", lrc);
    }
    memset(ownerKey, 0, sizeof(ownerKey));
    memset(ownerKey2, 0, sizeof(ownerKey2));
    memset(pass, 0, strlen(pass));
    free(pass);
    printf("selftest: %d failure(s), %.0f s\n", failures, now() - tMain);
    fflush(stdout);
    return failures ? 1 : 0;
}
