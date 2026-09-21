/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules for which managed windows appear in the F9 overview and the
// Alt-Tab switcher.  Headless.
// Run with:  gnustep-tests test-overview

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSWindowListFilter.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  PASS([URSWindowListFilter includesFrameNeedingDestroy: NO
                                             hasTitlebar: YES
                                          isUtilityPanel: NO],
       "a live, decorated document window is included");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: NO
                                              hasTitlebar: YES
                                           isUtilityPanel: YES],
       "a utility panel (palette) is excluded even when fully decorated");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: YES
                                              hasTitlebar: YES
                                           isUtilityPanel: NO],
       "a frame already marked for destruction is excluded");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: NO
                                              hasTitlebar: NO
                                           isUtilityPanel: NO],
       "a frame without a titlebar (not yet managed) is excluded");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: YES
                                              hasTitlebar: YES
                                           isUtilityPanel: YES],
       "a destroyed utility panel is excluded (both reasons agree)");

  [arp release];
  return 0;
}
