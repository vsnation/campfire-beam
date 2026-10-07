// Campfire for BEAM: wallet-api as an in-process static library, for platforms
// where an app may not start a child process (iOS).
//
// This file is not part of the BEAM tree. The iOS build
// (scripts/beam/core/ios/build_wallet_api.sh) applies patch 0101, which adds the
// CMake option BEAM_WALLET_API_LIBRARY and compiles this file into
// beam_wallet_api_lib when it is given as BEAM_WALLET_API_LIBRARY_SOURCE. No other
// build compiles it, and wallet/api/cli/api_cli.cpp is not edited: its log macros
// embed __LINE__, so any edit there would change the pinned desktop and Android
// binaries.
//
// This file includes api_cli.cpp with two macros:
//
//  * main -> campfire_wallet_api_main, which beam_wallet_api_run() calls.
//
//  * GracefulIntHandler -> a no-op Reactor::Scope (the reactor is already
//    current) followed by a ReactorCapture. Stock wallet-api installs
//    process-wide SIGINT/SIGTERM/SIGHUP/SIGPIPE handlers at that point and
//    resets all four to SIG_DFL on exit; inside an app that would take over the
//    host's signal handling and leave SIGPIPE fatal afterwards. The capture
//    records the reactor so beam_wallet_api_stop() can stop it from another
//    thread (Reactor::stop() is uv_async_send(), which is thread-safe).
//
// Every header api_cli.cpp includes is included here first, so the two macros
// only ever reach api_cli.cpp's own text.

#include <boost/program_options.hpp>
#include <boost/filesystem.hpp>
#include <boost/algorithm/string/trim.hpp>
#include <algorithm>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "core/block_crypt.h"
#include "utility/logger.h"
#include "wallet/api/i_wallet_api.h"
#include "utility/cli/options.h"
#include "utility/helpers.h"
#include "utility/io/reactor.h"
#include "utility/io/timer.h"
#include "utility/io/tcpserver.h"
#include "utility/io/sslserver.h"
#include "utility/io/json_serializer.h"
#include "utility/string_helpers.h"
#include "utility/log_rotation.h"
#include "http/http_connection.h"
#include "http/http_msg_creator.h"
#include "p2p/line_protocol.h"
#include "wallet/core/wallet_db.h"
#include "wallet/core/wallet_network.h"
#include "wallet/core/simple_transaction.h"
#include "wallet/core/node_network.h"
#include "wallet/core/secstring.h"
#include "keykeeper/local_private_key_keeper.h"
#include "wallet/transactions/assets/assets_reg_creators.h"
#include "wallet/transactions/lelantus/lelantus_reg_creators.h"
#ifdef BEAM_ATOMIC_SWAP_SUPPORT
#include "api_cli_swap.h"
#endif
#ifdef BEAM_IPFS_SUPPORT
#include "wallet/ipfs/ipfs.h"
#include "wallet/ipfs/ipfs_async.h"
#endif
#ifdef BEAM_ASSET_SWAP_SUPPORT
#include "wallet/client/extensions/dex_board/dex_board.h"
#include "wallet/transactions/dex/dex_tx_builder.h"
#include "wallet/transactions/dex/dex_tx.h"
#endif
#include "wallet/core/contracts/i_shaders_manager.h"
#include "bvm/bvm2.h"
#include "utility/hex.h"
#include "nlohmann/json.hpp"
#include "mnemonic/mnemonic.h"
// version.h has no include guard; api_cli.cpp includes it below.

#include "beam_wallet_api.h"

namespace campfire_wallet_api
{
    std::mutex g_lock;
    beam::io::Reactor* g_reactor = nullptr;  // set while the server's event loop exists
    bool g_running = false;                  // beam_wallet_api_run() is executing
    bool g_stopRequested = false;            // stop() arrived during this run

    struct ReactorCapture
    {
        explicit ReactorCapture(beam::io::Reactor& reactor)
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_reactor = &reactor;
            if (g_stopRequested)
            {
                reactor.stop();
            }
        }

        ~ReactorCapture()
        {
            std::lock_guard<std::mutex> guard(g_lock);
            g_reactor = nullptr;
        }

        ReactorCapture(const ReactorCapture&) = delete;
        ReactorCapture& operator=(const ReactorCapture&) = delete;
    };
}

#define main campfire_wallet_api_main
#define GracefulIntHandler Scope campfire_reactor_scope(*reactor); ::campfire_wallet_api::ReactorCapture
#include "wallet/api/cli/api_cli.cpp"
#undef GracefulIntHandler
#undef main

#define CAMPFIRE_EXPORT extern "C" __attribute__((visibility("default")))

namespace campfire_wallet_api
{
    void wipe(std::string& s)
    {
        std::fill(s.begin(), s.end(), '\0');
    }

    void wipe(beam::WordList& words)
    {
        for (auto& w : words)
        {
            wipe(w);
        }
    }
}

