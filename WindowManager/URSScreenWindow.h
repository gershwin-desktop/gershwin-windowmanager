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

@end
