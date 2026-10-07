// Campfire for BEAM: the integrated node of libbeam_core (beam_node_* in beam_core.h).
//
// What beam-ui's NodeClient does (node/node_client.cpp), without Qt: beam::Node on a
// thread of its own with its own io::Reactor and Rules scope, fast sync
// (Horizon::SetStdFastSync), mining off, the wallet's owner key. Differences:
//
//  * it listens on 127.0.0.1 only and never starts the UDP LAN beacon (NodeClient
//    listens on INADDR_ANY; beam-node does neither with the core series' 0001);
//  * with a SOCKS5 proxy every outbound peer connection goes through it (patch
//    0202), configured peers must then be IPv4 literals and nothing is resolved;
//  * the owner key is imported here exactly as beam-node imports --owner_key and
//    --pass (beam/cli.cpp ImportKey_T: KeyString with the password, HKdfPub), and a
//    key that does not import is refused before the thread starts;
//  * progress is published as a plain snapshot (beam_node_status) instead of
//    callbacks: the node thread refreshes it every 500 ms and on its observer
//    events, beam_node_get_status() copies it under a mutex. Nothing is parsed
//    from logs.
#include "beam_core.h"
#include "beam_core_internal.h"
#include "beam_core_thread.h"

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/block_rw.h"
#include "node/db.h"
#include "node/node.h"
#include "utility/common.h"
#include "utility/io/address.h"
#include "utility/io/errorhandling.h"
#include "utility/io/reactor.h"
#include "utility/io/timer.h"
#include "utility/logger.h"

namespace campfire_node
{
    using beam::io::Address;

    struct Params
    {
        std::string dbPath;
        uint16_t port = 0;
        std::vector<std::string> peers;   // "host:port"
        Address proxy;                    // empty: direct
        int verificationThreads = -1;
        std::shared_ptr<ECC::HKdfPub> owner;
    };

    std::mutex g_startLock;               // serialises beam_node_start()
    std::mutex g_lock;                    // guards everything below
    beam_node_status g_status;            // the published snapshot
    bool g_everStarted = false;
    bool g_running = false;               // a node thread exists and has not finished
    std::atomic<bool> g_stopRequested{false};
    beam::io::Reactor* g_reactor = nullptr; // the node thread's reactor while it exists
    campfire_core::CoreThread* g_thread = nullptr; // never destroyed while running (see beam_node_start)

    const uint32_t kRefreshMs = 500;
    const uint32_t kLongStepPublishMs = 250;

    template <typename F>
    void Update(F&& f)
    {
        std::lock_guard<std::mutex> guard(g_lock);
        f(g_status);
        g_status.updated_at_ms = campfire_core::NowMs();
    }

    void SetDetail(beam_node_status& s, const std::string& text)
    {
        std::memset(s.error_detail, 0, sizeof(s.error_detail));
        std::strncpy(s.error_detail, text.c_str(), sizeof(s.error_detail) - 1);
    }

    // "a.b.c.d" (no port).
    bool IsIPv4(const std::string& host)
    {
        int dots = 0, digits = 0, value = 0;
        for (char c : host)
        {
            if (c == '.')
            {
                if (!digits || ++dots > 3)
                    return false;
                digits = value = 0;
            }
            else if (c >= '0' && c <= '9')
            {
                value = value * 10 + (c - '0');
                if (++digits > 3 || value > 255)
                    return false;
            }
            else
                return false;
        }
        return dots == 3 && digits > 0;
    }

    // "host:port" with a port in 1..65535 and a non-empty host without spaces.
    bool SplitHostPort(const std::string& s, std::string& host, uint16_t& port)
    {
        const size_t colon = s.rfind(':');
        if (colon == std::string::npos || colon == 0 || colon + 1 >= s.size())
            return false;
        host = s.substr(0, colon);
        if (host.find_first_of(" \t:") != std::string::npos)
            return false;
        unsigned long v = 0;
        for (size_t i = colon + 1; i < s.size(); i++)
        {
            if (s[i] < '0' || s[i] > '9')
                return false;
            v = v * 10 + unsigned(s[i] - '0');
            if (v > 65535)
                return false;
        }
        if (!v)
            return false;
        port = static_cast<uint16_t>(v);
        return true;
    }

