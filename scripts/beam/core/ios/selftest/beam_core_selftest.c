// Self-test for libbeam_wallet_api.a, run inside the iOS Simulator by
// scripts/beam/core/ios/verify_ios.sh (xcrun simctl spawn). Not shipped.
//
//   beam_core_selftest version
//       Prints the core's version and rules, runs `--version` through
//       beam_wallet_api_run(), and checks stop() is a no-op when idle.
//
//   beam_core_selftest live <workdir> <node host:port> <max seconds>
//       In <workdir> (which holds a 0600 phrase.txt and pass.txt for a throwaway
//       wallet, written by verify_ios.sh and deleted here once read):
//       creates the wallet, checks wrong/right passwords, starts wallet-api on a
//       random loopback port with an ACL key and a 0600 config file, asks for
//       get_version and wallet_status until it is in sync (or time runs out),
//       stops it from this thread, checks run() returned and the database opens
//       again, then stops a second run before its event loop exists.
//
// Prints only heights, flags and return codes: never a balance, address or secret.
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "beam_wallet_api.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (cond) { printf("PASS  "); } else { printf("FAIL  "); failures++; } printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)

static char* read_file(const char* path)
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
    FILE* f = fopen(path, "wb");
    if (!f) return -1;
    chmod(path, 0600);
    fputs(text, f);
    fclose(f);
    return 0;
}

struct run_args { int argc; char** argv; int rc; };

static void* run_thread(void* p)
{
    struct run_args* a = (struct run_args*)p;
    a->rc = beam_wallet_api_run(a->argc, a->argv);
    return NULL;
}

static int free_port(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    socklen_t len = sizeof(a);
    bind(s, (struct sockaddr*)&a, sizeof(a));
    getsockname(s, (struct sockaddr*)&a, &len);
    int port = ntohs(a.sin_port);
    close(s);
    return port;
}

static int connect_port(int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((uint16_t)port);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { close(s); return -1; }
    return s;
}

// Sends one request line and reads one response line (events are not subscribed).
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

static long json_int(const char* json, const char* key)
{
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\":", key);
    const char* p = strstr(json, pat);
    return p ? strtol(p + strlen(pat), NULL, 10) : -1;
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

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec / 1e9;
}

static int cmd_version(void)
{
    const char* v = beam_wallet_api_version();
    printf("version: %s\n", v);
    CHECK(strncmp(v, "7.5.14493 ", 10) == 0, "beam_wallet_api_version() starts with 7.5.14493");
    const char* rules = beam_wallet_api_rules_signature();
    printf("rules signature: %s\n", rules);
    CHECK(strstr(rules, "network=mainnet") != NULL && strstr(rules, "3928666-96df3f33ee02ad9e") != NULL,
          "rules are mainnet with HF6 (3928666-96df3f33ee02ad9e)");
    CHECK(beam_wallet_api_is_running() == 0, "is_running() == 0 when idle");
    beam_wallet_api_stop();  // no-op when idle
    char* argv[] = {"wallet-api", "--version", NULL};
    printf("--- run --version:\n");
    fflush(stdout);
    int rc = beam_wallet_api_run(2, argv);
    CHECK(rc == 0, "beam_wallet_api_run(--version) returned %d", rc);
    return failures ? 1 : 0;
}

