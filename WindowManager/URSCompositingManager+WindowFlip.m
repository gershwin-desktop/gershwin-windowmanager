/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCompositingManager+WindowFlip.h"
#import "URSWindowFlipEffect.h"

static const double URSWindowFlipFront = 0.0;
static const double URSWindowFlipBack = 180.0;

@implementation URSCompositingManager (WindowFlip)

- (BOOL)canFlipWindows {
    return self.compositingActive && [URSWindowFlipEffect isEnabled];
}

- (void)flipWindow:(xcb_window_t)frameId {
    if (![self canFlipWindows]) {
        return;
    }
    // The compositor, not a table here, knows whether the window is turned:
    // it forgets that when the window goes, so a reused window id can never
    // inherit another window's back.
    id<URSWindowEffect> current = [self effectOnWindow:frameId];
    double angle = URSWindowFlipFront;
    double target = URSWindowFlipBack;
    if ([current isKindOfClass:[URSWindowFlipEffect class]]) {
        URSWindowFlipEffect *turn = (URSWindowFlipEffect *)current;
        angle = [turn currentAngle];
        target = [turn toAngle] == URSWindowFlipBack ? URSWindowFlipFront : URSWindowFlipBack;
    }
    if (angle == target) {
        return;
    }
    [self playEffect:[[URSWindowFlipEffect alloc] initFromAngle:angle toAngle:target]
            onWindow:frameId];
}

@end
