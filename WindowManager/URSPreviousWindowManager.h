/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

// Canonical path of the program a process runs, or nil when it cannot be read
// (process gone, other user, no procfs).
NSString *URSExecutablePathForProcess(pid_t pid);

// The process a newly registered window manager may terminate, or 0.
// ownerPID is the _NET_WM_PID of the previous WM_Sn selection owner on our
// own display (0 when there was none), so window managers on other displays
// are never candidates even when they run the same program as the same user.
pid_t URSPreviousWindowManagerToTerminate(pid_t ownerPID,
                                          pid_t ownPID,
                                          NSString *ownExecutable,
                                          NSString *(^executableForPID)(pid_t pid));

// SIGTERM, then SIGKILL if the process is still there after two seconds.
void URSTerminateProcess(pid_t pid);