static int cmd_live(const char* dir, const char* node, int maxSeconds)
{
    if (chdir(dir) != 0) { printf("FAIL  chdir %s: %s\n", dir, strerror(errno)); return 1; }
    char* phrase = read_file("phrase.txt");
    char* pass = read_file("pass.txt");
    unlink("phrase.txt");
    unlink("pass.txt");
    if (!phrase || !pass) { printf("FAIL  phrase.txt/pass.txt missing\n"); return 1; }

    char db[1024];
    snprintf(db, sizeof(db), "%s/wallet.db", dir);
    double t0 = now();
    int rc = beam_wallet_api_init_wallet(db, pass, phrase);
    CHECK(rc == BEAM_WALLET_OK, "init_wallet -> %d (%.2f s)", rc, now() - t0);
    rc = beam_wallet_api_init_wallet(db, pass, phrase);
    CHECK(rc == BEAM_WALLET_EXISTS, "init_wallet again -> %d (EXISTS)", rc);
    rc = beam_wallet_api_init_wallet("/nonexistent-dir/x.db", pass, "not a phrase");
    CHECK(rc == BEAM_WALLET_INVALID_PHRASE, "init_wallet with a bad phrase -> %d (INVALID_PHRASE)", rc);
    memset(phrase, 0, strlen(phrase));
    rc = beam_wallet_api_check_wallet(db, "definitely-not-the-password");
    CHECK(rc == BEAM_WALLET_WRONG_PASSWORD, "check_wallet(wrong password) -> %d (WRONG_PASSWORD)", rc);
    rc = beam_wallet_api_check_wallet(db, pass);
    CHECK(rc == BEAM_WALLET_OK, "check_wallet(right password) -> %d", rc);

    // Secrets reach wallet-api only through 0600 files, as on the desktop.
    char cfg[1200], acl[1200], line[600], aclKey[65];
    snprintf(cfg, sizeof(cfg), "%s/selftest.cfg", dir);
    snprintf(acl, sizeof(acl), "%s/selftest.acl", dir);
    snprintf(line, sizeof(line), "pass=%s\n", pass);
    write_private(cfg, line);
    memset(line, 0, sizeof(line));
    srandom((unsigned)time(NULL) ^ (unsigned)getpid());
    for (int i = 0; i < 64; i++) aclKey[i] = "0123456789abcdef"[random() % 16];
    aclKey[64] = 0;
    snprintf(line, sizeof(line), "%s:write\n", aclKey);
    write_private(acl, line);

    int port = free_port();
    char a_wallet[1100], a_cfg[1300], a_node[300], a_port[32], a_acl[1300];
    snprintf(a_wallet, sizeof(a_wallet), "--wallet_path=%s", db);
    snprintf(a_cfg, sizeof(a_cfg), "--config_file=%s", cfg);
    snprintf(a_node, sizeof(a_node), "--node_addr=%s", node);
    snprintf(a_port, sizeof(a_port), "--port=%d", port);
    snprintf(a_acl, sizeof(a_acl), "--acl_path=%s", acl);
    char* argv[] = {"wallet-api", a_wallet, a_cfg, a_node, a_port, "--use_http=0", "--tcp_max_line=16777216",
                    "--ip_whitelist=127.0.0.1", "--use_acl=1", a_acl, "--enable_assets", "--enable_lelantus",
                    "--api_version=7.4", "--log_level=info", "--file_log_level=warning", "--log_cleanup_days=3", NULL};
    int argc = (int)(sizeof(argv) / sizeof(argv[0])) - 1;

    struct run_args ra = {argc, argv, 12345};
    pthread_t th;
    double started = now();
    pthread_create(&th, NULL, run_thread, &ra);

    int s = -1;
    while (now() - started < 30) {
        s = connect_port(port);
        if (s >= 0) break;
        usleep(150 * 1000);
    }
    CHECK(s >= 0, "wallet-api listening on 127.0.0.1:%d after %.2f s", port, now() - started);
    unlink(cfg);
    unlink(acl);
    if (s < 0) { beam_wallet_api_stop(); pthread_join(th, NULL); return 1; }
    CHECK(beam_wallet_api_is_running() == 1, "is_running() == 1 while serving");

    char resp[8192];
    rpc(s, "not-the-key", 1, "get_version", resp, sizeof(resp));
    CHECK(strstr(resp, "\"error\"") != NULL, "a request with a wrong ACL key is refused: %.120s", resp);
    rpc(s, aclKey, 2, "get_version", resp, sizeof(resp));
    printf("get_version: %s\n", resp);
    CHECK(strstr(resp, "\"api_version\": \"7.4\"") != NULL || strstr(resp, "\"api_version\":\"7.4\"") != NULL, "get_version answers api_version 7.4");

    int synced = 0;
    long height = -1;
    double syncAt = 0;
    for (int id = 3; now() - started < maxSeconds; id++) {
        if (rpc(s, aclKey, id, "wallet_status", resp, sizeof(resp)) < 0) { printf("FAIL  wallet_status: connection lost\n"); failures++; break; }
        height = json_int(resp, "current_height");
        int inSync = json_bool(resp, "is_in_sync");
        long ts = json_int(resp, "current_state_timestamp");
        long age = ts > 0 ? (long)time(NULL) - ts : -1;
        printf("t+%5.1fs wallet_status: current_height=%ld is_in_sync=%d tip_age=%lds\n", now() - started, height, inSync, age);
        fflush(stdout);
        if (inSync == 1 && height > 3928666 && age >= 0 && age < 600) { synced = 1; syncAt = now() - started; break; }
        sleep(3);
    }
    CHECK(synced, "in sync past HF6 (height %ld) after %.1f s", height, syncAt);
    close(s);

    double stopAt = now();
    beam_wallet_api_stop();
    pthread_join(th, NULL);
    CHECK(ra.rc == 0, "stop() from another thread: run() returned %d after %.2f s", ra.rc, now() - stopAt);
    CHECK(beam_wallet_api_is_running() == 0, "is_running() == 0 after stop");
    rc = beam_wallet_api_check_wallet(db, pass);
    CHECK(rc == BEAM_WALLET_OK, "wallet.db opens again after stop -> %d (closed cleanly)", rc);

    // A stop that arrives before the event loop exists is kept and honoured.
    write_private(cfg, "");
    snprintf(line, sizeof(line), "pass=%s\n", pass);
    write_private(cfg, line);
    memset(line, 0, sizeof(line));
    snprintf(line, sizeof(line), "%s:write\n", aclKey);
    write_private(acl, line);
    snprintf(a_port, sizeof(a_port), "--port=%d", free_port());
    ra.rc = 12345;
    started = now();
    pthread_create(&th, NULL, run_thread, &ra);
    while (!beam_wallet_api_is_running() && now() - started < 5) usleep(1000);
    beam_wallet_api_stop();
    pthread_join(th, NULL);
    CHECK(ra.rc == 0, "stop() right after start: run() returned %d after %.2f s", ra.rc, now() - started);
    unlink(cfg);
    unlink(acl);
    memset(pass, 0, strlen(pass));
    free(pass);
    free(phrase);
    return failures ? 1 : 0;
}

int main(int argc, char** argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 2 && strcmp(argv[1], "version") == 0) return cmd_version();
    if (argc >= 5 && strcmp(argv[1], "live") == 0) return cmd_live(argv[2], argv[3], atoi(argv[4]));
    fprintf(stderr, "usage: %s version | live <workdir> <node host:port> <max seconds>\n", argv[0]);
    return 2;
}
