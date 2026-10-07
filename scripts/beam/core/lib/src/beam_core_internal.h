// Campfire for BEAM: internals shared by the libbeam_core sources. Not installed.
#pragma once

#include <cstdint>
#include <memory>
#include <string>

#include "utility/logger.h"

namespace campfire_core
{
    // The process-wide logger (beam_core_log.cpp). Created once, never destroyed:
    // wallet-api and the node log from their own threads, and either may outlive
    // the other.

    // For wallet-api's main(): the logger of the process. If beam_core_init() was
    // not called, it is created now from wallet-api's own options (levels, file
    // prefix, directory), which is what stock wallet-api would do. The returned
    // pointer does not own the logger.
    std::shared_ptr<beam::Logger> LoggerForWalletApi(int consoleLevel, int fileLevel,
                                                     const std::string& prefix, const std::string& dir);

    // For the node thread: makes sure a logger exists (console at warning if
    // beam_core_init() was not called).
    void EnsureLogger();

    // Unix time in milliseconds.
    uint64_t NowMs();
}
