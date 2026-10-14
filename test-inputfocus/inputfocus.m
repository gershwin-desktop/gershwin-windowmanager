/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// A click on Menu.app's bar gave that window the focus although it uses
// ICCCM's No Input model (WM_HINTS input False, no WM_TAKE_FOCUS), so the
// frontmost application lost the focus and hid its palettes.  Headless.
// Run with:  gnustep-tests test-inputfocus

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "URSInputFocusPolicy.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  PASS(!URSWindowAcceptsInputFocus(NO, NO),
       "No Input (input False, no WM_TAKE_FOCUS) never gets the focus");
  PASS(URSWindowAcceptsInputFocus(YES, NO),
       "Passive (input True) gets the focus");
  PASS(URSWindowAcceptsInputFocus(YES, YES),
       "Locally Active gets the focus");
  PASS(URSWindowAcceptsInputFocus(NO, YES),
       "Globally Active (GNUstep's windows) is focused through WM_TAKE_FOCUS");

  [arp release];
  return 0;
}
