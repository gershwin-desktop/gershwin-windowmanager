/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Makes NSWorkspace in this process answer from what it knows locally and
// never contact, launch or wait for the workspace application.  ownPort is
// the name this process is registered under as a services provider.
//
// A window manager must not depend on the desktop it manages: when Workspace
// did not answer, -[NSWorkspace launchedApplications] from the window switcher
// started a second Workspace, which killed the running one, and then opened a
// modal "seems to have hung" panel out of the event handler.  While that panel
// waited the run loop never ran its default mode again, so timers,
// distributed notifications and with them every theme change went unheard.
void URSStopContactingWorkspaceApplication(NSString *ownPort);
