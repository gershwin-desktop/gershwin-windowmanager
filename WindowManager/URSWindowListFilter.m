/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowListFilter.h"

@implementation URSWindowListFilter

+ (BOOL)includesFrameNeedingDestroy:(BOOL)needDestroy
                         hasTitlebar:(BOOL)hasTitlebar
                      isUtilityPanel:(BOOL)isUtilityPanel
                    isFloatingWindow:(BOOL)isFloatingWindow {
    return !needDestroy && hasTitlebar && !isUtilityPanel && !isFloatingWindow;
}

+ (BOOL)isManagedUtilityPanelNeedingDestroy:(BOOL)needDestroy
                                 hasTitlebar:(BOOL)hasTitlebar
                              isUtilityPanel:(BOOL)isUtilityPanel {
    return !needDestroy && hasTitlebar && isUtilityPanel;
}

+ (BOOL)isManagedFloatingWindowNeedingDestroy:(BOOL)needDestroy
                                   hasTitlebar:(BOOL)hasTitlebar
                                isUtilityPanel:(BOOL)isUtilityPanel
                              isFloatingWindow:(BOOL)isFloatingWindow {
    // A utility panel is also floating-level in practice (it sets both the
    // style bit and the level), but it stays out of this set - it already
    // belongs to the unconditional palette set above, and double-counting
    // it here would make it independently toggleable by
    // URSOverviewUtilityWindowsKey, which is not what that default governs.
    return !needDestroy && hasTitlebar && !isUtilityPanel && isFloatingWindow;
}

@end
