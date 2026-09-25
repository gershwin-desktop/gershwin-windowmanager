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
                                          isUtilityPanel: NO
                                        isFloatingWindow: NO],
       "a live, decorated document window is included");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: NO
                                              hasTitlebar: YES
                                           isUtilityPanel: YES
                                         isFloatingWindow: NO],
       "a utility panel (palette) is excluded even when fully decorated");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: YES
                                              hasTitlebar: YES
                                           isUtilityPanel: NO
                                         isFloatingWindow: NO],
       "a frame already marked for destruction is excluded");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: NO
                                              hasTitlebar: NO
                                           isUtilityPanel: NO
                                         isFloatingWindow: NO],
       "a frame without a titlebar (not yet managed) is excluded");

  PASS(![URSWindowListFilter includesFrameNeedingDestroy: YES
                                              hasTitlebar: YES
                                           isUtilityPanel: YES
                                         isFloatingWindow: NO],
       "a destroyed utility panel is excluded (both reasons agree)");

  /* A Stickies note (or any window a client floats above normal ones,
   * NSFloatingWindowLevel) sets no GNUstep utility style bit, so it never
   * trips isUtilityPanel, yet it must stay out of the tiled grid the same
   * way a palette does - it is not a document to lay out among the rest. */
  PASS(![URSWindowListFilter includesFrameNeedingDestroy: NO
                                              hasTitlebar: YES
                                           isUtilityPanel: NO
                                         isFloatingWindow: YES],
       "a floating window (a Stickies note) is excluded although it is not a utility panel");

  PASS([URSWindowListFilter isManagedFloatingWindowNeedingDestroy: NO
                                                       hasTitlebar: YES
                                                    isUtilityPanel: NO
                                                  isFloatingWindow: YES],
       "a live, decorated floating window is reported as one to fade or keep in place");

  PASS(![URSWindowListFilter isManagedFloatingWindowNeedingDestroy: YES
                                                         hasTitlebar: YES
                                                      isUtilityPanel: NO
                                                    isFloatingWindow: YES],
       "a floating window already marked for destruction is not reported");

  PASS(![URSWindowListFilter isManagedFloatingWindowNeedingDestroy: NO
                                                         hasTitlebar: YES
                                                      isUtilityPanel: NO
                                                    isFloatingWindow: NO],
       "an ordinary document window is not reported as a floating window");

  /* A GNUstep utility panel is also floating (it sets both the style bit and
   * the level), but it belongs only to the existing, unconditional palette
   * set - not the new, configurable floating-window set - so the two never
   * double-count the same frame. */
  PASS(![URSWindowListFilter isManagedFloatingWindowNeedingDestroy: NO
                                                         hasTitlebar: YES
                                                      isUtilityPanel: YES
                                                    isFloatingWindow: YES],
       "a utility panel is not also reported as a floating window");

  PASS([URSWindowListFilter isManagedUtilityPanelNeedingDestroy: NO
                                                     hasTitlebar: YES
                                                  isUtilityPanel: YES],
       "a utility panel is still reported by the existing palette rule, unaffected by the new one");

  [arp release];
  return 0;
}