    // An IPv4 literal "a.b.c.d:port" -> Address, without any lookup.
    bool ParseLiteral(const std::string& s, Address& out)
    {
        std::string host;
        uint16_t port = 0;
        if (!SplitHostPort(s, host, port) || !IsIPv4(host))
            return false;
        uint32_t ip = 0;
        size_t pos = 0;
        for (int i = 0; i < 4; i++)
        {
            size_t dot = host.find('.', pos);
            ip = (ip << 8) | uint32_t(std::stoul(host.substr(pos, dot - pos)));
            pos = dot + 1;
        }
        out = Address().ip(ip).port(port);
        return true;
    }

    std::string Trim(const std::string& s)
    {
        const size_t b = s.find_first_not_of(" \t\r\n");
        if (b == std::string::npos)
            return std::string();
        const size_t e = s.find_last_not_of(" \t\r\n");
        return s.substr(b, e - b + 1);
    }

    // Removes the node database path (and its directory) from a message: error
    // texts end up in the UI and in logs, and the path holds the account name.
    std::string Scrub(std::string text, const std::string& dbPath)
    {
        auto erase = [&text](const std::string& what, const char* with)
        {
            if (what.size() < 2)
                return;
            for (size_t p; (p = text.find(what)) != std::string::npos; )
                text.replace(p, what.size(), with);
        };
        erase(dbPath, "<node db>");
        const size_t slash = dbPath.find_last_of("/\\");
        if (slash != std::string::npos && slash > 0)
            erase(dbPath.substr(0, slash), "<node dir>");
        if (text.size() > 150)
            text.resize(150);
        return text;
    }

    int StepOf(const char* sz)
    {
        if (!sz)
            return BEAM_NODE_STEP_OTHER;
        if (!std::strncmp(sz, "Raising Fossil", 14)) return BEAM_NODE_STEP_RAISING_FOSSIL;
        if (!std::strncmp(sz, "Raising TxoLo", 13)) return BEAM_NODE_STEP_RAISING_TXO_LO;
        if (!std::strncmp(sz, "Raising TxoHi", 13)) return BEAM_NODE_STEP_RAISING_TXO_HI;
        if (!std::strncmp(sz, "Rebuilding", 10)) return BEAM_NODE_STEP_REBUILDING;
        if (!std::strncmp(sz, "Rescanning", 10)) return BEAM_NODE_STEP_RESCANNING;
        return BEAM_NODE_STEP_OTHER;
    }

    int Percent(uint64_t done, uint64_t total)
    {
        if (!total)
            return 0;
        if (done >= total)
            return 100;
        return static_cast<int>((done * 100) / total);
    }

