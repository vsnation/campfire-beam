// Campfire for BEAM: wallet-api inside libbeam_core, and the wallet functions of
// the C interface (beam_core.h).
//
// Same technique as the iOS core (scripts/beam/core/ios/src/api_cli_library.cpp):
// this file includes wallet/api/cli/api_cli.cpp, which is not edited, with macros:
//
//  * main -> campfire_wallet_api_main, which beam_wallet_api_run() calls.
//
//  * GracefulIntHandler -> a no-op Reactor::Scope plus a ReactorCapture. Stock
//    wallet-api installs process-wide SIGINT/SIGTERM/SIGHUP/SIGPIPE handlers there
//    and resets them to SIG_DFL on exit; a library must not. The capture records
//    the reactor so beam_wallet_api_stop() can stop it from another thread
//    (Reactor::stop() is uv_async_send(), which is thread-safe).
//
//  * Logger -> CampfireApiLogger. api_cli.cpp's main() calls Logger::create(),
//    which throws when a logger exists and whose result dies when main() returns.
//    In libbeam_core the node logs from its own thread at the same time, so the
//    process has one logger (beam_core_log.cpp) and wallet-api's main() gets a
//    non-owning handle to it. The BEAM_LOG_* macros expand to Logger::will_log(),
//    which the shim forwards unchanged.
//
// Every header api_cli.cpp includes is included here first, so the macros only
// reach api_cli.cpp's own text.

// As the stock wallet-api executable compiles api_cli.cpp (it defines this before
// any include); logger.h would otherwise default it to 0 first.
#ifndef LOG_VERBOSE_ENABLED
#define LOG_VERBOSE_ENABLED 1
#endif

#include <boost/program_options.hpp>
#include <boost/filesystem.hpp>
#include <boost/algorithm/string/trim.hpp>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "core/block_crypt.h"
#include "core/block_rw.h"
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

#include <condition_variable>
#include <cstdint>

#include "beam_core.h"
#include "beam_core_internal.h"
#include "beam_core_thread.h"

namespace beam
{
    // What api_cli.cpp sees as beam::Logger (see the top of this file).
    struct CampfireApiLogger
    {
        static std::shared_ptr<Logger> create(int /*flushLevel*/, int consoleLevel, int fileLevel,
                                              const std::string& fileNamePrefix, const std::string& dstPath)
        {
            return campfire_core::LoggerForWalletApi(consoleLevel, fileLevel, fileNamePrefix, dstPath);
        }

        static bool will_log(int level) { return Logger::will_log(level); }
        static Logger* get() { return Logger::get(); }
    };
}

namespace campfire_wallet_api
{
    // ---- the single run() instance (iOS interface, unchanged) --------------------
    std::mutex g_lock;
    beam::io::Reactor* g_reactor = nullptr;  // set while the server's event loop exists
    bool g_running = false;                  // beam_wallet_api_run() is executing
    bool g_stopRequested = false;            // stop() arrived during this run

    // ---- instances started with beam_wallet_api_start() ---------------------------
    // Each runs api_cli.cpp's main() on a CoreThread of its own. The thread knows its
    // Instance through t_instance, so the hooks below (reactor capture, server
    // listening, the assets flag) reach the right one.
    struct Instance
    {
        int64_t id = 0;
        std::vector<std::string> args;           // argv copy, kept for the run
        std::unique_ptr<campfire_core::CoreThread> thread;
        std::mutex m;
        std::condition_variable cv;
        beam::io::Reactor* reactor = nullptr;    // while its event loop exists
        bool stopRequested = false;
        bool listening = false;                  // its server listens
        bool serverFailed = false;               // its server could not listen
        bool ended = false;                      // main() returned
        int exitStatus = 0;
        bool assets = false;                     // this instance's --enable_assets
    };

    std::mutex g_instLock;                       // guards g_instances and g_nextId
    // Never destroyed: at process exit a destructor must not wait for (or terminate
    // on) an instance thread that is still running.
    auto* g_instances = new std::map<int64_t, std::shared_ptr<Instance>>();
    int64_t g_nextId = 1;