CAMPFIRE_EXPORT int beam_wallet_api_run(int argc, char** argv)
{
    using namespace campfire_wallet_api;
    {
        std::lock_guard<std::mutex> guard(g_lock);
        if (g_running)
        {
            return BEAM_WALLET_API_ALREADY_RUNNING;
        }
        g_running = true;
        g_stopRequested = false;
    }

    int rc = BEAM_WALLET_API_UNCAUGHT_EXCEPTION;
    try
    {
        rc = campfire_wallet_api_main(argc, argv);
    }
    catch (...)
    {
        // main() catches std::exception itself; nothing may cross the C boundary.
    }

    std::lock_guard<std::mutex> guard(g_lock);
    g_running = false;
    g_stopRequested = false;
    return rc;
}

CAMPFIRE_EXPORT void beam_wallet_api_stop(void)
{
    using namespace campfire_wallet_api;
    std::lock_guard<std::mutex> guard(g_lock);
    if (!g_running)
    {
        return;
    }
    g_stopRequested = true;
    if (g_reactor)
    {
        g_reactor->stop();
    }
}

CAMPFIRE_EXPORT int beam_wallet_api_is_running(void)
{
    using namespace campfire_wallet_api;
    std::lock_guard<std::mutex> guard(g_lock);
    return g_running ? 1 : 0;
}

CAMPFIRE_EXPORT const char* beam_wallet_api_version(void)
{
    static const std::string version = PROJECT_VERSION + " (" + BRANCH_NAME + ")";
    return version.c_str();
}

CAMPFIRE_EXPORT const char* beam_wallet_api_rules_signature(void)
{
    static const std::string signature = []
    {
        beam::Rules rules;
        rules.UpdateChecksum();
        return rules.get_SignatureStr();
    }();
    return signature.c_str();
}

CAMPFIRE_EXPORT int beam_wallet_api_init_wallet(const char* wallet_path, const char* password, const char* phrase)
{
    using namespace campfire_wallet_api;
    if (!wallet_path || !password || !phrase || !*wallet_path)
    {
        return BEAM_WALLET_FAILED;
    }
    try
    {
        beam::Rules rules;
        beam::Rules::Scope scopeRules(rules);
        rules.UpdateChecksum();
        // WalletDB arms a flush timer on the current reactor when it is modified,
        // as beam-wallet does around every command. The loop never runs: the
        // database commits what is pending when it closes, before the reactor goes.
        auto reactor = beam::io::Reactor::create();
        beam::io::Reactor::Scope scopeReactor(*reactor);

        const std::string path(wallet_path);
        if (WalletDB::isInitialized(path))
        {
            return BEAM_WALLET_EXISTS;
        }

        std::string text(phrase);
        std::replace(text.begin(), text.end(), ' ', ';');
        boost::algorithm::trim_if(text, [](char ch) { return ch == ';'; });
        beam::WordList words = string_helpers::split(text, ';');
        wipe(text);
        words.erase(std::remove_if(words.begin(), words.end(), [](const std::string& w) { return w.empty(); }), words.end());
        if (words.size() != beam::WORD_COUNT || !beam::isValidMnemonic(words))
        {
            wipe(words);
            return BEAM_WALLET_INVALID_PHRASE;
        }

        auto buf = beam::decodeMnemonic(words);
        wipe(words);
        SecString seed;
        seed.assign(buf.data(), buf.size());  // the non-const overload wipes buf
        ECC::NoLeak<ECC::uintBig> walletSeed;
        walletSeed.V = seed.hash().V;

        SecString pass;
        pass.assign(static_cast<const void*>(password), std::strlen(password));
        auto walletDB = WalletDB::init(path, pass, walletSeed);
        if (!walletDB)
        {
            return BEAM_WALLET_FAILED;
        }
        walletDB->generateAndSaveDefaultAddress();
        return BEAM_WALLET_OK;
    }
    catch (...)
    {
        return BEAM_WALLET_FAILED;
    }
}

CAMPFIRE_EXPORT int beam_wallet_api_check_wallet(const char* wallet_path, const char* password)
{
    if (!wallet_path || !password || !*wallet_path)
    {
        return BEAM_WALLET_FAILED;
    }
    try
    {
        beam::Rules rules;
        beam::Rules::Scope scopeRules(rules);
        rules.UpdateChecksum();
        auto reactor = beam::io::Reactor::create();   // see beam_wallet_api_init_wallet()
        beam::io::Reactor::Scope scopeReactor(*reactor);

        const std::string path(wallet_path);
        if (!WalletDB::isInitialized(path))
        {
            return BEAM_WALLET_NOT_FOUND;
        }
        SecString pass;
        pass.assign(static_cast<const void*>(password), std::strlen(password));
        auto walletDB = WalletDB::open(path, pass);
        return walletDB ? BEAM_WALLET_OK : BEAM_WALLET_FAILED;
    }
    catch (const FileIsNotDatabaseException&)
    {
        return BEAM_WALLET_WRONG_PASSWORD;
    }
    catch (...)
    {
        return BEAM_WALLET_FAILED;
    }
}
