// Campfire for BEAM: the threads libbeam_core starts (wallet-api instances, the
// node). Not installed.
//
// wallet-api and beam-node normally run on a process's main thread (8 MB stack on
// macOS and Linux). std::thread gives 512 KB on macOS, so on POSIX these threads are
// created with an explicit 8 MB stack. Windows: std::thread (1 MB, the same as the
// main thread of the stock executables).
#pragma once

#include <functional>
#include <memory>
#include <stdexcept>

#ifdef _WIN32
#include <thread>
#else
#include <pthread.h>
#endif

namespace campfire_core
{
    class CoreThread
    {
    public:
        static constexpr size_t kStackBytes = 8u * 1024 * 1024;

        // Starts fn on a new thread. Throws std::runtime_error if it cannot.
        explicit CoreThread(std::function<void()> fn)
        {
#ifdef _WIN32
            m_thread = std::thread(std::move(fn));
#else
            auto* heapFn = new std::function<void()>(std::move(fn));
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_setstacksize(&attr, kStackBytes);
            const int rc = pthread_create(&m_thread, &attr, &CoreThread::Entry, heapFn);
            pthread_attr_destroy(&attr);
            if (rc != 0)
            {
                delete heapFn;
                throw std::runtime_error("pthread_create failed");
            }
#endif
            m_joinable = true;
        }

        CoreThread(const CoreThread&) = delete;
        CoreThread& operator=(const CoreThread&) = delete;

        // Never destroy a running thread: the owner joins first, or leaks the
        // object (at process exit a destructor must not wait for a thread).
        ~CoreThread() = default;

        bool joinable() const { return m_joinable; }

        void join()
        {
            if (!m_joinable)
                return;
#ifdef _WIN32
            m_thread.join();
#else
            pthread_join(m_thread, nullptr);
#endif
            m_joinable = false;
        }

    private:
#ifdef _WIN32
        std::thread m_thread;
#else
        pthread_t m_thread;
        static void* Entry(void* p)
        {
            std::unique_ptr<std::function<void()>> fn(static_cast<std::function<void()>*>(p));
            (*fn)();
            return nullptr;
        }
#endif
        bool m_joinable = false;
    };
}
