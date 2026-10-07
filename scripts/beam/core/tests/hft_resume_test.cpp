// Campfire for BEAM: regression test for core patch 0006 (an HFT contract transaction
// that was in flight when the wallet stopped).
//
// Built and run by scripts/beam/core/test_hft_resume.sh against the static libraries of an
// existing core build, once with the stock wallet/core/contract_transaction.cpp and once
// with 0006 applied. The stock build is expected to FAIL these checks (that is the bug the
// patch fixes); the patched one must pass them all.
//
// The transaction is driven through a fake INegotiatorGateway (tip, dependent state,
// registrations, kernel proofs) and a real SQLite wallet DB. No node, no network, no funds.
// The stored app shader is deliberately not a shader: if the core starts a rebuild, the run
// fails at once and prints "Shader exec error", which the test counts.

#include "wallet/core/wallet.h"
#include "wallet/core/wallet_db.h"
#include "wallet/core/contract_transaction.h"
#include "bvm/invoke_data.h"
#include "core/fly_client.h"
#include "utility/io/reactor.h"
#include "utility/io/timer.h"
#include "utility/logger.h"

#include <boost/filesystem.hpp>
#include <iostream>
#include <sstream>

// Defined by each executable (wallet-api: api_cli.cpp).
thread_local const beam::Rules* beam::Rules::s_pInstance = nullptr;

using namespace beam;
using namespace beam::wallet;

namespace
{
    int g_Failures = 0;

    void Check(bool ok, const char* what)
    {
        std::cerr << (ok ? "  ok    " : "  FAIL  ") << what << std::endl;
        if (!ok)
            g_Failures++;
    }

    // Counts app shader runs: ContractTransaction prints one line per run.
    struct ShaderRunCounter
    {
        std::stringstream m_Out;
        std::streambuf* m_pPrev;

        ShaderRunCounter() { m_pPrev = std::cout.rdbuf(m_Out.rdbuf()); }
        ~ShaderRunCounter() { std::cout.rdbuf(m_pPrev); }

        size_t get_Runs() const
        {
            std::string s = m_Out.str();
            size_t n = 0;
            for (size_t pos = 0; (pos = s.find("Shader ", pos)) != std::string::npos; pos++)
                n++;
            return n;
        }
    };

    struct FakeNetwork : proto::FlyClient::INetwork
    {
        void Connect() override {}
        void Disconnect() override {}
        void PostRequestInternal(proto::FlyClient::Request&) override {} // never answered
    };

    struct FakeGateway : INegotiatorGateway
    {
        Block::SystemState::Full m_Tip;
        std::vector<Merkle::Hash> m_Dependent;
        std::vector<Merkle::Hash> m_Registered; // kernel IDs of every tx sent to the "node"
        std::vector<std::pair<Merkle::Hash, IConfirmCallback::Ptr> > m_Pending;
        std::vector<Merkle::Hash> m_Queried;
        bool m_Completed = false;
        bool m_Failed = false;

        void SetTip(Height h)
        {
            ZeroObject(m_Tip);
            m_Tip.m_Number.v = h;
            m_Tip.m_Prev = h; // any value; it is the "root" dependent context of this block
        }

        void OnAsyncStarted() override {}
        void OnAsyncFinished() override {}
        void on_tx_completed(const TxID&) override { m_Completed = true; }
        void on_tx_failed(const TxID&) override { m_Failed = true; }
        void register_tx(const TxID&, const Transaction::Ptr& p, const Merkle::Hash*, SubTxID) override
        {
            for (const auto& pKrn : p->m_vKernels)
                m_Registered.push_back(pKrn->get_ID());
        }
        void confirm_kernel(const TxID&, const Merkle::Hash&, SubTxID) override {}
        void confirm_asset(const TxID&, const PeerID&, SubTxID) override {}
        void confirm_asset(const TxID&, const Asset::ID, SubTxID) override {}
        void get_kernel(const TxID&, const Merkle::Hash&, SubTxID) override {}
        bool get_tip(Block::SystemState::Full& s) const override { s = m_Tip; return true; }
        void send_tx_params(const WalletID&, const SetTxParameter&) override {}
        void get_shielded_list(const TxID&, TxoID, uint32_t, ShieldedListCallback&&) override {}
        void UpdateOnNextTip(const TxID&) override {}

