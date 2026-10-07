// Campfire for BEAM: the one BEAM logger of libbeam_core (beam_core_init).
//
// BEAM's logger is a process-wide singleton (beam::Logger::g_logger), and stock
// Logger::create() throws when one exists. wallet-api's main() and beam-node's
// main() each create their own and destroy it on exit, which inside one process
// would leave the other's threads logging through a dead object. So libbeam_core
// has exactly one logger, created here and never destroyed; wallet-api's call to
// Logger::create is redirected to it (beam_core_wallet_api.cpp).
//
// The logger is BEAM's format ("I 2026-10-07.12:00:00.123 message"), written to the
// console (stdout) and/or a file. Files: <log_dir>/beam_core_<yy_mm_dd_HH_MM_SS>.log,
// 0600, a new one each day or past 16 MB; files older than 3 days are deleted.
// The node's "Owned accounts :" listing (endpoints derived from the owner key, which
// identify the wallet) is reduced to a count.
#include "beam_core.h"
#include "beam_core_internal.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>

#include <boost/filesystem.hpp>

#include "utility/common.h"
#include "utility/helpers.h"

#ifdef _WIN32
#include <share.h>
#else
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace campfire_core
{
    namespace fs = boost::filesystem;

    namespace
    {
        const char* const kFilePrefix = "beam_core_";
        const uint64_t kMaxFileBytes = 16ull * 1024 * 1024;
        const unsigned kKeepDays = 3;
        const char* const kOwnedAccounts = "Owned accounts :";

        fs::path PathOf(const std::string& utf8)
        {
#ifdef _WIN32
            return fs::path(beam::Utf8toUtf16(utf8.c_str()));
#else
            return fs::path(utf8);
#endif
        }

        // Deletes <prefix>*.log in dir older than kKeepDays. Best effort.
        void PruneOldFiles(const fs::path& dir, const std::string& prefix)
        {
            try
            {
                const std::time_t cutoff = std::time(nullptr) - std::time_t(kKeepDays) * 86400;
                for (fs::directory_iterator it(dir), end; it != end; ++it)
                {
                    const fs::path p = it->path();
                    const std::string name = p.filename().string();
                    if (name.compare(0, prefix.size(), prefix) != 0 || p.extension().string() != ".log")
                        continue;
                    boost::system::error_code ec;
                    if (fs::is_regular_file(p, ec) && fs::last_write_time(p, ec) < cutoff)
                        fs::remove(p, ec);
                }
            }
            catch (...)
            {
            }
        }

        class CoreLogger final : public beam::Logger
        {
        public:
            CoreLogger(int consoleLevel, int fileLevel, const std::string& dir, const std::string& prefix)
                : m_consoleLevel(consoleLevel)
                , m_fileLevel(dir.empty() ? 0 : fileLevel)
                , m_dir(dir)
                , m_prefix(prefix)
            {
                int minLevel = 0;
                if (m_consoleLevel > 0) minLevel = m_consoleLevel;
                if (m_fileLevel > 0) minLevel = minLevel ? std::min(minLevel, m_fileLevel) : m_fileLevel;
                m_minLevel = minLevel ? minLevel : 1000; // no sink: nothing is accepted
                if (m_fileLevel > 0)
                {
                    PruneOldFiles(PathOf(m_dir), m_prefix);
                    OpenFile(); // throws if the file cannot be created
                }
            }

            // Never called: the logger lives until the process exits.
            ~CoreLogger() override
            {
                if (g_logger == this) g_logger = nullptr;
                if (m_file) fclose(m_file);
            }

            void Install() { g_logger = this; }

            void set_header_formatter(beam::LogMessageHeaderFormatter formatter) override
            {
                if (formatter) m_headerFormatter = formatter;
            }

            void set_time_format(const char* format, bool printMilliseconds) override
            {
                std::lock_guard<std::mutex> guard(m_lock);
                m_timeFormat = format ? format : "";
                m_printMs = format ? printMilliseconds : false;
            }

            const FileNameType& get_current_file_name() override
            {
                return m_fileName;
            }

            void rotate() override
            {
                std::lock_guard<std::mutex> guard(m_lock);
                if (m_fileLevel > 0)
                {
                    try { OpenFile(); } catch (...) {}
                }
            }

        protected:
            bool level_accepted(int level) override
            {
                return level >= m_minLevel;
            }

            void write_message(const beam::LogMessageHeader& header, const char* buf, size_t size) override
            {
                std::string redacted;
                if (size > std::strlen(kOwnedAccounts) && std::strncmp(buf, kOwnedAccounts, std::strlen(kOwnedAccounts)) == 0)
                {
                    // "Owned accounts :\n\t<endpoint>\n..." -> the count only.
                    size_t n = 0;
                    for (size_t i = 0; i + 1 < size; i++)
                        if (buf[i] == '\n' && buf[i + 1] == '\t') n++;
                    redacted = std::string(kOwnedAccounts) + " " + std::to_string(n) + " (endpoints withheld)\n";
                    buf = redacted.data();
                    size = redacted.size();
                }

                std::lock_guard<std::mutex> guard(m_lock);
                char ts[80];
                char head[256];
                if (!m_timeFormat.empty())
                    beam::format_timestamp(ts, sizeof(ts), m_timeFormat.c_str(), header.timestamp, m_printMs);
                else
                    ts[0] = 0;
                size_t headSize = m_headerFormatter(head, sizeof(head), ts, header);
                headSize = std::min(headSize, sizeof(head) - 1);

                if (m_consoleLevel > 0 && header.level >= m_consoleLevel)
                {
                    fwrite(head, 1, headSize, stdout);
                    fwrite(buf, 1, size, stdout);
                    fflush(stdout);
                }
                if (m_fileLevel > 0 && header.level >= m_fileLevel)
                {
                    MaybeRotate(header.timestamp);
                    if (m_file)
                    {
                        fwrite(head, 1, headSize, m_file);
                        fwrite(buf, 1, size, m_file);
                        fflush(m_file);
                        m_fileBytes += headSize + size;
                    }
                }
            }

        private:
            void MaybeRotate(uint64_t timestampMs)
            {
                const std::string day = beam::format_timestamp("%y_%m_%d", timestampMs, false);
                if (m_fileBytes < kMaxFileBytes && day == m_fileDay)
                    return;
                try
                {
                    OpenFile();
                    PruneOldFiles(PathOf(m_dir), m_prefix);
                }
                catch (...)
                {
                }
            }

            // Caller holds m_lock (or is the constructor).
            void OpenFile()
            {
                const uint64_t now = beam::local_timestamp_msec();
                std::string name = m_prefix + beam::format_timestamp("%y_%m_%d_%H_%M_%S", now, false);
                fs::path path = PathOf(m_dir) / (name + ".log");
                for (int i = 1; fs::exists(path) && i < 100; i++)
                    path = PathOf(m_dir) / (name + "_" + std::to_string(i) + ".log");

                FILE* f = nullptr;
#ifdef _WIN32
                f = _wfsopen(path.wstring().c_str(), L"ab", _SH_DENYNO);
#else
                int fd = ::open(path.string().c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
                if (fd >= 0)
                {
                    ::fchmod(fd, 0600);
                    f = fdopen(fd, "ab");
                    if (!f) ::close(fd);
                }
#endif
                if (!f)
                    throw std::runtime_error("cannot open log file");
                if (m_file)
                    fclose(m_file);
                m_file = f;
                m_fileBytes = 0;
                m_fileDay = beam::format_timestamp("%y_%m_%d", now, false);
#ifdef _WIN32
                m_fileName = path.wstring();
#else
                m_fileName = path.string();
#endif
            }

            std::mutex m_lock;
            const int m_consoleLevel;
            const int m_fileLevel;
            int m_minLevel = 1000;
            const std::string m_dir;
            const std::string m_prefix;
            beam::LogMessageHeaderFormatter m_headerFormatter = beam::def_header_formatter;
            std::string m_timeFormat = "%Y-%m-%d.%T";
            bool m_printMs = true;
            FILE* m_file = nullptr;
            uint64_t m_fileBytes = 0;
            std::string m_fileDay;
            FileNameType m_fileName;
        };

        std::mutex g_initLock;
        CoreLogger* g_core = nullptr; // set once, never freed

        bool ValidLevel(int level)
        {
            return level >= 0 && level <= BEAM_LOG_LEVEL_CRITICAL;
        }

        // Creates the log directory 0700 when it does not exist.
        bool PrepareDir(const std::string& dir)
        {
            try
            {
                const fs::path p = PathOf(dir);
                if (!fs::exists(p))
                {
                    fs::create_directories(p);
#ifndef _WIN32
                    ::chmod(p.string().c_str(), 0700);
#endif
                }
                return fs::is_directory(p);
            }
            catch (...)
            {
                return false;
            }
        }

        // Caller holds g_initLock.
        int CreateLocked(int consoleLevel, int fileLevel, const std::string& dir, const std::string& prefix)
        {
            if (g_core)
                return BEAM_CORE_ALREADY_INITIALIZED;
#if !defined(_WIN32) && !defined(__APPLE__)
            // libuv writes to sockets with write(); on Linux and Android a peer that
            // went away would raise SIGPIPE, whose default action kills the app.
            // (Apple platforms: libuv sets SO_NOSIGPIPE on every socket.) Only the
            // default disposition is changed; a handler the app installed is kept.
            struct sigaction current;
            if (::sigaction(SIGPIPE, nullptr, &current) == 0 && current.sa_handler == SIG_DFL)
                ::signal(SIGPIPE, SIG_IGN);
#endif
            if (fileLevel > 0 && !dir.empty() && !PrepareDir(dir))
                return BEAM_CORE_LOG_DIR_FAILED;
            try
            {
                auto* logger = new CoreLogger(consoleLevel, fileLevel, dir, prefix);
                logger->Install();
                g_core = logger;
            }
            catch (...)
            {
                return BEAM_CORE_LOG_DIR_FAILED;
            }
            return BEAM_CORE_OK;
        }
    }

    std::shared_ptr<beam::Logger> LoggerForWalletApi(int consoleLevel, int fileLevel,
                                                     const std::string& prefix, const std::string& dir)
    {
        std::lock_guard<std::mutex> guard(g_initLock);
        if (!g_core)
        {
            int rc = CreateLocked(ValidLevel(consoleLevel) ? consoleLevel : BEAM_LOG_LEVEL_INFO,
                                  ValidLevel(fileLevel) ? fileLevel : BEAM_LOG_LEVEL_INFO, dir, prefix);
            if (rc != BEAM_CORE_OK && rc != BEAM_CORE_ALREADY_INITIALIZED)
                CreateLocked(ValidLevel(consoleLevel) ? consoleLevel : BEAM_LOG_LEVEL_INFO, 0, std::string(), prefix);
        }
        // Not owning: wallet-api's main() drops it on exit, the logger stays.
        return std::shared_ptr<beam::Logger>(g_core, [](beam::Logger*) {});
    }

    void EnsureLogger()
    {
        std::lock_guard<std::mutex> guard(g_initLock);
        if (!g_core)
            CreateLocked(BEAM_LOG_LEVEL_WARNING, 0, std::string(), kFilePrefix);
    }

    uint64_t NowMs()
    {
        using namespace std::chrono;
        return uint64_t(duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count());
    }
}

extern "C" BEAM_CORE_API int beam_core_init(const char* log_dir, int console_level, int file_level)
{
    using namespace campfire_core;
    if (!ValidLevel(console_level) || !ValidLevel(file_level))
        return BEAM_CORE_INVALID_ARGUMENT;
    const std::string dir = log_dir ? log_dir : "";
    std::lock_guard<std::mutex> guard(g_initLock);
    return CreateLocked(console_level, dir.empty() ? 0 : file_level, dir, kFilePrefix);
}
