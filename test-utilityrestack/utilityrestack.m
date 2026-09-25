/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// -restackDockWindowsAbove re-raised every UTILITY window of the focused
// application by iterating [windowsMap allValues] (undefined
// NSDictionary order) whenever any of them requested stack_mode=Above.
// Every Stickies note is a UTILITY window, so raising one note re-stacked
// all of that app's notes in arbitrary order and could put a different
// note on top than the one the user actually clicked.  Headless.
// Run with:  gnustep-tests test-utilityrestack

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSUtilityRestackOrder.m"

// Ids shaped like real Stickies notes: three utility windows of one app,
// stacked bottom to top as the server currently has them.
static const uint32_t note1 = 0x800001;
static const uint32_t note2 = 0x800002;
static const uint32_t note3 = 0x800003;

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  {
    NSArray *serverOrder = @[ @(note1), @(note2), @(note3) ];

    // The user clicked note1, currently at the bottom.  It must end up
    // last (topmost); note2 and note3 must keep their relative order.
    NSArray *order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note1
                                                      currentStackingOrder:serverOrder];
    NSArray *want = @[ @(note2), @(note3), @(note1) ];
    PASS_EQUAL(order, want,
        "the clicked window ends up last (topmost) regardless of where it started");

    // Clicking the window that is already topmost changes nothing.
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note3
                                              currentStackingOrder:serverOrder];
    want = @[ @(note1), @(note2), @(note3) ];
    PASS_EQUAL(order, want, "an already-topmost window stays last");

    // The middle window moves to the end; the other two keep their
    // original relative order (note1 still before note3).
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note2
                                              currentStackingOrder:serverOrder];
    want = @[ @(note1), @(note3), @(note2) ];
    PASS_EQUAL(order, want,
        "siblings not being raised keep their existing relative order");
  }
  {
    NSArray *serverOrder = @[ @(note1), @(note2) ];

    // No specific request (e.g. a restack triggered by something other
    // than a raise ConfigureRequest): use the server's own order, never
    // reorder arbitrarily.
    NSArray *order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:0
                                              currentStackingOrder:serverOrder];
    PASS_EQUAL(order, serverOrder,
        "with no requested window the server's current order is kept as-is");

    // A window not yet present in the known stacking order (e.g. mapped
    // this instant) is still placed last, on top, rather than dropped.
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note3
                                              currentStackingOrder:serverOrder];
    NSArray *want = @[ @(note1), @(note2), @(note3) ];
    PASS_EQUAL(order, want,
        "a requested window absent from the known order is still placed on top");
  }

  [arp release];
  return 0;
}
