/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSWindowEffect.h"

// A window that must stay exactly where it is, painted from its last
// picture, for a fixed span of time even though it may unmap while this
// runs - used to keep a parent window's own frame on screen for as long as
// an attached window (a sheet or drawer) it just detached from is still
// playing its own dismiss slide, so the parent does not vanish first.  It
// never moves or resizes the window; it only keeps the compositor from
// freeing the parent's picture until the span has elapsed, after which the
// normal end-of-effect cleanup releases it exactly like any other effect
// that outlives an unmap (see URSCompositingManager's keepsContentAfterUnmap).
@interface URSHoldLastFrameEffect : NSObject <URSWindowEffect>

- (instancetype)initWithDuration:(NSTimeInterval)duration;

@end