        void confirm_kernel_ex(const Merkle::Hash& id, IConfirmCallback::Ptr&& p) override
        {
            m_Queried.push_back(id);
            m_Pending.emplace_back(id, std::move(p));
        }

        const Merkle::Hash* get_DependentState(uint32_t& n) override
        {
            n = static_cast<uint32_t>(m_Dependent.size());
            return n ? &m_Dependent.front() : nullptr;
        }

        bool WasQueried(const Merkle::Hash& id) const
        {
            return std::find(m_Queried.begin(), m_Queried.end(), id) != m_Queried.end();
        }

        bool WasRegisteredOtherThan(const Merkle::Hash* pAllowed) const
        {
            for (const auto& id : m_Registered)
                if (!pAllowed || (id != *pAllowed))
                    return true;
            return false;
        }

        // Answers every pending kernel proof request: pMined is in block hMined, nothing else is.
        void Answer(const Merkle::Hash* pMined, Height hMined)
        {
            auto v = std::move(m_Pending);
            m_Pending.clear();
            for (auto& x : v)
            {
                bool bFound = pMined && (x.first == *pMined);
                x.second->OnDone(bFound ? &hMined : nullptr);
            }
        }
    };

    void Pump(io::Reactor& r)
    {
        auto t = io::Timer::create(r);
        t->start(40, false, [&r]() { r.stop(); });
        r.run();
    }

    TxKernel::Ptr MakeKernel(const ContractID& cid, Height h, uint8_t tag)
    {
        auto p = std::make_unique<TxKernelContractInvoke>();
        p->m_Cid = cid;
        p->m_iMethod = 3;
        p->m_Args.push_back(tag);
        p->m_Height = HeightRange(h);
        p->m_Fee = 1100000;
        p->m_Dependent = true;
        return p;
    }

    Merkle::Hash KernelID(const TxKernel& k)
    {
        return k.get_ID();
    }

    // Same layout as ContractTransaction::MyBuilder::HftVariant / HftState.
    struct StoredVariant
    {
        HeightHash m_Key;
        Transaction m_Tx;
        std::vector<CoinID> m_Input;
        std::vector<IPrivateKeyKeeper2::ShieldedInput> m_InputShielded;
        std::vector<CoinID> m_Output;

        template <typename Archive>
        void serialize(Archive& ar)
        {
            ar & m_Key & m_Tx & m_Input & m_InputShielded & m_Output;
        }
    };

    ByteBuffer HftStateBlob(const bvm2::FundsMap& spend, std::vector<StoredVariant>& v)
    {
        Serializer ser;
        ser & Cast::Down< std::map<Asset::ID, AmountSigned> >(spend);
        size_t n = v.size();
        ser & n;
        for (auto& x : v)
            ser & x;
        ByteBuffer bb;
        ser.swap_buf(bb);
        return bb;
    }

    size_t StoredVariantCount(IWalletDB& db, const TxID& txID)
    {
        ByteBuffer buf;
        if (!storage::getTxParameter(db, txID, kDefaultSubTxID, TxParameterID::HftState, buf) || buf.empty())
            return 0;
        Deserializer der;
        der.reset(&buf.front(), buf.size());
        std::map<Asset::ID, AmountSigned> spend;
        der & spend;
        size_t n = 0;
        der & n;
        return n;
    }

    bool HasKernelParam(IWalletDB& db, const TxID& txID)
    {
        ByteBuffer buf;
        return storage::getTxParameter(db, txID, kDefaultSubTxID, TxParameterID::Kernel, buf) && !buf.empty();
    }

    struct Env
    {
        io::Reactor::Ptr m_pReactor;
        std::unique_ptr<io::Reactor::Scope> m_pScope;
        std::string m_Path;
        IWalletDB::Ptr m_pDB;
        std::shared_ptr<Wallet> m_pWallet;
        FakeGateway m_Gw;
        TxID m_TxID;
        ContractID m_Cid;
        BaseTransaction::Ptr m_pTx;

        explicit Env(const char* szName)
        {
            m_pReactor = io::Reactor::create();
            m_pScope = std::make_unique<io::Reactor::Scope>(*m_pReactor);

            m_Path = (boost::filesystem::temp_directory_path() / szName).string();
            boost::filesystem::remove(m_Path);

            ECC::NoLeak<ECC::uintBig> seed;
            seed.V = 7U;
            m_pDB = WalletDB::init(m_Path, std::string("test"), seed, false);

            m_pWallet = std::make_shared<Wallet>(m_pDB);
            m_pWallet->SetNodeEndpoint(std::make_shared<FakeNetwork>());

            for (uint32_t i = 0; i < m_TxID.size(); i++)
                m_TxID[i] = static_cast<uint8_t>(0x50 + i);
            m_Cid = 0x729fU;
        }

