// Campfire for BEAM: libbeam_core, the BEAM core as ONE shared library
// (libbeam_core.dylib, libbeam_core.so, beam_core.dll). It runs inside the app's
// process, like BEAM's own desktop wallet (beam-ui): wallet-api and the private
// node are threads of the app, not separate programs. Built by
// scripts/beam/core/lib (sources: src/, patches: patches/).
//
// The wallet-api part is the interface of the iOS core (scripts/beam/core/ios/src/
// beam_wallet_api.h) unchanged: same names, values and semantics, so one Dart
// binding serves both. Added here: one process-wide logger (beam_core_init), the
// owner key export, and the integrated node (beam_node_*).
//
// wallet-api runs either as the single beam_wallet_api_run() instance (iOS) or as
// any number of instances started with beam_wallet_api_start() (desktop: one per
// open wallet), next to one integrated node; all run at the same time, stop
// independently and can be started again. Strings are UTF-8, NUL-terminated.
// Nothing here installs a signal handler or starts a child process. Secrets
// (passwords, the phrase, the owner key) are never logged.
#ifndef CAMPFIRE_BEAM_CORE_H
#define CAMPFIRE_BEAM_CORE_H

#include <stdint.h>

#if defined(_WIN32)
#  if defined(BEAM_CORE_BUILDING)
#    define BEAM_CORE_API __declspec(dllexport)
#  else
#    define BEAM_CORE_API __declspec(dllimport)
#  endif
#else
#  define BEAM_CORE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// ---- logging ------------------------------------------------------------------

// BEAM's log levels (utility/logger.h). 0 disables a sink.
#define BEAM_LOG_LEVEL_CRITICAL 6
#define BEAM_LOG_LEVEL_ERROR    5
#define BEAM_LOG_LEVEL_WARNING  4
#define BEAM_LOG_LEVEL_INFO     3
#define BEAM_LOG_LEVEL_DEBUG    2
#define BEAM_LOG_LEVEL_VERBOSE  1
#define BEAM_LOG_SINK_DISABLED  0

// beam_core_init() results.
#define BEAM_CORE_OK 0
#define BEAM_CORE_ALREADY_INITIALIZED 1  // a logger exists already; nothing changed
#define BEAM_CORE_INVALID_ARGUMENT 2     // a level outside 0..6
#define BEAM_CORE_LOG_DIR_FAILED 3       // log_dir could not be created or written

// The one BEAM logger of the process, shared by wallet-api and the node. Call it
// once, before anything else. File logs go to log_dir (created 0700 if missing) as
// beam_core_<date>.log, each file 0600; files older than 3 days are deleted here.
// log_dir NULL or "" = no file log; console = the process's stdout. Levels are
// BEAM_LOG_LEVEL_*; 0 disables that sink.
//
// wallet-api's --log_level / --file_log_level / --log_cleanup_days do not apply
// in-process: this logger's levels do. If this was not called, the first
// beam_wallet_api_run() creates the logger from its own options with the files in
// <current directory>/logs (stock wallet-api behaviour, as on iOS), and
// beam_node_start() creates a console-only logger at warning. The logger then
// lives until the process exits. The node's "Owned accounts" listing (which
// identifies the wallet) is reduced to a count before it is written.
BEAM_CORE_API int beam_core_init(const char* log_dir, int console_level, int file_level);

// ---- wallet-api ---------------------------------------------------------------

// beam_wallet_api_run() returns wallet-api's own exit status (0: stopped
// normally or --version/--help; 1: unsupported --api_version; -1: could not
// start or failed while running) or one of these.
#define BEAM_WALLET_API_ALREADY_RUNNING (-100)
#define BEAM_WALLET_API_UNCAUGHT_EXCEPTION (-101)

// Runs wallet-api with the given command line (argv[0] is ignored, as in a
// process) on the calling thread until beam_wallet_api_stop() is called or it
// fails. Blocks; call it from a thread of its own. When it returns, the wallet
// database is closed. Relative paths resolve against the process's current
// directory.
//
// Besides the stock options it takes --proxy=1 --proxy_addr=<ip:port> (patch
// 0201): every node connection then goes through that SOCKS5 proxy (Tor) and
// never directly, and --node_addr must be an IPv4 address and port — a host name
// is refused (run() returns -1) without being looked up.
BEAM_CORE_API int beam_wallet_api_run(int argc, char** argv);

