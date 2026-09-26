/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFramePacer.h"

const NSTimeInterval URSFramePacerWaitForPresentation = -1.0;

@implementation URSFramePacer
{
    NSTimeInterval _lastPaint;
}

- (instancetype)initWithMinimumInterval:(NSTimeInterval)interval
{
    self = [super init];
    if (self) {
        _minimumInterval = interval;
    }
    return self;
}

- (NSTimeInterval)delayBeforePaintAt:(NSTimeInterval)now
{
    if (_pacedByPresentation) {
        // The refresh itself is the frame cap here.  A clock on top of it
        // would, on a display refreshing slightly faster than the clock,
        // hold back the frame that is due right after a completion.
        return _presentationPending ? URSFramePacerWaitForPresentation : 0;
    }
    if (_lastPaint <= 0) {
        return 0;
    }
    NSTimeInterval elapsed = now - _lastPaint;
    return elapsed < _minimumInterval ? _minimumInterval - elapsed : 0;
}

- (void)notePaintAt:(NSTimeInterval)now
{
    _lastPaint = now;
}

- (void)notePresentationQueued
{
    // Without completion reports nothing would ever clear the flag.
    if (_pacedByPresentation) {
        _presentationPending = YES;
    }
}

- (void)notePresentationCompleted
{
    _presentationPending = NO;
}

- (void)reset
{
    _presentationPending = NO;
}

@end
