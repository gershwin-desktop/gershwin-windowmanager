/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class XCBTitleBar;

/*
 * The titlebars the theme integration draws: the set it walks to re-render
 * every titlebar and to find the one an Expose is for.  Foundation only, so
 * its ownership rules can be tested without an X server.
 */
@interface URSTitlebarRegistry : NSObject

// Adding a titlebar that is already registered changes nothing.
- (void)addTitlebar:(XCBTitleBar *)titlebar;
- (NSUInteger)count;

// A copy, so drawing a titlebar may register or drop others meanwhile.
- (NSArray *)titlebars;

@end