// Asks the running wallet-api to stop and returns at once; run() then returns.
// Safe from any thread. A no-op when nothing runs. A request that arrives
// before the server's event loop exists is kept and honoured as soon as it
// does.
BEAM_CORE_API void beam_wallet_api_stop(void);

// 1 while beam_wallet_api_run() is executing, else 0 (instances started with
// beam_wallet_api_start() are not counted: see beam_wallet_api_instance_count()).
// beam_wallet_api_stop() likewise stops only the run() instance.
BEAM_CORE_API int beam_wallet_api_is_running(void);

// ---- several wallet-api instances (desktop: one per open wallet) ------------------
//
// Each instance is a complete wallet-api (its own wallet.db, node connection, port,
// ACL, event loop) on a thread of its own, started by the library. Any number run
// side by side, next to the integrated node and next to a beam_wallet_api_run()
// instance. They share only the process: the logger (beam_core_init), the current
// directory (wallet-api reads ./wallet-api.cfg and ./beam-common.cfg at start-up,
// as the executable does) and the wallet library's assets switch (on for the whole
// process once any instance starts with --enable_assets; never switched off).
// Consensus rules are per thread (each instance has its own, as each process had).

// beam_wallet_api_start() errors (negative; a handle is > 0).
#define BEAM_WALLET_API_START_FAILED (-1)          // wallet-api returned -1 during start-up: no wallet, wrong
                                                   // password, bad --node_addr / --proxy_addr, ... (see its log)
#define BEAM_WALLET_API_START_BAD_API_VERSION (-2) // it returned 1: unsupported --api_version
#define BEAM_WALLET_API_START_NOT_SERVING (-3)     // it returned 0 without serving (--version, --help)
#define BEAM_WALLET_API_START_NO_LISTEN (-4)       // its server could not listen on --port (in use); it was stopped
// BEAM_WALLET_API_UNCAUGHT_EXCEPTION (-101)       // an exception left wallet-api during start-up
#define BEAM_WALLET_API_START_TIMEOUT (-102)       // neither listening nor ended within 120 s; asked to stop
#define BEAM_WALLET_API_START_THREAD_FAILED (-103) // the thread could not be created

// beam_wallet_api_instance_state() results.
#define BEAM_WALLET_API_INSTANCE_UNKNOWN (-1)  // no such handle
#define BEAM_WALLET_API_INSTANCE_STARTING 0    // (only seen from another thread while start() waits)
#define BEAM_WALLET_API_INSTANCE_RUNNING 1     // its server listens
#define BEAM_WALLET_API_INSTANCE_STOPPING 2    // stop requested; not ended yet
#define BEAM_WALLET_API_INSTANCE_STOPPED 3     // ended after a stop request, exit status 0; wallet.db is closed
#define BEAM_WALLET_API_INSTANCE_FAILED 4      // ended otherwise; *exit_status says how. wallet.db is closed.

// Starts a wallet-api instance with the given command line (argv[0] is ignored, as
// in a process; the same options as beam_wallet_api_run()) on a new thread of its
// own, and returns once its server listens on --port: a handle > 0. Returns a
// negative BEAM_WALLET_API_START_* (or _UNCAUGHT_EXCEPTION) when it does not get
// there; an instance that ended is then gone, one that timed out is asked to stop.
// Blocks only for start-up (opening wallet.db and the listening socket, usually
// well under a second; DNS for --node_addr when there is no proxy): call it off the
// UI thread. argv is copied. Secrets do not belong on it (--config_file, as now).
BEAM_CORE_API int64_t beam_wallet_api_start(int argc, char** argv);

// Asks the instance to stop and returns at once. Its state goes STOPPING, then
// STOPPED once wallet.db is closed. Safe from any thread; repeated calls and
// unknown or ended handles are no-ops.
BEAM_CORE_API void beam_wallet_api_stop_instance(int64_t handle);