    // Node observer and long-step handler. Lives on the node thread; it outlives
    // the Node it watches.
    class Observer final
        : public beam::Node::IObserver
        , public beam::ILongAction
    {
    public:
        beam::Node* m_pNode = nullptr;

        // Node::IObserver
        void OnSyncProgress() override
        {
            if (!m_pNode)
                return;
            beam::Node::SyncStatus s = m_pNode->m_SyncStatus;
            if (!s.m_Total)
                return;
            // As beam-node's and beam-ui's observers: relative to the first value.
            if (!m_HaveDone0)
            {
                m_Done0 = s.m_Done;
                m_HaveDone0 = true;
            }
            s.ToRelative(m_Done0);
            m_RelDone = s.m_Done;
            m_RelTotal = s.m_Total;
            m_HaveProgress = true;
        }

        void OnRolledBack() override
        {
            // During fast sync the processor rolls back to its start when a sync
            // attempt fails ("Fast-sync failed", OnFastSyncFailed), then retries.
            if (m_pNode && m_pNode->get_Processor().IsFastSync())
                m_FastSyncRetries++;
        }

        void InitializeUtxosProgress(uint64_t done, uint64_t total) override
        {
            Update([&](beam_node_status& st)
            {
                st.init_done = done;
                st.init_total = total;
            });
        }

        beam::ILongAction* GetLongActionHandler() override
        {
            return this;
        }

        void OnSyncError(Error error) override
        {
            m_SyncError = (error == TimeDiffToLarge) ? BEAM_NODE_SYNC_ERROR_TIME_DIFF : BEAM_NODE_SYNC_ERROR_UNKNOWN;
            m_SyncErrorCount++;
        }

        // ILongAction: called on the node thread while a long step blocks it.
        void Reset(const char* sz, uint64_t nTotal) override
        {
            m_StepTotal = nTotal;
            m_LastPublish_ms = 0;
            const int step = StepOf(sz);
            Update([&](beam_node_status& st)
            {
                st.long_step = step;
                st.long_step_total = nTotal;
                st.long_step_done = 0;
                st.long_step_percent = 0;
            });
        }

        void SetTotal(uint64_t nTotal) override
        {
            m_StepTotal = nTotal;
        }

        bool OnProgress(uint64_t pos) override
        {
            const uint32_t now = beam::GetTime_ms();
            if (!m_LastPublish_ms || now - m_LastPublish_ms >= kLongStepPublishMs)
            {
                m_LastPublish_ms = now ? now : 1;
                const uint64_t total = m_StepTotal;
                Update([&](beam_node_status& st)
                {
                    st.long_step_done = pos;
                    st.long_step_total = total;
                    st.long_step_percent = Percent(pos, total);
                });
            }
            // BEAM aborts the steps that check this (rescans) when it is false.
            return !g_stopRequested.load();
        }

        // Results for Refresh().
        uint64_t m_Done0 = 0;
        bool m_HaveDone0 = false;
        uint64_t m_RelDone = 0;
        uint64_t m_RelTotal = 0;
        bool m_HaveProgress = false;
        uint32_t m_FastSyncRetries = 0;
        int m_SyncError = BEAM_NODE_SYNC_ERROR_NONE;
        uint32_t m_SyncErrorCount = 0;
        bool m_SawFastSync = false;
        bool m_FastSyncDone = false;

    private:
        uint64_t m_StepTotal = 0;
        uint32_t m_LastPublish_ms = 0;
    };

    // Copies the node's state into the snapshot. Node thread only. A refresh can
    // only run when no long step does (both run on this thread), so it also ends
    // the long-step report.
    void Refresh(beam::Node& node, Observer& obs)
    {
        const beam::NodeProcessor& p = node.get_Processor();
        const uint64_t tip = p.m_Cursor.m_Full.m_Number.v;
        const uint64_t tipTs = tip ? p.m_Cursor.m_Full.m_TimeStamp : 0;
        const bool fastSync = p.IsFastSync();
        if (fastSync)
            obs.m_SawFastSync = true;
        else if (obs.m_SawFastSync)
            obs.m_FastSyncDone = true;

        beam::Node::PeerStats ps;
        node.get_PeerStats(ps);
        const uint32_t known = node.get_AcessiblePeerCount();
        const beam::Node::SyncStatus raw = node.m_SyncStatus;
        const bool synced = !fastSync && node.m_UpdatedFromPeers && raw.m_Total && raw.m_Done == raw.m_Total && tip > 0;
        const int accounts = static_cast<int>(p.m_vAccounts.size());

        Update([&](beam_node_status& st)
        {
            if (st.tip_height != tip)
                st.tip_changed_at_ms = campfire_core::NowMs();
            st.tip_height = tip;
            st.tip_timestamp = tipTs;
            st.peers_connected = static_cast<int32_t>(ps.m_Connected);
            st.peers_with_tip = static_cast<int32_t>(ps.m_WithTip);
            st.peers_known = static_cast<int32_t>(known);
            st.updated_from_peers = node.m_UpdatedFromPeers ? 1 : 0;
            st.best_peer_height = ps.m_BestTip.v;
            st.best_peer_timestamp = ps.m_BestTipTime;
            if (obs.m_HaveProgress)
            {
                st.sync_done = obs.m_RelDone;
                st.sync_total = obs.m_RelTotal;
                st.sync_percent = Percent(obs.m_RelDone, obs.m_RelTotal);
            }
            st.synced = synced ? 1 : 0;
            st.tx_replication_on = node.m_PostStartSynced ? 1 : 0;
            st.sync_error = obs.m_SyncError;
            st.sync_error_count = obs.m_SyncErrorCount;
            st.fast_sync_active = fastSync ? 1 : 0;
            st.fast_sync_done = obs.m_FastSyncDone ? 1 : 0;
            st.fast_sync_target = fastSync ? p.m_SyncData.m_Target.m_Number.v : 0;
            st.fast_sync_retries = obs.m_FastSyncRetries;
            st.owner_accounts = accounts;
            st.long_step = BEAM_NODE_STEP_NONE;
            st.long_step_percent = -1;
            st.long_step_done = 0;
            st.long_step_total = 0;
        });
    }

