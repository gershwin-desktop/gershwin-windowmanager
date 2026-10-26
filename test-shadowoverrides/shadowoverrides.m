/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// What the compositor records about single windows' shadows must end with
// the window: X gives a destroyed window's id to later, unrelated windows.
// Headless.  Run with:  gnustep-tests test-shadowoverrides

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSShadowOverrides.m"

// Ids as a client's first window gets them, and as the next client to
// connect gets them again.
static const uint32_t reusedId = 0x600000;
static const uint32_t otherId = 0x600001;

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("shadow overrides")
  {
    URSShadowOverrides *o = [[URSShadowOverrides alloc] init];
    [o setSkipsShadow: YES forWindow: reusedId];
    [o setSkipsShadow: YES forWindow: otherId];
    PASS([o skipsShadowForWindow: reusedId], "a window can be kept shadowless");

    [o forgetWindow: reusedId];
    PASS(![o skipsShadowForWindow: reusedId],
         "a window reusing a destroyed shadowless window's id gets a shadow");
    PASS([o skipsShadowForWindow: otherId],
         "forgetting one window leaves the others shadowless");

    [o setSkipsShadow: NO forWindow: otherId];
    PASS(![o skipsShadowForWindow: otherId], "a window can get its shadow back");
  }
  {
    URSShadowOverrides *o = [[URSShadowOverrides alloc] init];
    PASS([o setCornerRadius: 12 forWindow: reusedId], "a new radius is a change");
    PASS(![o setCornerRadius: 12 forWindow: reusedId], "the same radius is no change");
    PASS([o cornerRadiusForWindow: reusedId] == 12, "the radius is kept");

    [o forgetWindow: reusedId];
    PASS([o cornerRadiusForWindow: reusedId] == 0,
         "a window reusing a destroyed window's id has square corners");
    PASS(![o setCornerRadius: 0 forWindow: reusedId], "square after forgetting is no change");
  }
  END_SET("shadow overrides")

  [arp release];
  return 0;
}
