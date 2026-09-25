/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The theme's list of drawn titlebars must not be what keeps a closed
// window's titlebar alive: the titlebar points back at its frame, so every
// titlebar the list held on to kept a whole frame, its cursor, shape and
// attributes for the life of the window manager.
// Headless.  Run with:  gnustep-tests test-titlebarregistry

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "URSTitlebarRegistry.h"

static NSUInteger freed = 0;

// Stands in for an XCBTitleBar: only its lifetime matters here
@interface FakeTitlebar : NSObject
@end

@implementation FakeTitlebar
- (void)dealloc
{
  freed++;
  [super dealloc];
}
@end

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  URSTitlebarRegistry *registry = [URSTitlebarRegistry new];
  FakeTitlebar *kept = [FakeTitlebar new];
  FakeTitlebar *closed = [FakeTitlebar new];

  [registry addTitlebar: (XCBTitleBar *)kept];
  [registry addTitlebar: (XCBTitleBar *)kept];
  PASS([registry count] == 1, "adding the same titlebar twice registers it once");

  NSAutoreleasePool *inner = [NSAutoreleasePool new];
  [registry addTitlebar: (XCBTitleBar *)closed];
  PASS([registry count] == 2, "a second titlebar is registered");
  [inner release];

  // The window closed: its frame, the titlebar's only owner, let go
  [closed release];
  PASS(freed == 1, "a titlebar nobody else owns is freed although it is registered");

  inner = [NSAutoreleasePool new];
  NSArray *left = [registry titlebars];
  PASS([left count] == 1 && [left objectAtIndex: 0] == kept,
       "a freed titlebar is no longer listed, the live one still is");
  PASS([registry count] == 1, "the count drops with the freed titlebar");
  [inner release];

  [kept release];
  PASS(freed == 2, "the last titlebar is freed as well");

  [registry release];
  [arp release];
  return 0;
}
