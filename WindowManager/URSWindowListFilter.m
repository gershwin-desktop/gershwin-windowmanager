/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowListFilter.h"

@implementation URSWindowListFilter

+ (BOOL)includesFrameNeedingDestroy:(BOOL)needDestroy
                         hasTitlebar:(BOOL)hasTitlebar
                      isUtilityPanel:(BOOL)isUtilityPanel {
    return !needDestroy && hasTitlebar && !isUtilityPanel;
}

+ (BOOL)isManagedUtilityPanelNeedingDestroy:(BOOL)needDestroy
                                 hasTitlebar:(BOOL)hasTitlebar
                              isUtilityPanel:(BOOL)isUtilityPanel {
    return !needDestroy && hasTitlebar && isUtilityPanel;
}

@end
