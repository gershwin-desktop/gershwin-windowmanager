/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSPresentationTransition.h"
#import "URSCompositingManager.h"

// Ease in and out, so windows neither jump off nor slam into place.
double URSPresentationEase(double t) {
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
}

NSRect URSInterpolateRect(NSRect from, NSRect to, double p) {
    return NSMakeRect(NSMinX(from) + (NSMinX(to) - NSMinX(from)) * p,
                      NSMinY(from) + (NSMinY(to) - NSMinY(from)) * p,
                      NSWidth(from) + (NSWidth(to) - NSWidth(from)) * p,
                      NSHeight(from) + (NSHeight(to) - NSHeight(from)) * p);
}

@interface URSPresentationTransition ()
@property (assign, nonatomic) NSTimeInterval duration;
@property (weak, nonatomic) id target;
@property (assign, nonatomic) SEL closedAction;
@property (assign, nonatomic) double fromProgress;
@property (readwrite, assign, nonatomic) double targetProgress;
@property (assign, nonatomic) NSTimeInterval start;
@property (strong, nonatomic) NSTimer *timer;
@end

@implementation URSPresentationTransition

- (instancetype)initWithDuration:(NSTimeInterval)duration
                          target:(id)target
                    closedAction:(SEL)closedAction {
    self = [super init];
    if (self) {
        _duration = duration;
        _target = target;
        _closedAction = closedAction;
    }
    return self;
}

- (double)progress {
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.start;
    double t = MIN(1.0, MAX(0.0, elapsed / self.duration));
    return self.fromProgress + (self.targetProgress - self.fromProgress) * URSPresentationEase(t);
}

- (BOOL)isAnimating {
    return self.timer != nil;
}

- (void)runTo:(double)target {
    self.fromProgress = [self progress];
    self.targetProgress = target;
    self.start = [NSDate timeIntervalSinceReferenceDate];
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.duration
                                                  target:self
                                                selector:@selector(ended:)
                                                userInfo:nil
                                                 repeats:NO];
    [self.compositingManager presentationChanged];
}

- (void)jumpTo:(double)target {
    [self.timer invalidate];
    self.timer = nil;
    self.fromProgress = target;
    self.targetProgress = target;
    [self.compositingManager presentationChanged];
}

- (void)cancel {
    [self.timer invalidate];
    self.timer = nil;
    self.fromProgress = 0.0;
    self.targetProgress = 0.0;
}

- (void)ended:(NSTimer *)timer {
    self.timer = nil;
    // The last frame must be painted at the end position, not the one
    // before it.
    [self.compositingManager presentationChanged];
    if (self.targetProgress == 0.0) {
        id target = self.target;
        if (target) {
            ((void (*)(id, SEL, id))[target methodForSelector:self.closedAction])(target, self.closedAction, self);
        }
    }
}

@end