        ~Env()
        {
            m_pTx.reset();
            m_pWallet.reset();
            m_pDB.reset();
            m_pScope.reset();
            boost::filesystem::remove(m_Path);
        }

        template <typename T>
        void Set(TxParameterID id, const T& v)
        {
            storage::setTxParameter(*m_pDB, m_TxID, kDefaultSubTxID, id, v, false);
        }

        template <typename T>
        bool Get(TxParameterID id, T& v)
        {
            return storage::getTxParameter(*m_pDB, m_TxID, kDefaultSubTxID, id, v);
        }

        // The invoke data a pool_trade produces: one dependent call, re-runnable app attached.
        bvm2::ContractInvokeData MakeData(const HeightHash& parent)
        {
            bvm2::ContractInvokeData d;
            auto& e = d.m_vec.emplace_back();
            e.m_Cid = m_Cid;
            e.m_iMethod = 3;
            e.m_Args.push_back(1);
            e.m_Flags = bvm2::ContractInvokeEntry::Flags::Dependent | bvm2::ContractInvokeEntry::Flags::SaveAppInvoke;
            e.m_ParentCtx = parent;
            e.m_Spend[0] = 2000000;     // pay 0.02 BEAM
            e.m_Spend[174] = -16000000; // receive 0.16 FOMO
            d.m_AppInvoke.m_App = { 0xde, 0xad, 0xbe, 0xef }; // not a shader: a rebuild fails at once
            d.m_AppInvoke.m_Args["action"] = "pool_trade";
            return d;
        }

        void SetCommon(const bvm2::ContractInvokeData& d, Height hCreated)
        {
            Set(TxParameterID::TransactionType, TxType::Contract);
            Set(TxParameterID::IsSender, true);
            Set(TxParameterID::Status, TxStatus::InProgress);
            Set(TxParameterID::CreateTime, getTimestamp());
            Set(TxParameterID::MinHeight, hCreated);
            Set(TxParameterID::ContractDataPacked, d);
        }

        void Start()
        {
            ContractTransaction::Creator creator(m_pDB);
            BaseTransaction::Creator& c = creator;
            m_pTx = c.Create(BaseTransaction::TxContext(*m_pWallet, m_Gw, m_TxID));
            Step();
        }

        void Step()
        {
            m_pTx->Update();
            Pump(*m_pReactor);
        }

        void AnswerAll(const Merkle::Hash* pMined, Height hMined)
        {
            for (int i = 0; (i < 8) && !m_Gw.m_Pending.empty(); i++)
            {
                m_Gw.Answer(pMined, hMined);
                Pump(*m_pReactor);
            }
        }

        bool IsCompleted()
        {
            TxStatus s = TxStatus::Pending;
            Get(TxParameterID::Status, s);
            return m_Gw.m_Completed || (TxStatus::Completed == s);
        }

        bool IsFailed()
        {
            TxStatus s = TxStatus::Pending;
            Get(TxParameterID::Status, s);
            return m_Gw.m_Failed || (TxStatus::Failed == s);
        }
    };
}

