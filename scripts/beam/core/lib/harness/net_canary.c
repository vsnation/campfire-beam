// Test-only network canary for verify_lib.sh (macOS). Not shipped.
//
// Loaded into the self-test with DYLD_INSERT_LIBRARIES, it interposes the calls a
// process makes to reach the network and records them:
//
//   getaddrinfo / gethostbyname / gethostbyname2   every name looked up
//   connect                                         every IPv4/IPv6 destination
//   sendto                                          every IPv4/IPv6 UDP destination
//
// libuv (BEAM's io::Reactor), BEAM's io::Address::resolve and the system resolver
// all go through these, so "no lookup of a name" and "no connection to anything
// but 127.0.0.1" can be asserted for every call the library makes, not only for
// the sockets that happen to be open when lsof looks.
//
// The self-test reads the record through net_canary_* (found with dlsym).
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

#define MAX_EVENTS 4096

struct event {
    int phase;
    char kind;          // 'L' lookup, 'C' connect, 'U' udp send
    int loopback;       // C/U: destination is 127.0.0.0/8 or ::1
    int numeric;        // L: the name is a numeric address
    char what[96];      // L: the name; C/U: ip:port
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct event g_events[MAX_EVENTS];
static int g_count = 0;
static int g_phase = 0;
static int g_dropped = 0;

static int is_numeric_name(const char* name)
{
    struct in_addr a4;
    struct in6_addr a6;
    if (!name) return 1;
    return inet_pton(AF_INET, name, &a4) == 1 || inet_pton(AF_INET6, name, &a6) == 1;
}

static void record(char kind, int loopback, int numeric, const char* what)
{
    pthread_mutex_lock(&g_lock);
    if (g_count < MAX_EVENTS) {
        struct event* e = &g_events[g_count++];
        e->phase = g_phase;
        e->kind = kind;
        e->loopback = loopback;
        e->numeric = numeric;
        snprintf(e->what, sizeof(e->what), "%s", what ? what : "(null)");
    } else {
        g_dropped++;
    }
    pthread_mutex_unlock(&g_lock);
}

static void record_addr(char kind, const struct sockaddr* sa)
{
    char buf[96];
    if (!sa) return;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in* in = (const struct sockaddr_in*)sa;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &in->sin_addr, ip, sizeof(ip));
        snprintf(buf, sizeof(buf), "%s:%u", ip, ntohs(in->sin_port));
        record(kind, (ntohl(in->sin_addr.s_addr) >> 24) == 127, 1, buf);
    } else if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6* in6 = (const struct sockaddr_in6*)sa;
        char ip[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &in6->sin6_addr, ip, sizeof(ip));
        snprintf(buf, sizeof(buf), "[%s]:%u", ip, ntohs(in6->sin6_port));
        record(kind, IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr), 1, buf);
    }
    // AF_UNIX (the system resolver's own IPC, syslog, ...) is not the network.
}

static int canary_getaddrinfo(const char* node, const char* service, const struct addrinfo* hints, struct addrinfo** res)
{
    if (node) record('L', 0, is_numeric_name(node), node);
    return getaddrinfo(node, service, hints, res);
}
DYLD_INTERPOSE(canary_getaddrinfo, getaddrinfo)

static struct hostent* canary_gethostbyname(const char* name)
{
    record('L', 0, is_numeric_name(name), name);
    return gethostbyname(name);
}
DYLD_INTERPOSE(canary_gethostbyname, gethostbyname)

static struct hostent* canary_gethostbyname2(const char* name, int af)
{
    record('L', 0, is_numeric_name(name), name);
    return gethostbyname2(name, af);
}
DYLD_INTERPOSE(canary_gethostbyname2, gethostbyname2)

static int canary_connect(int fd, const struct sockaddr* addr, socklen_t len)
{
    record_addr('C', addr);
    return connect(fd, addr, len);
}
DYLD_INTERPOSE(canary_connect, connect)

static ssize_t canary_sendto(int fd, const void* buf, size_t n, int flags, const struct sockaddr* addr, socklen_t len)
{
    if (addr) record_addr('U', addr);
    return sendto(fd, buf, n, flags, addr, len);
}
DYLD_INTERPOSE(canary_sendto, sendto)

// ---- read-out for the self-test -------------------------------------------------------

__attribute__((visibility("default"))) void net_canary_set_phase(int phase)
{
    pthread_mutex_lock(&g_lock);
    g_phase = phase;
    pthread_mutex_unlock(&g_lock);
}

// Counts events of a phase: lookups of names that are not numeric addresses, and
// connections / UDP sends to anything but loopback. If list is set, prints them.
__attribute__((visibility("default"))) void net_canary_count(int phase, int* name_lookups, int* external_connects,
                                                               int* external_udp, int* loopback_connects, int print)
{
    int l = 0, c = 0, u = 0, lc = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_count; i++) {
        const struct event* e = &g_events[i];
        if (e->phase != phase) continue;
        if (e->kind == 'L' && !e->numeric) { l++; if (print) printf("      canary: lookup %s\n", e->what); }
        if (e->kind == 'C' && !e->loopback) { c++; if (print) printf("      canary: connect %s\n", e->what); }
        if (e->kind == 'C' && e->loopback) lc++;
        if (e->kind == 'U' && !e->loopback) { u++; if (print) printf("      canary: udp %s\n", e->what); }
    }
    if (g_dropped && print) printf("      canary: %d events not recorded (buffer full)\n", g_dropped);
    pthread_mutex_unlock(&g_lock);
    if (name_lookups) *name_lookups = l;
    if (external_connects) *external_connects = c;
    if (external_udp) *external_udp = u;
    if (loopback_connects) *loopback_connects = lc;
}

// 1 if a lookup of exactly this name was recorded in any phase.
__attribute__((visibility("default"))) int net_canary_looked_up(const char* name)
{
    int found = 0;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < g_count && !found; i++)
        if (g_events[i].kind == 'L' && strcmp(g_events[i].what, name) == 0) found = 1;
    pthread_mutex_unlock(&g_lock);
    return found;
}