    thread_local Instance* t_instance = nullptr;

    struct ReactorCapture
    {
        explicit ReactorCapture(beam::io::Reactor& reactor)
            : m_inst(t_instance)
        {
            if (m_inst)
            {
                std::lock_guard<std::mutex> guard(m_inst->m);
                m_inst->reactor = &reactor;
                if (m_inst->stopRequested)
                    reactor.stop();
                return;
            }
            std::lock_guard<std::mutex> guard(g_lock);
            g_reactor = &reactor;
            if (g_stopRequested)
            {
                reactor.stop();
            }
        }

        ~ReactorCapture()
        {
            if (m_inst)
            {
                std::lock_guard<std::mutex> guard(m_inst->m);
                m_inst->reactor = nullptr;
                return;
            }
            std::lock_guard<std::mutex> guard(g_lock);
            g_reactor = nullptr;
        }

        ReactorCapture(const ReactorCapture&) = delete;
        ReactorCapture& operator=(const ReactorCapture&) = delete;

    private:
        Instance* const m_inst;
    };

    void OnServer(bool listening)
    {
        Instance* inst = t_instance;
        if (!inst)
            return;
        std::lock_guard<std::mutex> guard(inst->m);
        if (listening)
            inst->listening = true;
        else
            inst->serverFailed = true;
        inst->cv.notify_all();
    }
}

namespace beam::io
{
    // What api_cli.cpp sees as io::TcpServer / io::SslServer: the real ones, plus a
    // report to the instance whether its server listens. Stock wallet-api only logs
    // "cannot start server" and runs on without one; beam_wallet_api_start() needs
    // to know.
    template <typename Real>
    struct CampfireServerShim
    {
        using Ptr = typename Real::Ptr;
        using Callback = typename Real::Callback;

        template <typename... Args>
        static Ptr create(Args&&... args)
        {
            try
            {
                Ptr p = Real::create(std::forward<Args>(args)...);
                ::campfire_wallet_api::OnServer(true);
                return p;
            }
            catch (...)
            {
                ::campfire_wallet_api::OnServer(false);
                throw;
            }
        }
    };
    using CampfireTcpServer = CampfireServerShim<TcpServer>;
    using CampfireSslServer = CampfireServerShim<SslServer>;
}

namespace beam::wallet
{
    // What api_cli.cpp sees as wallet::g_AssetsEnabled. The flag is a process
    // global read by the wallet library (CheckAssetsEnabled); stock main() writes it
    // from --enable_assets. An instance writes its own copy instead, so concurrent
    // instances never write the global under each other; beam_wallet_api_start()
    // switches the global on once, before the thread starts, when the instance asks
    // for assets. run() (one instance, iOS) keeps the stock behaviour.
    bool& CampfireAssetsEnabled()
    {
        auto* inst = ::campfire_wallet_api::t_instance;
        return inst ? inst->assets : g_AssetsEnabled;
    }
}

#define main campfire_wallet_api_main
#define GracefulIntHandler Scope campfire_reactor_scope(*reactor); ::campfire_wallet_api::ReactorCapture
#define Logger CampfireApiLogger
#define TcpServer CampfireTcpServer
#define SslServer CampfireSslServer
#define g_AssetsEnabled CampfireAssetsEnabled()
#include "wallet/api/cli/api_cli.cpp"
#undef g_AssetsEnabled
#undef SslServer
#undef TcpServer
#undef Logger
#undef GracefulIntHandler
#undef main

#define CAMPFIRE_EXPORT extern "C" BEAM_CORE_API

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

