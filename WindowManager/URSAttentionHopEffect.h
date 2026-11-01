/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowEffect.h"

// The window hops once in place, stretching on takeoff and squashing on
// landing, to lead the eye to it (e.g. the window Alt-Tab switched to).
@interface URSAttentionHopEffect : NSObject <URSWindowEffect>

// The hop height follows the screen, so it looks the same at any resolution.
- (instancetype)initWithScreenHeight:(double)screenHeight;

@end
