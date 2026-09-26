/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class XCBConnection;
@class XCBFrame;
@class URSWindowSwitcher;

// A managed window on the screen, as a presentation sees it.
@interface URSScreenWindow : NSObject

@property (strong, nonatomic) XCBFrame *frame;
@property (copy, nonatomic) NSString *title;
// Root pixels, y down, borders included.
@property (assign, nonatomic) NSRect windowRect;

// The decorated document windows that are not minimized, bottom to top;
// palettes are left out (URSWindowListFilter).  Called on a subclass, it
// makes instances of that subclass.
+ (NSArray *)windowsOnScreenOfConnection:(XCBConnection *)connection
                          windowSwitcher:(URSWindowSwitcher *)windowSwitcher;

// Frame ids (NSNumber) of the palettes the list above leaves out, which a
// presentation fades away rather than leaving them over its scene.
+ (NSSet *)utilityPanelsOfConnection:(XCBConnection *)connection;

// Frame ids (NSNumber) of floating windows the list above also leaves out -
// Stickies notes and any other client window that asks for
// NSFloatingWindowLevel without the GNUstep utility style bit.  Distinct
// from the palette set above: whether a presentation fades these out or
// leaves them in place is a user choice (URSOverviewUtilityWindowsKey).
+ (NSSet *)floatingWindowsOfConnection:(XCBConnection *)connection;

// Top-level windows typed _NET_WM_WINDOW_TYPE_DOCK (the Menu bar and the
// Dock), as frame ids (NSNumber), which a presentation fades away so the
// whole screen is free.
+ (NSSet *)dockWindowsOfConnection:(XCBConnection *)connection;

@end