// What `beam-wallet export_owner_key` does (wallet/cli/cli.cpp ExportOwnerKey):
// the owner Kdf of the wallet, exported with KeyString under the wallet password,
// meta "0". beam-node imports it with the same password (beam/cli.cpp).
CAMPFIRE_EXPORT int beam_wallet_api_export_owner_key(const char* wallet_path, const char* password, char* out, int out_len)
{
    using namespace campfire_wallet_api;
    if (!out || out_len <= 0)
    {
        return BEAM_WALLET_FAILED;
    }
    std::memset(out, 0, static_cast<size_t>(out_len));
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
        const size_t passLen = std::strlen(password);
        SecString pass;
        pass.assign(static_cast<const void*>(password), passLen);
        auto walletDB = WalletDB::open(path, pass);
        if (!walletDB)
        {
            return BEAM_WALLET_FAILED;
        }
        beam::Key::IPKdf::Ptr ownerKdf = walletDB->get_OwnerKdf();
        if (!ownerKdf)
        {
            return BEAM_WALLET_FAILED;
        }

        beam::KeyString ks;
        ks.SetPassword(beam::Blob(password, static_cast<uint32_t>(passLen)));
        ks.m_sMeta = std::to_string(0);
        ks.ExportP(*ownerKdf);

        int rc = BEAM_WALLET_FAILED;
        if (!ks.m_sRes.empty() && ks.m_sRes.size() < static_cast<size_t>(out_len))
        {
            std::memcpy(out, ks.m_sRes.data(), ks.m_sRes.size());
            out[ks.m_sRes.size()] = 0;
            rc = BEAM_WALLET_OK;
        }
        wipe(ks.m_sRes);
        return rc;
    }
    catch (const FileIsNotDatabaseException&)
    {
        return BEAM_WALLET_WRONG_PASSWORD;
    }
    catch (...)
    {
        std::memset(out, 0, static_cast<size_t>(out_len));
        return BEAM_WALLET_FAILED;
    }
}

// ---- several wallet-api instances in one process ------------------------------------

namespace campfire_wallet_api
{
    // How long beam_wallet_api_start() waits for a server that neither listens nor
    // fails: start-up (config, database, DNS when no proxy) takes well under a
    // second normally.
    const std::chrono::seconds kStartLimit(120);

    bool WantsAssets(const std::vector<std::string>& args)
    {
        for (const auto& a : args)
        {
            if (a == "--enable_assets" || a == "--enable_assets=1" || a == "--enable_assets=true")
                return true;
        }
        return false;
    }

    void InstanceThread(std::shared_ptr<Instance> inst)
    {
        t_instance = inst.get();
        std::vector<char*> argv;
        for (auto& a : inst->args)
            argv.push_back(&a[0]);
        argv.push_back(nullptr);
        int rc = BEAM_WALLET_API_UNCAUGHT_EXCEPTION;
        try
        {
            rc = campfire_wallet_api_main(static_cast<int>(inst->args.size()), argv.data());
        }
        catch (...)
        {
            // main() catches std::exception itself; nothing may leave the thread.
        }
        t_instance = nullptr;
        for (auto& a : inst->args)
            wipe(a);
        std::lock_guard<std::mutex> guard(inst->m);
        inst->exitStatus = rc;
        inst->ended = true;
        inst->cv.notify_all();
    }

    // Joins the threads of instances that have ended. Caller holds g_instLock.
    void ReapLocked()
    {
        for (auto& kv : *g_instances)
        {
            Instance& inst = *kv.second;
            bool ended;
            {
                std::lock_guard<std::mutex> guard(inst.m);
                ended = inst.ended;
            }
            if (ended && inst.thread && inst.thread->joinable())
            {
                inst.thread->join(); // past its last statement: returns at once
                inst.thread.reset();
                inst.args.clear();
            }
        }
    }

    std::shared_ptr<Instance> Find(int64_t handle)
    {
        std::lock_guard<std::mutex> guard(g_instLock);
        ReapLocked();
        auto it = g_instances->find(handle);
        return it == g_instances->end() ? nullptr : it->second;
    }

    void RequestStop(Instance& inst)
    {
        std::lock_guard<std::mutex> guard(inst.m);
        inst.stopRequested = true;
        if (inst.reactor)
            inst.reactor->stop(); // uv_async_send: thread-safe
    }
}