    struct Failure
    {
        int code = 0;
        std::string detail;
    };

    // Runs one node until it is stopped or fails. Throws on failure; the Node is
    // destroyed (database closed) before this returns or the exception leaves.
    void RunNode(const Params& params, beam::io::Reactor& reactor, Failure& fail)
    {
        std::vector<Address> peers;
        for (const auto& peer : params.peers)
        {
            if (g_stopRequested.load())
                return;
            Address a;
            if (!params.proxy.empty())
            {
                // Validated in beam_node_start(): literals only, never a lookup.
                if (ParseLiteral(peer, a))
                    peers.push_back(a);
            }
            else if (a.resolve(peer.c_str()) && a.port())
                peers.push_back(a);
            else
                BEAM_LOG_WARNING() << "Unable to resolve node address: " << peer;
        }
        if (peers.empty())
        {
            fail.code = BEAM_NODE_ERR_NO_PEERS;
            fail.detail = "No peer address could be resolved";
            return;
        }

        Observer obs; // outlives the node
        {
            beam::Node node;
            obs.m_pNode = &node;
            auto& cfg = node.m_Cfg;
            cfg.m_Listen.port(params.port);
            cfg.m_Listen.ip(Address::LOCALHOST.ip()); // this process's wallet-api only
            cfg.m_BeaconPeriod_ms = 0;                // no UDP LAN beacon
            cfg.m_sPathLocal = params.dbPath;
            cfg.m_MiningThreads = 0;
            cfg.m_VerificationThreads = params.verificationThreads;
            cfg.m_Horizon.SetStdFastSync();
            cfg.m_Connect = peers;
            cfg.m_ProxyAddr = params.proxy;            // patch 0202; empty: direct
            cfg.m_Observer = &obs;
            node.m_Keys.m_pOwner = params.owner;

            BEAM_LOG_INFO() << "starting the integrated node on 127.0.0.1:" << params.port
                            << (params.proxy.empty() ? "" : " (peers through the SOCKS5 proxy)");
            node.Initialize();

            const uint64_t initial = node.get_Processor().m_Cursor.m_Full.m_Number.v;
            Update([&](beam_node_status& st)
            {
                st.initial_tip_height = initial;
                st.has_initial_tip = 1;
                st.owner_accounts = static_cast<int32_t>(node.get_Processor().m_vAccounts.size());
                st.long_step = BEAM_NODE_STEP_NONE;
                st.long_step_percent = -1;
            });

            if (node.get_AcessiblePeerCount() == 0)
            {
                cfg.m_Observer = nullptr;
                fail.code = BEAM_NODE_ERR_NO_PEERS;
                fail.detail = "The node has no peer to connect to";
                return;
            }

            if (!g_stopRequested.load())
            {
                Update([](beam_node_status& st)
                {
                    if (st.state == BEAM_NODE_STATE_STARTING)
                        st.state = BEAM_NODE_STATE_RUNNING;
                });
                Refresh(node, obs);
                auto timer = beam::io::Timer::create(reactor);
                timer->start(kRefreshMs, true, [&node, &obs]() { Refresh(node, obs); });
                reactor.run();
                timer->cancel();
                Refresh(node, obs);
            }
            cfg.m_Observer = nullptr;
            Update([](beam_node_status& st)
            {
                if (st.state == BEAM_NODE_STATE_RUNNING || st.state == BEAM_NODE_STATE_STARTING)
                    st.state = BEAM_NODE_STATE_STOPPING;
            });
            obs.m_pNode = nullptr;
        } // ~Node: peers dropped, database flushed and closed
    }

