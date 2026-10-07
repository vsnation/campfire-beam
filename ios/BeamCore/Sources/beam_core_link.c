// Campfire for BEAM: keeps the BEAM core's C interface in BeamCore.framework.
//
// The linker copies an archive member into the framework only when something
// refers to it, and no native code in the app calls these functions: Dart looks
// them up at run time (lib/wallets/beam/host/beam_core_library.dart). This
// table is that reference. Sources/exported_symbols.txt then makes these seven
// the framework's only exports. Declarations: scripts/beam/core/ios/src/beam_wallet_api.h.

int beam_wallet_api_run(int argc, char** argv);
void beam_wallet_api_stop(void);
int beam_wallet_api_is_running(void);
const char* beam_wallet_api_version(void);
const char* beam_wallet_api_rules_signature(void);
int beam_wallet_api_init_wallet(const char* wallet_path, const char* password, const char* phrase);
int beam_wallet_api_check_wallet(const char* wallet_path, const char* password);

__attribute__((used)) static const void* const beam_core_exports[] = {
    (const void*)&beam_wallet_api_run,
    (const void*)&beam_wallet_api_stop,
    (const void*)&beam_wallet_api_is_running,
    (const void*)&beam_wallet_api_version,
    (const void*)&beam_wallet_api_rules_signature,
    (const void*)&beam_wallet_api_init_wallet,
    (const void*)&beam_wallet_api_check_wallet,
};
