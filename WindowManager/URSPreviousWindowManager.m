/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSPreviousWindowManager.h"
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static NSString *URSReadLink(NSString *linkPath)
{
    char buffer[PATH_MAX];
    ssize_t len = readlink([linkPath fileSystemRepresentation], buffer, sizeof(buffer) - 1);
    if (len == -1) {
        return nil;
    }
    buffer[len] = '\0';
    return [NSString stringWithUTF8String:buffer];
}

NSString *URSExecutablePathForProcess(pid_t pid)
{
    // Linux procfs names it exe, the BSD procfs file.
    NSString *linked = URSReadLink([NSString stringWithFormat:@"/proc/%d/exe", (int)pid]);
    if (!linked) {
        linked = URSReadLink([NSString stringWithFormat:@"/proc/%d/file", (int)pid]);
    }
    if (!linked) {
        return nil;
    }
    char resolved[PATH_MAX];
    if (realpath([linked fileSystemRepresentation], resolved) == NULL) {
        return linked;
    }
    return [NSString stringWithUTF8String:resolved];
}

pid_t URSPreviousWindowManagerToTerminate(pid_t ownerPID,
                                          pid_t ownPID,
                                          NSString *ownExecutable,
                                          NSString *(^executableForPID)(pid_t pid))
{
    if (ownerPID <= 0 || ownerPID == ownPID || ownExecutable == nil) {
        return 0;
    }
    // Another window manager program quits by itself on SelectionClear; only
    // a hung copy of ourselves is ours to put down.
    if (![executableForPID(ownerPID) isEqualToString:ownExecutable]) {
        return 0;
    }
    return ownerPID;
}

void URSTerminateProcess(pid_t pid)
{
    NSLog(@"[WindowManager] Terminating previous window manager with PID %d", (int)pid);
    kill(pid, SIGTERM);
    for (int waitedMs = 0; waitedMs < 2000; waitedMs += 100) {
        usleep(100000);
        if (kill(pid, 0) != 0) {
            return;
        }
    }
    NSLog(@"[WindowManager] Force killing previous window manager with PID %d", (int)pid);
    kill(pid, SIGKILL);
}