CAMPFIRE_EXPORT int64_t beam_wallet_api_start(int argc, char** argv)
{
    using namespace campfire_wallet_api;
    if (argc < 1 || !argv)
        return BEAM_WALLET_API_START_FAILED;

    auto inst = std::make_shared<Instance>();
    for (int i = 0; i < argc; i++)
        inst->args.emplace_back(argv[i] ? argv[i] : "");
    inst->assets = WantsAssets(inst->args);

    {
        std::lock_guard<std::mutex> guard(g_instLock);
        ReapLocked();
        // The library-wide flag goes on once, before this thread exists, and never
        // off while anything runs (see CampfireAssetsEnabled()).
        if (inst->assets && !beam::wallet::g_AssetsEnabled)
            beam::wallet::g_AssetsEnabled = true;
        inst->id = g_nextId++;
        (*g_instances)[inst->id] = inst;
        try
        {
            inst->thread = std::make_unique<campfire_core::CoreThread>([inst]() { InstanceThread(inst); });
        }
        catch (...)
        {
            g_instances->erase(inst->id);
            return BEAM_WALLET_API_START_THREAD_FAILED;
        }
    }

    std::unique_lock<std::mutex> lock(inst->m);
    const bool decided = inst->cv.wait_for(lock, kStartLimit, [&] { return inst->listening || inst->serverFailed || inst->ended; });
    if (decided && inst->listening)
        return inst->id;

    if (!decided || inst->serverFailed)
    {
        // No server: ask it to stop; it is collected once it has ended.
        inst->stopRequested = true;
        if (inst->reactor)
            inst->reactor->stop();
        if (inst->serverFailed)
        {
            inst->cv.wait_for(lock, std::chrono::seconds(30), [&] { return inst->ended; });
            return BEAM_WALLET_API_START_NO_LISTEN;
        }
        return BEAM_WALLET_API_START_TIMEOUT;
    }

    // main() returned during start-up.
    switch (inst->exitStatus)
    {
    case 0: return BEAM_WALLET_API_START_NOT_SERVING;      // --version, --help
    case 1: return BEAM_WALLET_API_START_BAD_API_VERSION;   // unsupported --api_version
    case BEAM_WALLET_API_UNCAUGHT_EXCEPTION: return BEAM_WALLET_API_UNCAUGHT_EXCEPTION;
    default: return BEAM_WALLET_API_START_FAILED;
    }
}

CAMPFIRE_EXPORT void beam_wallet_api_stop_instance(int64_t handle)
{
    using namespace campfire_wallet_api;
    if (auto inst = Find(handle))
        RequestStop(*inst);
}

CAMPFIRE_EXPORT int beam_wallet_api_instance_state(int64_t handle, int* exit_status)
{
    using namespace campfire_wallet_api;
    auto inst = Find(handle);
    if (!inst)
        return BEAM_WALLET_API_INSTANCE_UNKNOWN;
    std::lock_guard<std::mutex> guard(inst->m);
    if (inst->ended)
    {
        if (exit_status)
            *exit_status = inst->exitStatus;
        const bool stopped = inst->stopRequested && inst->exitStatus == 0 && inst->listening && !inst->serverFailed;
        return stopped ? BEAM_WALLET_API_INSTANCE_STOPPED : BEAM_WALLET_API_INSTANCE_FAILED;
    }
    if (exit_status)
        *exit_status = 0;
    if (inst->stopRequested)
        return BEAM_WALLET_API_INSTANCE_STOPPING;
    return inst->listening ? BEAM_WALLET_API_INSTANCE_RUNNING : BEAM_WALLET_API_INSTANCE_STARTING;
}

CAMPFIRE_EXPORT int beam_wallet_api_instance_count(void)
{
    using namespace campfire_wallet_api;
    std::lock_guard<std::mutex> guard(g_instLock);
    ReapLocked();
    int n = 0;
    for (auto& kv : *g_instances)
    {
        std::lock_guard<std::mutex> g(kv.second->m);
        if (!kv.second->ended)
            n++;
    }
    return n;
}