// The instance's state (BEAM_WALLET_API_INSTANCE_*). Once it has ended,
// *exit_status (if exit_status is not NULL) receives wallet-api's exit status (0
// stopped normally, -1 failed, -101 uncaught exception); before that, 0. A
// handle stays valid for the life of the process; its thread is collected once it
// has ended, and what remains is a few bytes of state.
BEAM_CORE_API int beam_wallet_api_instance_state(int64_t handle, int* exit_status);

// How many instances started with beam_wallet_api_start() have not ended yet.
// Before the app exits this must reach 0 (stop each, then wait): a thread still
// running at exit would outlive the objects it uses.
BEAM_CORE_API int beam_wallet_api_instance_count(void);

// "7.5.14493 (beam-7.5.14493-campfire)": version and branch label of the core.
BEAM_CORE_API const char* beam_wallet_api_version(void);

// The consensus rules this build follows, exactly as wallet-api logs them after
// "Rules signature: " ("network=mainnet" and one "<height>-<hash>" per fork).
// Lets the app refuse a core that would stall at a hard fork.
BEAM_CORE_API const char* beam_wallet_api_rules_signature(void);

// beam_wallet_api_init_wallet() / _check_wallet() / _export_owner_key() results.
#define BEAM_WALLET_OK 0
#define BEAM_WALLET_EXISTS 1          // init: wallet_path already holds a wallet
#define BEAM_WALLET_NOT_FOUND 2       // check, export: no wallet at wallet_path
#define BEAM_WALLET_WRONG_PASSWORD 3  // check, export: the password does not open it
#define BEAM_WALLET_INVALID_PHRASE 4  // init: not 12 words from the dictionary
#define BEAM_WALLET_FAILED 5          // anything else (export: also out_len too small)

// Creates wallet_path from a 12-word phrase ("w1;w2;...;w12", or separated by
// spaces), as `beam-wallet restore` does: the seed is the hash of the decoded
// phrase, and the default address is generated. The phrase is checked against
// the dictionary only; the caller checks the BIP39 checksum. Secrets stay in
// memory and are wiped from the copies made here. Nothing is logged.
BEAM_CORE_API int beam_wallet_api_init_wallet(const char* wallet_path, const char* password, const char* phrase);

// Opens wallet_path with password and closes it again. Used to tell a wrong
// password from other start-up failures. The wallet must not be open.
BEAM_CORE_API int beam_wallet_api_check_wallet(const char* wallet_path, const char* password);

// The wallet's owner key (master viewer key), encrypted with `password`, exactly
// as `beam-wallet export_owner_key` prints it after "Owner Viewer key: ". It lets
// a node see every payment to this wallet: treat it as a secret. The wallet must
// not be open in this process. Writes a NUL-terminated string into out (capacity
// out_len bytes; 256 is enough) and wipes its own copies; on failure out is
// zeroed.
BEAM_CORE_API int beam_wallet_api_export_owner_key(const char* wallet_path, const char* password, char* out, int out_len);

// ---- the integrated node --------------------------------------------------------

// beam_node_start() results (also beam_node_status.error).
#define BEAM_NODE_OK 0
#define BEAM_NODE_ALREADY_RUNNING 1     // a node of this process has not reached STOPPED/FAILED yet
#define BEAM_NODE_INVALID_ARGUMENT 2    // missing path, port outside 1..65535, bad peer or proxy syntax
#define BEAM_NODE_BAD_OWNER_KEY 3       // the owner key and password do not import (as `key import failed`)
#define BEAM_NODE_HOSTNAME_REFUSED 4    // a socks5_proxy is set and a peer is not an IPv4 literal
#define BEAM_NODE_THREAD_FAILED 5       // the node thread could not be created
// Only in beam_node_status.error (after start returned 0):
#define BEAM_NODE_ERR_PORT_IN_USE 20    // the P2P port could not be opened on 127.0.0.1
#define BEAM_NODE_ERR_DB_CORRUPT 21     // node_db_path is damaged (BEAM's CorruptionException)
#define BEAM_NODE_ERR_DB_INCOMPATIBLE 22 // node_db_path was written by an incompatible node version
#define BEAM_NODE_ERR_DISK_FULL 23      // no space left while writing the node database
#define BEAM_NODE_ERR_STORAGE 24        // node_db_path could not be opened or written (permissions, path)
#define BEAM_NODE_ERR_NO_PEERS 25       // no peer address could be resolved
#define BEAM_NODE_ERR_FAILED 26         // anything else; see error_detail
#define BEAM_NODE_ERR_DB_IN_USE 27      // node_db_path is locked by another process (another node on it)

