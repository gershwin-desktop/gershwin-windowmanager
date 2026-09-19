/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttentionHopEffect.h"
#import <math.h>

// One hop and one rebound, timed like a ball under gravity (the rebound,
// reaching URSHopReboundHeight of the first hop, takes the square root of
// that of its time) so it reads as a bounce rather than a mechanical up and
// down.
static const NSTimeInterval URSHopDuration = 0.65;
static const double URSHopFirstLanding = 0.5;
static const double URSHopSecondLanding = 0.72;
static const double URSHopReboundHeight = 0.19;
static const double URSHopLiftPerScreenHeight = 0.018;
static const double URSHopTakeoffStretch = 0.025;
static const double URSHopLandingSquash = 0.035;
// The window gets narrower as it gets taller, but less so, which keeps the
// text in it from visibly pumping sideways.
static const double URSHopWidthPerStretch = 0.6;

// A wobble that starts at rest, peaks quickly and dies out, so every change
// of shape grows out of the current one instead of popping in.
static double URSHopWobble(double tau) {
    if (tau <= 0.0) return 0.0;
    return sin(2.0 * M_PI * tau / 0.22) * exp(-tau / 0.09);
}

// Height of the hop at progress t, in units of the hop height.
static double URSHopLiftAt(double t) {
    if (t < URSHopFirstLanding) {
        double u = t / URSHopFirstLanding;
        return 4.0 * u * (1.0 - u);
    }
    if (t < URSHopSecondLanding) {
        double u = (t - URSHopFirstLanding) / (URSHopSecondLanding - URSHopFirstLanding);
        return URSHopReboundHeight * 4.0 * u * (1.0 - u);
    }
    return 0.0;
}

// How much taller than natural the window is at progress t (negative is
// squashed); the softer rebound landing squashes less.
static double URSHopStretchAt(double t) {
    return URSHopTakeoffStretch * URSHopWobble(t)
         - URSHopLandingSquash * URSHopWobble(t - URSHopFirstLanding)
         - URSHopLandingSquash * sqrt(URSHopReboundHeight)
           * URSHopWobble(t - URSHopSecondLanding);
}

// Bound on |URSHopStretchAt|: every wobble stays within +-1.
static double URSHopMaxStretch(void) {
    return URSHopTakeoffStretch + URSHopLandingSquash * (1.0 + sqrt(URSHopReboundHeight));
}

@implementation URSAttentionHopEffect {
    double _liftHeight;
}

- (instancetype)initWithScreenHeight:(double)screenHeight {
    self = [super init];
    if (self) {
        _liftHeight = screenHeight * URSHopLiftPerScreenHeight;
    }
    return self;
}

- (NSTimeInterval)duration {
    return URSHopDuration;
}

- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect {
    // Feet stay on the ground: squash and stretch around the bottom centre,
    // then the whole window is lifted by the hop.
    double stretch = URSHopStretchAt(t);
    NSRect r;
    r.size.width = windowRect.size.width * (1.0 - URSHopWidthPerStretch * stretch);
    r.size.height = windowRect.size.height * (1.0 + stretch);
    r.origin.x = NSMidX(windowRect) - r.size.width * 0.5;
    r.origin.y = NSMaxY(windowRect) - URSHopLiftAt(t) * _liftHeight - r.size.height;
    return r;
}

- (NSRect)reachOfWindowRect:(NSRect)windowRect {
    double maxStretch = URSHopMaxStretch();
    double padX = ceil(windowRect.size.width * maxStretch * URSHopWidthPerStretch * 0.5);
    double padTop = ceil(_liftHeight + windowRect.size.height * maxStretch);
    return NSMakeRect(windowRect.origin.x - padX, windowRect.origin.y - padTop,
                      windowRect.size.width + 2.0 * padX,
                      windowRect.size.height + padTop);
}

@end
