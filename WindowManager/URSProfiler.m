//
//  URSProfiler.m
//  WindowManager — Lightweight CPU profiling instrumentation
//
//  Collects per-probe call counts, total/min/max times.
//  Dumps a sorted summary to stderr every URS_PROFILE_INTERVAL seconds.
//

#if URS_PROFILING

#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include "URSProfiler.h"

// ── Configuration ───────────────────────────────────────────────────

#ifndef URS_PROFILE_INTERVAL
#define URS_PROFILE_INTERVAL 10.0   /* seconds between automatic dumps */
#endif

#define URS_MAX_PROBES 64

// ── Probe storage ───────────────────────────────────────────────────

typedef struct {
    const char *name;
    uint64_t    callCount;
    uint64_t    totalNanos;
    uint64_t    minNanos;
    uint64_t    maxNanos;
} URSProbeStats;

static URSProbeStats sProbes[URS_MAX_PROBES];
static int           sProbeCount = 0;
static struct timespec sLastDump;
static int           sInitialized = 0;
static volatile sig_atomic_t sDumpRequested = 0;

// ── Internal helpers ────────────────────────────────────────────────

static void ensureInitialized(void) {
    if (sInitialized) return;
    clock_gettime(CLOCK_MONOTONIC, &sLastDump);
    sInitialized = 1;
}

static uint64_t elapsedSinceDump(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)(now.tv_sec - sLastDump.tv_sec) * 1000000000ULL
         + (uint64_t)(now.tv_nsec - sLastDump.tv_nsec);
}

static int compareByTotal(const void *a, const void *b) {
    const URSProbeStats *pa = (const URSProbeStats *)a;
    const URSProbeStats *pb = (const URSProbeStats *)b;
    if (pb->totalNanos > pa->totalNanos) return 1;
    if (pb->totalNanos < pa->totalNanos) return -1;
    return 0;
}

// ── Public API ──────────────────────────────────────────────────────

int ursProbeRegister(const char *name) {
    ensureInitialized();
    // Linear scan is fine — only called once per probe site (static local caches index).
    for (int i = 0; i < sProbeCount; i++) {
        if (sProbes[i].name == name) return i;   // pointer comparison — same literal
    }
    if (sProbeCount >= URS_MAX_PROBES) {
        fprintf(stderr, "[Profile] WARNING: probe limit (%d) reached, ignoring '%s'\n",
                URS_MAX_PROBES, name);
        return 0;
    }
    int idx = sProbeCount++;
    sProbes[idx].name = name;
    sProbes[idx].callCount = 0;
    sProbes[idx].totalNanos = 0;
    sProbes[idx].minNanos = UINT64_MAX;
    sProbes[idx].maxNanos = 0;
    return idx;
}

void ursProbeRecord(int index, uint64_t nanos) {
    URSProbeStats *p = &sProbes[index];
    p->callCount++;
    p->totalNanos += nanos;
    if (nanos < p->minNanos) p->minNanos = nanos;
    if (nanos > p->maxNanos) p->maxNanos = nanos;

    // Drain any pending signal-triggered dump request (safe: called on runloop thread)
    if (sDumpRequested) {
        sDumpRequested = 0;
        ursProfileDump();
        return;
    }

    // Auto-dump every URS_PROFILE_INTERVAL seconds
    uint64_t intervalNs = (uint64_t)(URS_PROFILE_INTERVAL * 1e9);
    if (elapsedSinceDump() >= intervalNs) {
        ursProfileDump();
    }
}

void ursProfileDump(void) {
    if (sProbeCount == 0) return;

    // Compute wall-clock interval
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double interval = (double)(now.tv_sec - sLastDump.tv_sec)
                    + (double)(now.tv_nsec - sLastDump.tv_nsec) / 1e9;
    sLastDump = now;

    // Sort a copy by total time descending
    URSProbeStats sorted[URS_MAX_PROBES];
    memcpy(sorted, sProbes, sizeof(URSProbeStats) * sProbeCount);
    qsort(sorted, sProbeCount, sizeof(URSProbeStats), compareByTotal);

    fprintf(stderr,
            "\n═══ WindowManager Profile (%.1fs) ══════════════════════════════════════\n"
            "%-28s %8s %10s %10s %10s %10s\n",
            interval,
            "Probe", "Calls", "Total ms", "Avg µs", "Min µs", "Max µs");

    for (int i = 0; i < sProbeCount; i++) {
        URSProbeStats *p = &sorted[i];
        if (p->callCount == 0) continue;

        double totalMs = (double)p->totalNanos / 1e6;
        double avgUs   = (double)p->totalNanos / (double)p->callCount / 1e3;
        double minUs   = (double)p->minNanos / 1e3;
        double maxUs   = (double)p->maxNanos / 1e3;

        fprintf(stderr, "%-28s %8llu %10.1f %10.1f %10.1f %10.1f\n",
                p->name,
                (unsigned long long)p->callCount,
                totalMs, avgUs, minUs, maxUs);
    }
    fprintf(stderr,
            "════════════════════════════════════════════════════════════════════════\n\n");

    // Reset counters for next interval
    for (int i = 0; i < sProbeCount; i++) {
        sProbes[i].callCount = 0;
        sProbes[i].totalNanos = 0;
        sProbes[i].minNanos = UINT64_MAX;
        sProbes[i].maxNanos = 0;
    }
}

// ── Signal handler ──────────────────────────────────────────────────

static void ursProfileSignalHandler(int sig) {
    (void)sig;
    sDumpRequested = 1;         /* async-signal-safe: just set a flag */
}

void ursProfileInstallSignalHandler(void) {
    ensureInitialized();
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = ursProfileSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGUSR1, &sa, NULL);
    fprintf(stderr, "[Profile] Instrumentation active — dump with: kill -USR1 %d\n", getpid());
}

#endif /* URS_PROFILING */
