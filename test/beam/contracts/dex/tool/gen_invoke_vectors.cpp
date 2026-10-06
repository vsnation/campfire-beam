// Generates test/beam/contracts/dex/fixtures/raw_data_vectors.json entries.
//
// Serializes bvm2::ContractInvokeData-shaped values with BEAM's own vendored
// yas library and the exact options of utility/serialize.h, following the
// field order of bvm/invoke_data.h, and prints "<name> <hex>" per vector.
// The Dart decoder (lib/wallets/beam/contracts/common/invoke_data.dart) is
// tested against these bytes.
//
//   clang++ -std=c++17 -I <beam-source>/3rdparty gen_invoke_vectors.cpp \
//       -o gen && ./gen
//
// <beam-source> is a checkout of github.com/BeamMW/beam at beam-7.5.14493.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "yas/binary_oarchive.hpp"
#include "yas/std_types.hpp"

constexpr int SERIALIZE_OPTIONS = yas::binary | yas::no_header | yas::elittle | yas::compacted;

struct Os {
    std::vector<uint8_t> buf;
    size_t write(const void* p, size_t n) {
        auto b = static_cast<const uint8_t*>(p);
        buf.insert(buf.end(), b, b + n);
        return n;
    }
};

struct Hash32 {  // beam::uintBig_t<32>: serialized as `ar & m_pData`
    uint8_t m_pData[32];
    template <class Ar> void serialize(Ar& ar) { ar & m_pData; }
};

struct Entry {
    uint32_t m_Flags = 0;
    Hash32 m_Cid{};
    uint32_t m_iMethod = 0;
    std::vector<uint8_t> m_Data;
    std::vector<uint8_t> m_Args;
    std::vector<Hash32> m_vSig;
    uint32_t m_Charge = 0;
    uint64_t m_ParentHeight = 0;
    Hash32 m_ParentHash{};
    std::map<uint32_t, int64_t> m_Spend;
    std::string m_sComment;

    template <class Ar> void save(Ar& ar) const {
        static const uint32_t nHasFlags = 0x80000000;
        uint32_t nVal = m_Flags ? (nHasFlags | m_Flags) : m_iMethod;
        ar & nVal;
        if (nHasFlags & nVal) ar & m_iMethod;
        ar & m_Args & m_vSig & m_Charge & m_sComment & m_Spend;
        if (m_iMethod) ar & m_Cid; else ar & m_Data;
        if (2 & m_Flags) ar & m_ParentHeight & m_ParentHash;  // Dependent
    }
};

struct App {
    std::vector<uint8_t> m_App, m_Contract;
    std::map<std::string, std::string> m_Args;
    uint32_t m_Privilege = 0;
};

static void hexcid(Hash32& h, const char* s) {
    for (int i = 0; i < 32; i++) { unsigned v; sscanf(s + 2 * i, "%2x", &v); h.m_pData[i] = (uint8_t)v; }
}

static void emit(const char* name, const std::vector<Entry>& v, const App* app,
                 const std::map<uint32_t, int64_t>* spendMax) {
    Os os;
    yas::binary_oarchive<Os, SERIALIZE_OPTIONS> ar(os);
    uint64_t n = v.size();
    ar & n;  // write_seq_size for the vector
    for (auto& e : v) e.save(ar);
    if (app) ar & app->m_App & app->m_Contract & app->m_Args & app->m_Privilege;
    if (spendMax) ar & *spendMax;
    printf("%s ", name);
    for (auto b : os.buf) printf("%02x", b);
    printf("\n");
}

int main() {
    const char* dex = "729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf";

    // 1. A plain (not dependent) trade: pay 0.1 BEAM, receive 0.80368764 FOMO.
    Entry t;
    t.m_iMethod = 7;
    hexcid(t.m_Cid, dex);
    t.m_Args.assign(17, 0);  // sizeof(Amm::Method::Trade)
    t.m_Args[0] = 174; t.m_Args[8] = 2;
    t.m_sComment = "Amm trade";
    t.m_Spend = {{0, 10000000}, {174, -80368764}};
    emit("trade_plain", {t}, nullptr, nullptr);

    // 2. A dependent add-liquidity with stored app args, a signature, and a
    //    parent context: pays BEAM + FOMO, receives LP 175.
    Entry a;
    a.m_Flags = 0x02 | 0x20;  // Dependent | SaveAppInvoke
    a.m_iMethod = 5;
    hexcid(a.m_Cid, dex);
    a.m_Args.assign(25, 7);
    Hash32 sig; memset(sig.m_pData, 0xab, 32); a.m_vSig = {sig};
    a.m_sComment = "Amm add";
    a.m_Spend = {{0, 10000000}, {174, 81173706}, {175, -33347624}};
    a.m_ParentHeight = 4068104;
    memset(a.m_ParentHash.m_pData, 0xcd, 32);
    App app;
    app.m_App.assign(300, 0x5a);
    app.m_Args = {{"action", "pool_add_liquidity"}, {"cid", dex}, {"aid1", "0"},
                  {"aid2", "174"}, {"kind", "2"}, {"val1", "10000000"},
                  {"val2", "0"}, {"bPredictOnly", "0"}};
    emit("add_dependent", {a}, &app, nullptr);

    // 3. Integer edges: a deployment (method 0, data instead of cid), the
    //    pool_create charge, unsigned 127/128 and signed 63/64 boundaries,
    //    a 2^62 magnitude, an explicit spend max.
    Entry d;
    d.m_Flags = 0x02 | 0x20 | 0x40;
    d.m_iMethod = 0;
    d.m_Data.assign(200, 0x11);
    d.m_Args.assign(128, 1);
    d.m_Charge = 137100;
    d.m_sComment = "edges";
    d.m_Spend = {{0, 1000000000}, {127, 63}, {128, -64}, {4294967295u, -(int64_t(1) << 62)}};
    d.m_ParentHeight = 127;
    App app2;
    app2.m_Privilege = 1;
    std::map<uint32_t, int64_t> smax = {{0, 1000000001}};
    emit("edges", {d}, &app2, &smax);

    // 4. pool_create: method 3, the declared charge, locks 10 BEAM.
    Entry c;
    c.m_iMethod = 3;
    hexcid(c.m_Cid, dex);
    c.m_Args.assign(42, 0);  // Pool::ID 9 + PubKey 33
    c.m_Charge = 137100;
    c.m_sComment = "Amm create pool";
    c.m_Spend = {{0, 1000000000}};
    emit("create_pool", {c}, nullptr, nullptr);

    // 5. pool_withdraw: burns 1 LP-175, receives BEAM + FOMO.
    Entry w;
    w.m_iMethod = 6;
    hexcid(w.m_Cid, dex);
    w.m_Args.assign(17, 0);
    w.m_sComment = "Amm withdraw";
    w.m_Spend = {{0, -29987143}, {174, -243416758}, {175, 100000000}};
    emit("withdraw", {w}, nullptr, nullptr);
    return 0;
}
