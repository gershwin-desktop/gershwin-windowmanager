/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Whether a managed frame belongs in a list of document windows the user
// switches between as a whole - the F9 overview and the Alt-Tab switcher
// both build their window list this way, and shared here so the rule
// cannot drift between the two.  A frame counts only while it is a live,
// fully decorated top-level window; a utility panel (palette) is excluded
// even though it is fully decorated, because it floats above its document
// on purpose and is not itself something to overview or switch to.  A
// floating window that is not a utility panel - a Stickies note, or any
// other client that asks for NSFloatingWindowLevel without the GNUstep
// utility style bit - is excluded the same way: it is not a document to
// lay out among the rest, matching how a reference desktop's window
// overview leaves floating/utility windows out of its tiled grid.
@interface URSWindowListFilter : NSObject

+ (BOOL)includesFrameNeedingDestroy:(BOOL)needDestroy
                         hasTitlebar:(BOOL)hasTitlebar
                      isUtilityPanel:(BOOL)isUtilityPanel
                    isFloatingWindow:(BOOL)isFloatingWindow;

// The complement: a live, fully decorated utility panel - one of the panels
// excluded above.  The F9 overview uses this to find the palettes it always
// fades out of its own scene instead of laying them into the grid.
+ (BOOL)isManagedUtilityPanelNeedingDestroy:(BOOL)needDestroy
                                 hasTitlebar:(BOOL)hasTitlebar
                              isUtilityPanel:(BOOL)isUtilityPanel;

// The other complement: a live, fully decorated floating window that is not
// itself a utility panel - a Stickies note and the like.  Kept as a set of
// its own, disjoint from the utility panel set above, because whether the
// F9 overview fades these out or leaves them untouched is a user choice
// (URSOverviewUtilityWindowsKey), unlike a true utility panel, which always
// fades.
+ (BOOL)isManagedFloatingWindowNeedingDestroy:(BOOL)needDestroy
                                   hasTitlebar:(BOOL)hasTitlebar
                                isUtilityPanel:(BOOL)isUtilityPanel
                              isFloatingWindow:(BOOL)isFloatingWindow;

@end