// The incident of 2026-10-07: variant V1 (block 100) expired at once, V2 (block 101) was
// built on another dependent context and sent. The wallet then restarted with V2 still
// pending. ContractDataPacked still describes V1 (stock builds never rewrite it), and the
// kernel of V1 was already proven absent at height 100.
void TestResumeWithStaleData()
{
    std::cerr << "resume: V2 pending, stored invoke data still V1's" << std::endl;
    Env env("cfb_hft_resume_a.db");
    ShaderRunCounter runs;

    HeightHash p1, p2;
    p1.m_Height = 100; p1.m_Hash = 0x11U;
    p2.m_Height = 101; p2.m_Hash = 0x22U;

    auto d = env.MakeData(p1);
    env.SetCommon(d, 100);

    TxKernel::Ptr k1 = MakeKernel(env.m_Cid, 100, 1);
    TxKernel::Ptr k2 = MakeKernel(env.m_Cid, 101, 2);
    Merkle::Hash id1 = KernelID(*k1), id2 = KernelID(*k2);

    std::vector<StoredVariant> v(1);
    v[0].m_Key.m_Height = 100;
    DependentContext::get_Ancestor(v[0].m_Key.m_Hash, p1.m_Hash, id1);
    v[0].m_Tx.m_vKernels.push_back(std::move(k1));
    v[0].m_Tx.m_Offset = Zero;
    env.Set(TxParameterID::HftState, HftStateBlob(d.get_FullSpend(), v));

    env.Set(TxParameterID::Kernel, k2);
    env.Set(TxParameterID::KernelID, id2);
    env.Set(TxParameterID::TransactionRegistered, static_cast<uint8_t>(proto::TxStatus::Ok));
    env.Set(TxParameterID::KernelUnconfirmedHeight, Height(100));
    env.Set(TxParameterID::State, ContractTransaction::State::Registration);

    // the node still holds V2 as its best dependent tx for block 101
    Merkle::Hash ctx2;
    DependentContext::get_Ancestor(ctx2, p2.m_Hash, id2);
    env.m_Gw.SetTip(100);
    env.m_Gw.m_Dependent.push_back(ctx2);

    env.Start();
    env.AnswerAll(nullptr, 0);
    env.Step();
    env.AnswerAll(nullptr, 0);

    Check(runs.get_Runs() == 0, "at block 100: no app shader run (no new variant is built)");
    Check(HasKernelParam(*env.m_pDB, env.m_TxID), "at block 100: V2 stays the current variant");
    Check(StoredVariantCount(*env.m_pDB, env.m_TxID) == 1, "at block 100: V2 is not filed away as an old variant");
    Check(!env.m_Gw.WasRegisteredOtherThan(&id2), "at block 100: nothing but V2 is sent to the node");
    Check(!env.IsFailed(), "at block 100: the swap is not given up while V2 can still be mined");

    // block 101 contains V2
    env.m_Gw.SetTip(101);
    env.m_Gw.m_Dependent.clear();
    env.Step();
    env.AnswerAll(&id2, 101);
    env.Step();
    env.AnswerAll(&id2, 101);

    Height hProof = 0;
    env.Get(TxParameterID::KernelProofHeight, hProof);

    Check(env.m_Gw.WasQueried(id2), "at block 101: V2's kernel is looked up");
    Check(env.IsCompleted() && (101 == hProof), "at block 101: the swap completes with V2");
    Check(runs.get_Runs() == 0, "no app shader run at any point");
    Check(!env.m_Gw.WasRegisteredOtherThan(&id2), "no second variant was ever sent");
}

// Stopped between variants: V2 was filed into the HFT state, the shader for V3 had not
// finished. No current variant exists.
void TestResumeBetweenVariants(bool bV2Mined)
{
    std::cerr << "resume: stopped between variants, V2 " << (bV2Mined ? "mined" : "not mined") << std::endl;
    Env env(bV2Mined ? "cfb_hft_resume_b2.db" : "cfb_hft_resume_b1.db");
    ShaderRunCounter runs;

    HeightHash p1, p2;
    p1.m_Height = 100; p1.m_Hash = 0x11U;
    p2.m_Height = 101; p2.m_Hash = 0x22U;

    auto d = env.MakeData(p1);
    env.SetCommon(d, 100);

    TxKernel::Ptr k1 = MakeKernel(env.m_Cid, 100, 1);
    TxKernel::Ptr k2 = MakeKernel(env.m_Cid, 101, 2);
    Merkle::Hash id1 = KernelID(*k1), id2 = KernelID(*k2);

    std::vector<StoredVariant> v(2);
    v[0].m_Key.m_Height = 100;
    DependentContext::get_Ancestor(v[0].m_Key.m_Hash, p1.m_Hash, id1);
    v[0].m_Tx.m_vKernels.push_back(std::move(k1));
    v[0].m_Tx.m_Offset = Zero;
    v[1].m_Key.m_Height = 101;
    DependentContext::get_Ancestor(v[1].m_Key.m_Hash, p2.m_Hash, id2);
    v[1].m_Tx.m_vKernels.push_back(std::move(k2));
    v[1].m_Tx.m_Offset = Zero;
    env.Set(TxParameterID::HftState, HftStateBlob(d.get_FullSpend(), v));

    env.Set(TxParameterID::KernelUnconfirmedHeight, Height(100));
    env.Set(TxParameterID::State, ContractTransaction::State::RebuildHft);

    env.m_Gw.SetTip(101);

    env.Start();
    for (int i = 0; i < 4; i++)
    {
        env.AnswerAll(bV2Mined ? &id2 : nullptr, 101);
        env.Step();
    }

    Check(runs.get_Runs() == 0, "no app shader run (no new variant is built)");
    Check(env.m_Gw.m_Registered.empty(), "nothing is sent to the node");
    Check(env.m_Gw.WasQueried(id2), "V2's kernel is looked up");
    if (bV2Mined)
        Check(env.IsCompleted(), "the swap completes with V2");
    else
        Check(env.IsFailed() && !env.IsCompleted(), "the swap ends as failed (expired), nothing rebuilt");
}

