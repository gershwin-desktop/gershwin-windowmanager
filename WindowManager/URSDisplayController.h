/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Keeps the desktop usable while monitors come and go.  At login and after
// every RandR change it runs "displayconfig apply" (gershwin-components),
// which brings the server to the user's saved layout for the connected
// monitors and always sets a RandR primary.  Once the layout has settled it
// learns the lit monitors, brings back windows that ended up where no
// monitor is, and moves the pointer onto the primary if its monitor went
// away.

#import <Foundation/Foundation.h>

@class XCBConnection;
@class URSWorkareaManager;
@class URSTitlebarController;

@interface URSDisplayController : NSObject

- (instancetype)initWithConnection:(XCBConnection *)connection
                   workareaManager:(URSWorkareaManager *)workareaManager
                titlebarController:(URSTitlebarController *)titlebarController;

// A RandR screen, CRTC or output change arrived; a hotplug sends several,
// so the work starts once they have stopped for a moment.
- (void)screenChanged;

// An output's connection state as an output change event reports it.  Only
// a monitor plugged in or out runs displayconfig; other changes (the
// Display pane, xrandr) are left alone and only lead to window rescue.
- (void)output:(uint32_t)output connected:(BOOL)connected;

@end
