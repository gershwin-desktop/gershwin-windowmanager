/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Returned by -delayBeforePaintAt: while the previous frame has not reached
// the screen yet: the next paint waits for -notePresentationCompleted, not
// for a clock.
extern const NSTimeInterval URSFramePacerWaitForPresentation;

// Decides when the compositor may paint its next frame.  Damage from a busy
// client (a scrolling browser) arrives far more often than the screen
// refreshes; everything that arrives before the next permitted paint is
// painted together in that one pass, and nothing is ever dropped - a paint
// is only ever deferred.
//
// Without presentation feedback a paint is allowed once per minimum
// interval.  With it (-pacedByPresentation), the display's refresh paces
// painting instead: at most one frame is waiting for the screen, and the
// next one is painted as soon as it has been shown.  A clock can never
// match the refresh exactly, and every refresh that gets no frame shows the
// previous one again - a visible hitch in a continuous scroll.
@interface URSFramePacer : NSObject

- (instancetype)initWithMinimumInterval:(NSTimeInterval)interval;

@property (nonatomic, readonly) NSTimeInterval minimumInterval;
@property (nonatomic, assign) BOOL pacedByPresentation;
@property (nonatomic, readonly) BOOL presentationPending;

// 0 to paint now, a positive time to try again after it, or
// URSFramePacerWaitForPresentation.
- (NSTimeInterval)delayBeforePaintAt:(NSTimeInterval)now;

- (void)notePaintAt:(NSTimeInterval)now;
- (void)notePresentationQueued;
- (void)notePresentationCompleted;

// Forgets the frame in flight, for when the buffers it was presented from
// are replaced (screen size change, compositing restarted).
- (void)reset;

@end