// No restart: a freshly built variant is answered "Inputs missing" by the node (in the
// incident, the variants built on top of the wallet's own pending one). Stock builds rebuild
// at once; 0006 only confirms what was built.
void TestInputsMissing()
{
    std::cerr << "fresh trade answered \"Inputs missing\"" << std::endl;
    Env env("cfb_hft_resume_c.db");
    ShaderRunCounter runs;

    env.m_Gw.SetTip(100);
    env.m_pDB->get_History().AddStates(&env.m_Gw.m_Tip, 1);
    {
        HeightHash id;
        id.m_Height = 100;
        id.m_Hash = 0x100U;
        env.m_pDB->setSystemStateID(id);
    }

    Coin c(5 * Rules::Coin);
    c.m_status = Coin::Status::Available;
    c.m_maturity = 1;
    c.m_confirmHeight = 1;
    env.m_pDB->storeCoin(c);

    HeightHash p1;
    p1.m_Height = 101;
    p1.m_Hash = env.m_Gw.m_Tip.m_Prev;
    auto d = env.MakeData(p1);
    d.m_vec.front().m_Spend.erase(174); // BEAM only: no asset outputs at this test height
    env.SetCommon(d, 100);
    env.Set(TxParameterID::Status, TxStatus::Pending);

    env.Start();
    for (int i = 0; (i < 10) && env.m_Gw.m_Registered.empty(); i++)
        env.Step();

    Check(env.m_Gw.m_Registered.size() == 1, "the first variant is built and sent");
    if (env.m_Gw.m_Registered.size() != 1)
        return;
    Merkle::Hash id1 = env.m_Gw.m_Registered.front();

    // what Wallet::OnRequestComplete stores for that answer
    env.Set(TxParameterID::TransactionRegistered, static_cast<uint8_t>(proto::TxStatus::InvalidInput));
    env.Step();
    env.Step();

    Check(runs.get_Runs() == 0, "no app shader run after \"Inputs missing\"");
    Check(HasKernelParam(*env.m_pDB, env.m_TxID), "the variant stays current");
    Check(StoredVariantCount(*env.m_pDB, env.m_TxID) == 0, "no rebuild started (nothing filed away)");

    // block 101 without it
    env.m_Gw.SetTip(101);
    env.Step();
    env.AnswerAll(nullptr, 0);
    env.Step();
    env.AnswerAll(nullptr, 0);

    Check(env.m_Gw.WasQueried(id1), "its kernel is looked up");
    Check(env.IsFailed() && !env.IsCompleted(), "the trade ends as failed (expired)");
    Check(env.m_Gw.m_Registered.size() == 1, "no second variant was ever sent");
    Check(runs.get_Runs() == 0, "no app shader run at any point");
}

int main()
{
    auto logger = beam::Logger::create(BEAM_LOG_LEVEL_WARNING, BEAM_LOG_LEVEL_WARNING);
    Rules rules;
    for (size_t i = 1; i < _countof(rules.pForks); i++)
        rules.pForks[i].m_Height = 1; // contract and dependent kernels exist from the start
    rules.UpdateChecksum();
    Rules::Scope scopeRules(rules);

    TestResumeWithStaleData();
    TestResumeBetweenVariants(false);
    TestResumeBetweenVariants(true);
    TestInputsMissing();

    std::cerr << (g_Failures ? "FAILED: " : "PASSED: ") << g_Failures << " failed check(s)" << std::endl;
    return g_Failures ? 1 : 0;
}