// beam_node_status.state
#define BEAM_NODE_STATE_IDLE 0      // never started in this process
#define BEAM_NODE_STATE_STARTING 1  // opening the database and connecting (may run a long step first)
#define BEAM_NODE_STATE_RUNNING 2   // the event loop runs: syncing or synced
#define BEAM_NODE_STATE_STOPPING 3  // stop requested; the node finishes its current step and closes the database
#define BEAM_NODE_STATE_STOPPED 4   // stopped on request; the database is closed
#define BEAM_NODE_STATE_FAILED 5    // ended by itself; see error, error_detail. The database is closed.

// beam_node_status.long_step: the node's long maintenance steps (BEAM's
// LongAction: it logs "Raising Fossil..." etc.). They run on the node's thread
// and cannot be interrupted; a stop waits for them.
#define BEAM_NODE_STEP_NONE 0
#define BEAM_NODE_STEP_RAISING_FOSSIL 1    // after fast sync: deletes old block bodies (minutes, disk peaks)
#define BEAM_NODE_STEP_RAISING_TXO_LO 2
#define BEAM_NODE_STEP_RAISING_TXO_HI 3
#define BEAM_NODE_STEP_REBUILDING 4        // "Rebuilding mapped image..." / "Rebuilding non-std data..."
#define BEAM_NODE_STEP_RESCANNING 5        // "Rescanning owned Txos..." / "Rescanning shielded Txos..."
#define BEAM_NODE_STEP_OTHER 6

// beam_node_status.sync_error (BEAM's Node::IObserver::Error); the node keeps running.
#define BEAM_NODE_SYNC_ERROR_NONE 0
#define BEAM_NODE_SYNC_ERROR_UNKNOWN 1
#define BEAM_NODE_SYNC_ERROR_TIME_DIFF 2   // a peer's tip is ahead of this device's clock: fix the clock

#define BEAM_NODE_STATUS_VERSION 1

