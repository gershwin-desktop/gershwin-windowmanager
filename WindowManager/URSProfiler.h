//
//  URSProfiler.h
//  WindowManager — Lightweight CPU profiling instrumentation
//
//  Enabled at compile time with -DURS_PROFILING=1.
//  When disabled, all macros compile to nothing (zero overhead).
//
//  Usage:
//      URS_PROFILE_BEGIN(paintAll);
//      ... work ...
//      URS_PROFILE_END(paintAll);
//
//  A summary is printed to stderr every URS_PROFILE_INTERVAL seconds
//  and on demand via SIGUSR1.
//

#ifndef URS_PROFILER_H
#define URS_PROFILER_H

#if URS_PROFILING

#include <time.h>
#include <stdint.h>

// ── Public API ──────────────────────────────────────────────────────

/// Register a named probe and return its index (idempotent per name).
int ursProbeRegister(const char *name);

/// Record a measurement for the given probe index.
void ursProbeRecord(int index, uint64_t nanos);

/// Print the current stats table to stderr and reset counters.
void ursProfileDump(void);

/// Install SIGUSR1 handler for on-demand dumps. Call once at startup.
void ursProfileInstallSignalHandler(void);

// ── Macros ──────────────────────────────────────────────────────────

#define URS_PROFILE_BEGIN(label) \
    struct timespec _urs_ts_##label; \
    clock_gettime(CLOCK_MONOTONIC, &_urs_ts_##label)

#define URS_PROFILE_END(label) do { \
    struct timespec _urs_te_##label; \
    clock_gettime(CLOCK_MONOTONIC, &_urs_te_##label); \
    uint64_t _urs_ns_##label = \
        (uint64_t)(_urs_te_##label.tv_sec - _urs_ts_##label.tv_sec) * 1000000000ULL \
        + (uint64_t)(_urs_te_##label.tv_nsec - _urs_ts_##label.tv_nsec); \
    static int _urs_idx_##label = -1; \
    if (_urs_idx_##label == -1) _urs_idx_##label = ursProbeRegister(#label); \
    ursProbeRecord(_urs_idx_##label, _urs_ns_##label); \
} while (0)

#else /* URS_PROFILING disabled */

#define URS_PROFILE_BEGIN(label)  ((void)0)
#define URS_PROFILE_END(label)    ((void)0)

static inline void ursProfileInstallSignalHandler(void) {}
static inline void ursProfileDump(void) {}

#endif /* URS_PROFILING */
#endif /* URS_PROFILER_H */
