/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipSidePlan.h"

@implementation URSFlipSidePlan

+ (URSFlipSideAction)actionWithBackInView:(BOOL)backInView
                                  waiting:(BOOL)waiting
                                  enabled:(BOOL)enabled
                              hasFlipSide:(BOOL)hasFlipSide
                           helperRunning:(BOOL)helperRunning
{
    if (backInView) {
        return URSFlipSideActionTurnToFront;
    }
    if (waiting) {
        return URSFlipSideActionCancelWait;
    }
    if (!enabled) {
        // Switched off is off: a terminal left from before would otherwise
        // still show on the back.
        return (hasFlipSide || helperRunning) ? URSFlipSideActionEndFlipSideAndPlainTurn
                                              : URSFlipSideActionPlainTurn;
    }
    if (hasFlipSide) {
        return URSFlipSideActionTurnToFlipSide;
    }
    // A second terminal would only end up as a second flip side the window
    // cannot take (a window has one).
    if (helperRunning) {
        return URSFlipSideActionWaitForFlipSide;
    }
    return URSFlipSideActionLookUpSourceDirectory;
}

+ (BOOL)flipSideStacksAboveParentWithBackShown:(BOOL)backShown
{
    return backShown;
}

@end
