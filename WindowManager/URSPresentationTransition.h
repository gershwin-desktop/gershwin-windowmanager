/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class URSCompositingManager;

// Eases a presentation between 0 (windows where they are) and 1 (windows
// where the presentation shows them), and turns around smoothly from
// wherever it is when asked to go the other way.
@interface URSPresentationTransition : NSObject

@property (weak, nonatomic) URSCompositingManager *compositingManager;
@property (readonly, nonatomic) double targetProgress;

// The action is sent to the target, with the transition as argument, when a
// run back to 0 has ended.
- (instancetype)initWithDuration:(NSTimeInterval)duration
                          target:(id)target
                    closedAction:(SEL)closedAction;

- (void)runTo:(double)target;
// Goes to target at once, without telling the target object.
- (void)jumpTo:(double)target;
// Stops at once without telling the target, for a presentation taken away.
- (void)cancel;

- (double)progress;
- (BOOL)isAnimating;

@end

// A rect progress (0..1) of the way from one rect to another.
NSRect URSInterpolateRect(NSRect from, NSRect to, double progress);
