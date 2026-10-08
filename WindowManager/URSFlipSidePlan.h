/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// What "Flip Window" does, from what is known about the window.
typedef NS_ENUM(NSInteger, URSFlipSideAction) {
    // The back is in view or on its way: turn round to the front.
    URSFlipSideActionTurnToFront,
    // The turn waits for the terminal, and the user asked again: the user
    // changed their mind, so the turn is called off.
    URSFlipSideActionCancelWait,
    // The flip side is off: turn to the plain back.
    URSFlipSideActionPlainTurn,
    // The flip side is off but this window has one from before: it goes,
    // and the window turns to the plain back.
    URSFlipSideActionEndFlipSideAndPlainTurn,
    // The flip side is there: turn to it at once.
    URSFlipSideActionTurnToFlipSide,
    // The terminal runs but has not shown its window yet: wait for it.
    URSFlipSideActionWaitForFlipSide,
    // Nothing yet: find the application's source directory; with one,
    // start the terminal there and wait for it, without one nothing turns
    // (the menu does not offer it).
    URSFlipSideActionLookUpSourceDirectory,
};

@interface URSFlipSidePlan : NSObject

+ (URSFlipSideAction)actionWithBackInView:(BOOL)backInView
                                  waiting:(BOOL)waiting
                                  enabled:(BOOL)enabled
                              hasFlipSide:(BOOL)hasFlipSide
                           helperRunning:(BOOL)helperRunning;

// Whether the flip side window stacks directly above its parent's frame
// (and so takes the input over the client area) rather than below it.
// Only once the back is fully in view: during the turn the user still
// sees the front go.
+ (BOOL)flipSideStacksAboveParentWithBackShown:(BOOL)backShown;

@end