// A snapshot of the node, for polling (about once a second). Plain data; all
// heights are block numbers as the node logs them ("My Tip: <n>-..."), times are
// Unix seconds (block times) or Unix milliseconds (*_ms, this device's clock).
typedef struct beam_node_status {
    uint32_t size;       // IN: sizeof(beam_node_status) of the caller; fields beyond it are not written
    uint32_t version;    // OUT: BEAM_NODE_STATUS_VERSION

    int32_t state;       // BEAM_NODE_STATE_*
    int32_t error;       // BEAM_NODE_ERR_* when state is FAILED, else 0
    char error_detail[160]; // short, user-safe text for error (never a secret or a path), "" if none

    int32_t port;        // P2P port on 127.0.0.1 of the current/last run, 0 before
    int32_t via_proxy;   // 1: every outbound peer connection goes through the SOCKS5 proxy
    uint64_t started_at_ms;  // when beam_node_start() accepted this run
    uint64_t updated_at_ms;  // when the node thread last refreshed this snapshot

    // Chain position of this node.
    uint64_t tip_height;        // its tip (0: nothing yet)
    uint64_t tip_timestamp;     // that block's timestamp, Unix s (0: none)
    uint64_t tip_changed_at_ms; // when tip_height last changed (0: never in this run)
    uint64_t initial_tip_height; // the tip it had on disk when it started ("Initial Tip:")
    int32_t has_initial_tip;    // 1 once initial_tip_height is known

    // Peers.
    int32_t peers_connected;    // live peer connections past the handshake
    int32_t peers_with_tip;     // of those, how many announced a tip
    int32_t peers_known;        // peer addresses known to the node (incl. banned)
    int32_t updated_from_peers; // 1 once at least one peer reported its tip
    uint64_t best_peer_height;  // highest tip announced by a connected peer (0: none)
    uint64_t best_peer_timestamp;

    // Sync progress, the node's own measure (beam-node "Updating node: p% (done/total)";
    // beam-ui onSyncProgressUpdated): work units relative to the first value seen
    // in this run, headers weigh 1 and blocks 8 per height. Not heights.
    uint64_t sync_done;
    uint64_t sync_total;
    int32_t sync_percent;       // 0..100, -1 before the first progress report
    int32_t synced;             // 1 now: not fast-syncing, a peer reported a tip, done == total, tip > 0
    int32_t tx_replication_on;  // BEAM's m_PostStartSynced: latched once per run ("Tx replication is ON").
                                // A fresh node can latch it during the header download, before fast sync.
    int32_t sync_error;         // BEAM_NODE_SYNC_ERROR_*, the latest one
    uint32_t sync_error_count;

    // Fast sync (Horizon StdFastSync: only the recent UTXO set is downloaded).
    int32_t fast_sync_active;   // 1 while fast sync runs ("Fast-sync mode up to block number N")
    int32_t fast_sync_done;     // 1 once fast sync ran in this run and is over ("Fast-sync succeeded")
    uint64_t fast_sync_target;  // the block fast sync heads for while active, else 0
    uint32_t fast_sync_retries; // rollbacks during fast sync: each is a "Fast-sync failed" and retry

    // Initialisation (beam-ui onInitProgressUpdated: the UTXO image on start-up).
    uint64_t init_done;
    uint64_t init_total;        // 0: not reported

    // Long maintenance step (beam-ui ILongAction).
    int32_t long_step;          // BEAM_NODE_STEP_*, NONE when nothing long runs
    int32_t long_step_percent;  // 0..100 while long_step != NONE, else -1
    uint64_t long_step_done;
    uint64_t long_step_total;

    // The owner key.
    int32_t owner_key_set;      // 1: the node runs with the wallet's owner key
    int32_t owner_accounts;     // owned accounts in the node database (beam-node "Owned accounts :"),
                                // -1 until the database is open
} beam_node_status;

// Starts the integrated node, as beam-ui's NodeClient does: beam::Node on a thread
// of its own with fast sync (Horizon StdFastSync), mining off, listening on
// 127.0.0.1:port only, the UDP LAN beacon off, storage node_db_path (its directory
// must exist; BEAM puts temporary files next to it), peers "host:port,host:port",
// owner key = the string beam_wallet_api_export_owner_key() returns plus the
// wallet password (imported as beam-node imports --owner_key/--pass, checked here,
// before the thread starts). verification_threads: as beam-node's
// --verification_threads (-1: all cores).
//
// socks5_proxy: NULL or "" for direct connections, or "ip:port" of a SOCKS5 proxy
// (Tor). With a proxy every outbound peer connection goes through it with no
// direct fallback (patch 0202), and every peer must be an IPv4 literal: a host
// name is refused (BEAM_NODE_HOSTNAME_REFUSED) without being looked up. Without a
// proxy, host names are resolved on the node thread.
//
// Returns BEAM_NODE_OK once the thread runs; later failures appear in the status
// (state FAILED). The owner key and password are not kept as strings; the imported
// key lives in the node until it stops.
BEAM_CORE_API int beam_node_start(const char* node_db_path, int port, const char* peers_csv,
                                  const char* owner_key, const char* password, int verification_threads,
                                  const char* socks5_proxy);

// Asks the node to stop and returns at once; status.state goes STOPPING, then
// STOPPED once the database is closed and the thread has ended. A long step in
// progress finishes first (minutes, during "Raising Fossil"). Safe from any
// thread; a no-op when no node runs.
BEAM_CORE_API void beam_node_stop(void);

// Copies the latest snapshot into *out (set out->size first). Cheap and
// thread-safe; does not wait for the node thread. Returns 0, or -1 if out is NULL
// or out->size is smaller than the first five fields.
BEAM_CORE_API int beam_node_get_status(beam_node_status* out);

#ifdef __cplusplus
}
#endif

#endif // CAMPFIRE_BEAM_CORE_H
