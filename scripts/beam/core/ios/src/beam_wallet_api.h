// Campfire for BEAM: C interface of wallet-api built as an in-process library
// (scripts/beam/core/ios: patch 0101, CMake option BEAM_WALLET_API_LIBRARY). Used on
// iOS, where an app may not start child processes. See api_cli_library.cpp.
//
// One wallet-api runs at a time per process. Strings are UTF-8, NUL-terminated.
#ifndef CAMPFIRE_BEAM_WALLET_API_H
#define CAMPFIRE_BEAM_WALLET_API_H

#ifdef __cplusplus
extern "C" {
#endif

// beam_wallet_api_run() returns wallet-api's own exit status (0: stopped
// normally or --version/--help; 1: unsupported --api_version; -1: could not
// start or failed while running) or one of these.
#define BEAM_WALLET_API_ALREADY_RUNNING (-100)
#define BEAM_WALLET_API_UNCAUGHT_EXCEPTION (-101)

// Runs wallet-api with the given command line (argv[0] is ignored, as in a
// process) on the calling thread until beam_wallet_api_stop() is called or it
// fails. Blocks; call it from a thread of its own. When it returns, the wallet
// database is closed. Relative paths, including wallet-api's logs/ directory,
// resolve against the process's current directory.
int beam_wallet_api_run(int argc, char** argv);

// Asks the running wallet-api to stop and returns at once; run() then returns.
// Safe from any thread. A no-op when nothing runs. A request that arrives
// before the server's event loop exists is kept and honoured as soon as it
// does.
void beam_wallet_api_stop(void);

// 1 while beam_wallet_api_run() is executing, else 0.
int beam_wallet_api_is_running(void);

// "7.5.14493 (beam-7.5.14493-campfire)": version and branch label of the core.
const char* beam_wallet_api_version(void);

// The consensus rules this build follows, exactly as wallet-api logs them after
// "Rules signature: " ("network=mainnet" and one "<height>-<hash>" per fork).
// Lets the app refuse a core that would stall at a hard fork.
const char* beam_wallet_api_rules_signature(void);

// beam_wallet_api_init_wallet() / beam_wallet_api_check_wallet() results.
#define BEAM_WALLET_OK 0
#define BEAM_WALLET_EXISTS 1          // init: wallet_path already holds a wallet
#define BEAM_WALLET_NOT_FOUND 2       // check: no wallet at wallet_path
#define BEAM_WALLET_WRONG_PASSWORD 3  // check: the password does not open it
#define BEAM_WALLET_INVALID_PHRASE 4  // init: not 12 words from the dictionary
#define BEAM_WALLET_FAILED 5          // anything else

// Creates wallet_path from a 12-word phrase ("w1;w2;...;w12", or separated by
// spaces), as `beam-wallet restore` does: the seed is the hash of the decoded
// phrase, and the default address is generated. The phrase is checked against
// the dictionary only; the caller checks the BIP39 checksum. Secrets stay in
// memory and are wiped from the copies made here. Nothing is logged.
int beam_wallet_api_init_wallet(const char* wallet_path, const char* password, const char* phrase);

// Opens wallet_path with password and closes it again. Used to tell a wrong
// password from other start-up failures. The wallet must not be open.
int beam_wallet_api_check_wallet(const char* wallet_path, const char* password);

#ifdef __cplusplus
}
#endif

#endif // CAMPFIRE_BEAM_WALLET_API_H