    // "io::Exception: code=-48 (EC_EADDRINUSE : address already in use)" -> "EADDRINUSE"
    std::string IoErrorName(const char* what)
    {
        const std::string w = what ? what : "";
        const size_t code = w.find("code=");
        if (code == std::string::npos)
            return std::string();
        const size_t open = w.find('(', code);
        const size_t sep = w.find(" : ", open == std::string::npos ? code : open);
        if (open == std::string::npos || sep == std::string::npos || sep <= open + 1)
            return std::string();
        std::string name = w.substr(open + 1, sep - open - 1);
        if (name.compare(0, 3, "EC_") == 0) // io::error_str() names them EC_EADDRINUSE etc.
            name.erase(0, 3);
        return name;
    }

    int SqliteCode(const std::string& err)
    {
        // NodeDB::ThrowSqliteError: "sqlite err <code>, <message>"
        const char* tag = "sqlite err ";
        const size_t p = err.find(tag);
        if (p == std::string::npos)
            return -1;
        return std::atoi(err.c_str() + p + std::strlen(tag));
    }

    void NodeThread(Params params)
    {
        campfire_core::EnsureLogger();
        Failure fail;
        try
        {
            beam::Rules rules; // mainnet, as the binaries are built
            rules.UpdateChecksum();
            beam::Rules::Scope scopeRules(rules);

            auto reactor = beam::io::Reactor::create();
            beam::io::Reactor::Scope scopeReactor(*reactor);
            {
                std::lock_guard<std::mutex> guard(g_lock);
                g_reactor = reactor.get();
                if (g_stopRequested.load())
                    reactor->stop();
            }
            struct Unpublish
            {
                ~Unpublish()
                {
                    std::lock_guard<std::mutex> guard(g_lock);
                    g_reactor = nullptr;
                }
            } unpublish; // runs before the reactor goes

            RunNode(params, *reactor, fail);
        }
        catch (const beam::io::Exception& e)
        {
            // Not e.errorCode: io::Exception's layout depends on whether logger.h
            // (which defines SHOW_CODE_LOCATION) was included before
            // errorhandling.h, which differs between BEAM's sources, so the field
            // read here may not be the one the thrower wrote. what() is the
            // runtime_error base, the same everywhere: "...code=N (EADDRINUSE : ...)".
            const std::string name = IoErrorName(e.what());
            if (name == "EADDRINUSE" || name == "EACCES" || name == "EADDRNOTAVAIL")
            {
                fail.code = BEAM_NODE_ERR_PORT_IN_USE;
                fail.detail = std::string("The node could not listen on 127.0.0.1:") + std::to_string(params.port)
                            + " (" + name + ")";
            }
            else
            {
                fail.code = BEAM_NODE_ERR_FAILED;
                fail.detail = "Network error " + (name.empty() ? std::string("(unknown)") : name);
            }
        }
        catch (const beam::NodeDBUpgradeException&)
        {
            fail.code = BEAM_NODE_ERR_DB_INCOMPATIBLE;
            fail.detail = "The node database was written by an incompatible node version";
        }
        catch (const beam::CorruptionException& e)
        {
            const int sq = SqliteCode(e.m_sErr);
            switch (sq)
            {
            case 13: // SQLITE_FULL
                fail.code = BEAM_NODE_ERR_DISK_FULL;
                fail.detail = "The disk is full";
                break;
            case 5:  // SQLITE_BUSY
            case 6:  // SQLITE_LOCKED
                fail.code = BEAM_NODE_ERR_DB_IN_USE;
                fail.detail = "The node database is in use by another process";
                break;
            case 3:  // SQLITE_PERM
            case 8:  // SQLITE_READONLY
            case 10: // SQLITE_IOERR
            case 14: // SQLITE_CANTOPEN
            case 23: // SQLITE_AUTH
                fail.code = BEAM_NODE_ERR_STORAGE;
                fail.detail = "The node database could not be opened or written: " + Scrub(e.m_sErr, params.dbPath);
                break;
            default:
                fail.code = BEAM_NODE_ERR_DB_CORRUPT;
                fail.detail = "The node database is damaged: " + Scrub(e.m_sErr, params.dbPath);
                break;
            }
        }
        catch (const std::exception& e)
        {
            const std::string what = e.what();
            if (what.find("disk is full") != std::string::npos || what.find("No space left") != std::string::npos)
            {
                fail.code = BEAM_NODE_ERR_DISK_FULL;
                fail.detail = "The disk is full";
            }
            else
            {
                fail.code = BEAM_NODE_ERR_FAILED;
                fail.detail = Scrub(what, params.dbPath);
            }
        }
        catch (...)
        {
            fail.code = BEAM_NODE_ERR_FAILED;
            fail.detail = "Unknown failure";
        }

        if (fail.code)
            BEAM_LOG_ERROR() << "integrated node failed: " << fail.detail;

        std::lock_guard<std::mutex> guard(g_lock);
        if (fail.code)
        {
            g_status.state = BEAM_NODE_STATE_FAILED;
            g_status.error = fail.code;
            SetDetail(g_status, fail.detail);
        }
        else if (g_stopRequested.load())
        {
            g_status.state = BEAM_NODE_STATE_STOPPED;
        }
        else
        {
            g_status.state = BEAM_NODE_STATE_FAILED;
            g_status.error = BEAM_NODE_ERR_FAILED;
            SetDetail(g_status, "The node stopped by itself");
        }
        g_status.long_step = BEAM_NODE_STEP_NONE;
        g_status.long_step_percent = -1;
        g_status.updated_at_ms = campfire_core::NowMs();
        g_running = false; // last: beam_node_start() may join this thread now
    }

