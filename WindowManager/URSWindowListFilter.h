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
// on purpose and is not itself something to overview or switch to.
@interface URSWindowListFilter : NSObject

+ (BOOL)includesFrameNeedingDestroy:(BOOL)needDestroy
                         hasTitlebar:(BOOL)hasTitlebar
                      isUtilityPanel:(BOOL)isUtilityPanel;

@end
