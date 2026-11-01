/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The pointer over the root window, and the cursor size other applications
// are told.  The root window has one cursor for all monitors, so the window
// manager changes it when the pointer crosses into a monitor with another
// factor: it watches pointer motion on the root, which reaches it only while
// the pointer is over the root itself or over a window nobody else watches
// motion on (frames and GNUstep windows do), so this costs nothing while
// the pointer is over an application.  Applications that are not GNUstep
// read Xcursor.size once when they start and cannot follow the monitors;
// they are given the size of the primary monitor.

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>

@class XCBConnection;

@interface URSPointerCursor : NSObject

+ (instancetype)sharedPointerCursor;

// Watch the root window, give it the cursor for where the pointer is now
// and publish Xcursor.size.
- (void)startWithConnection:(XCBConnection *)connection;

// The pointer moved on the root window (root coordinates).
- (void)pointerAtRootX:(int16_t)x y:(int16_t)y;

// The monitors or their factors changed: the same again.
- (void)outputScalesChanged;

@end