    void ResetStatus(beam_node_status& st)
    {
        std::memset(&st, 0, sizeof(st));
        st.size = sizeof(st);
        st.version = BEAM_NODE_STATUS_VERSION;
        st.state = BEAM_NODE_STATE_IDLE;
        st.sync_percent = -1;
        st.long_step_percent = -1;
        st.owner_accounts = -1;
    }

    struct StatusInit
    {
        StatusInit() { ResetStatus(g_status); }
    } g_statusInit;

    void Wipe(std::string& s)
    {
        std::fill(s.begin(), s.end(), '\0');
    }
}

extern "C" BEAM_CORE_API int beam_node_start(const char* node_db_path, int port, const char* peers_csv,
                                             const char* owner_key, const char* password, int verification_threads,
                                             const char* socks5_proxy)
{
    using namespace campfire_node;
    std::lock_guard<std::mutex> startGuard(g_startLock);

    if (!node_db_path || !*node_db_path || port < 1 || port > 65535 || !peers_csv)
        return BEAM_NODE_INVALID_ARGUMENT;
    if (!owner_key || !*owner_key || !password)
        return BEAM_NODE_BAD_OWNER_KEY;

    Params params;
    params.dbPath = node_db_path;
    params.port = static_cast<uint16_t>(port);
    params.verificationThreads = verification_threads;

    const bool viaProxy = socks5_proxy && *socks5_proxy;
    if (viaProxy && !ParseLiteral(Trim(socks5_proxy), params.proxy))
        return BEAM_NODE_INVALID_ARGUMENT;

    {
        const std::string csv(peers_csv);
        size_t pos = 0;
        while (pos <= csv.size())
        {
            const size_t comma = csv.find(',', pos);
            const std::string item = Trim(csv.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos));
            if (!item.empty())
            {
                std::string host;
                uint16_t p = 0;
                if (!SplitHostPort(item, host, p))
                    return BEAM_NODE_INVALID_ARGUMENT;
                // Behind a proxy a host name would be looked up outside it: refused,
                // and nothing here looks it up.
                if (viaProxy && !IsIPv4(host))
                    return BEAM_NODE_HOSTNAME_REFUSED;
                params.peers.push_back(item);
            }
            if (comma == std::string::npos)
                break;
            pos = comma + 1;
        }
        if (params.peers.empty())
            return BEAM_NODE_INVALID_ARGUMENT;
    }

    // A previous run that has finished: collect its thread.
    {
        campfire_core::CoreThread* old = nullptr;
        {
            std::lock_guard<std::mutex> guard(g_lock);
            if (g_running)
                return BEAM_NODE_ALREADY_RUNNING;
            old = g_thread;
            g_thread = nullptr;
        }
        if (old)
        {
            old->join(); // g_running is false: the thread is past its last statement
            delete old;
        }
    }

    // The owner key, as beam-node imports --owner_key with --pass.
    {
        std::string key(owner_key);
        beam::KeyString ks;
        ks.SetPassword(beam::Blob(password, static_cast<uint32_t>(std::strlen(password))));
        ks.m_sRes = key;
        Wipe(key);
        auto kdf = std::make_shared<ECC::HKdfPub>();
        bool ok = false;
        try
        {
            ok = ks.Import(*kdf);
        }
        catch (...)
        {
            ok = false;
        }
        Wipe(ks.m_sRes);
        if (!ok)
            return BEAM_NODE_BAD_OWNER_KEY;
        params.owner = std::move(kdf);
    }

    {
        std::lock_guard<std::mutex> guard(g_lock);
        ResetStatus(g_status);
        g_status.state = BEAM_NODE_STATE_STARTING;
        g_status.port = port;
        g_status.via_proxy = viaProxy ? 1 : 0;
        g_status.owner_key_set = 1;
        g_status.started_at_ms = campfire_core::NowMs();
        g_status.updated_at_ms = g_status.started_at_ms;
        g_stopRequested = false;
        g_running = true;
        g_everStarted = true;
        try
        {
            g_thread = new campfire_core::CoreThread([params]() { NodeThread(params); });
        }
        catch (...)
        {
            g_running = false;
            g_status.state = BEAM_NODE_STATE_FAILED;
            g_status.error = BEAM_NODE_THREAD_FAILED;
            SetDetail(g_status, "The node thread could not be created");
            return BEAM_NODE_THREAD_FAILED;
        }
    }
    return BEAM_NODE_OK;
}

extern "C" BEAM_CORE_API void beam_node_stop(void)
{
    using namespace campfire_node;
    std::lock_guard<std::mutex> guard(g_lock);
    if (!g_running)
        return;
    g_stopRequested = true;
    if (g_status.state == BEAM_NODE_STATE_STARTING || g_status.state == BEAM_NODE_STATE_RUNNING)
    {
        g_status.state = BEAM_NODE_STATE_STOPPING;
        g_status.updated_at_ms = campfire_core::NowMs();
    }
    if (g_reactor)
        g_reactor->stop(); // uv_async_send: thread-safe; honoured when the loop runs
}

extern "C" BEAM_CORE_API int beam_node_get_status(beam_node_status* out)
{
    using namespace campfire_node;
    if (!out || out->size < offsetof(beam_node_status, port))
        return -1;
    const uint32_t callerSize = out->size;
    const size_t n = std::min<size_t>(callerSize, sizeof(beam_node_status));
    std::lock_guard<std::mutex> guard(g_lock);
    std::memcpy(out, &g_status, n);
    out->size = callerSize;
    return 0;
}
