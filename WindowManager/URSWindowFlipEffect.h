/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowEffect.h"

// Defaults key (domain WindowManager), YES unless set to NO.
extern NSString * const URSWindowFlipEnabledKey;

// The window turns over about its vertical centre line, in perspective, to
// its back (a plain panel) and back again.  Angles are in degrees: 0 shows
// the front, 180 the back.  A turn that ends on the back stays there.
@interface URSWindowFlipEffect : NSObject <URSWindowEffect>

@property (readonly, nonatomic) double fromAngle;
@property (readonly, nonatomic) double toAngle;

+ (BOOL)isEnabled;

// A turn starting now; the duration follows the angle to cover.
- (instancetype)initFromAngle:(double)fromAngle toAngle:(double)toAngle;

// Where the turn is now, so a turn back can start from there.
- (double)currentAngle;

@end
