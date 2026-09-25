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
// note on top than the one the user actually clicked.
//
// The same loop also covers DIALOG windows, and a modal dialog must
// always end up above its app's own utility/floating panels - Keychain's
// password prompt (DIALOG + _NET_WM_STATE_MODAL) was found stacked BELOW
// its own utility panel whenever that panel last asked to be raised,
// because the loop had no notion of "modal wins" - it just put whichever
// window asked last on top of everyone.  Headless.
// Run with:  gnustep-tests test-utilityrestack

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSUtilityRestackOrder.m"

// Ids shaped like real Stickies notes: three utility windows of one app,
// stacked bottom to top as the server currently has them.
static const uint32_t note1 = 0x800001;
static const uint32_t note2 = 0x800002;
static const uint32_t note3 = 0x800003;

// A Keychain-shaped app: one utility panel plus one modal password dialog.
static const uint32_t utilPanel1 = 0x800101;
static const uint32_t utilPanel2 = 0x800102;
static const uint32_t modalDialog = 0x800103;

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSSet *noModals = [NSSet set];

  {
    NSArray *serverOrder = @[ @(note1), @(note2), @(note3) ];

    // The user clicked note1, currently at the bottom.  It must end up
    // last (topmost); note2 and note3 must keep their relative order.
    NSArray *order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note1
                                                      currentStackingOrder:serverOrder
                                                             modalWindowIds:noModals];
    NSArray *want = @[ @(note2), @(note3), @(note1) ];
    PASS_EQUAL(order, want,
        "the clicked window ends up last (topmost) regardless of where it started");

    // Clicking the window that is already topmost changes nothing.
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note3
                                              currentStackingOrder:serverOrder
                                                     modalWindowIds:noModals];
    want = @[ @(note1), @(note2), @(note3) ];
    PASS_EQUAL(order, want, "an already-topmost window stays last");

    // The middle window moves to the end; the other two keep their
    // original relative order (note1 still before note3).
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note2
                                              currentStackingOrder:serverOrder
                                                     modalWindowIds:noModals];
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
                                              currentStackingOrder:serverOrder
                                                     modalWindowIds:noModals];
    PASS_EQUAL(order, serverOrder,
        "with no requested window the server's current order is kept as-is");

    // A window not yet present in the known stacking order (e.g. mapped
    // this instant) is still placed last, on top, rather than dropped.
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:note3
                                              currentStackingOrder:serverOrder
                                                     modalWindowIds:noModals];
    NSArray *want = @[ @(note1), @(note2), @(note3) ];
    PASS_EQUAL(order, want,
        "a requested window absent from the known order is still placed on top");
  }
  {
    // The Keychain bug: the modal dialog currently sits at the bottom (a
    // previous raise buried it there), and now the app's OTHER utility
    // panel asks to be raised.  The panel must still not end up above the
    // modal dialog - the dialog blocks the whole app, panel included.
    NSArray *serverOrder = @[ @(modalDialog), @(utilPanel1), @(utilPanel2) ];
    NSSet *modals = [NSSet setWithObject:@(modalDialog)];

    NSArray *order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:utilPanel2
                                                      currentStackingOrder:serverOrder
                                                             modalWindowIds:modals];
    NSArray *want = @[ @(utilPanel1), @(utilPanel2), @(modalDialog) ];
    PASS_EQUAL(order, want,
        "a modal dialog stays above the app's utility panels even when a panel is the one raised");

    // Raising the modal dialog itself still puts it on top, same as any
    // other requested window within its own group.
    order = [URSUtilityRestackOrder raiseOrderForRequestedWindow:modalDialog
                                              currentStackingOrder:serverOrder
                                                     modalWindowIds:modals];
    want = @[ @(utilPanel1), @(utilPanel2), @(modalDialog) ];
    PASS_EQUAL(order, want, "raising the modal dialog keeps it on top of the utility panels");
  }

  [arp release];
  return 0;
}
