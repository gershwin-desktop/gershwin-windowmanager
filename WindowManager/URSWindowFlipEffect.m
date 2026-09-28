/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowFlipEffect.h"
#import "URSFlipGeometry.h"

NSString * const URSWindowFlipEnabledKey = @"URSWindowFlipEnabled";

// Half a second for a full turn: long enough to follow the window round,
// short enough not to be waited for.  A partial turn (turned back midway)
// keeps the same speed.
static const NSTimeInterval URSWindowFlipFullTurnDuration = 0.5;

@implementation URSWindowFlipEffect {
    NSTimeInterval _startTime;
    NSTimeInterval _duration;
    URSFlipGeometry *_geometry;
}

+ (void)initialize {
    if (self == [URSWindowFlipEffect class]) {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            URSWindowFlipEnabledKey: @YES,
        }];
    }
}

+ (BOOL)isEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:URSWindowFlipEnabledKey];
}

- (instancetype)initFromAngle:(double)fromAngle toAngle:(double)toAngle {
    self = [super init];
    if (self) {
        _fromAngle = fromAngle;
        _toAngle = toAngle;
        _duration = URSWindowFlipFullTurnDuration * fabs(toAngle - fromAngle) / 180.0;
        _startTime = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

// The window may be resized while it is turned over.
- (URSFlipGeometry *)geometryForSize:(NSSize)size {
    if (!_geometry || !NSEqualSizes([_geometry size], size)) {
        _geometry = [[URSFlipGeometry alloc] initWithSize:size];
    }
    return _geometry;
}

- (double)angleAtProgress:(double)t {
    return [URSFlipGeometry angleAtProgress:t fromAngle:self.fromAngle toAngle:self.toAngle];
}

- (double)currentAngle {
    if (_duration <= 0.0) {
        return self.toAngle;
    }
    return [self angleAtProgress:([NSDate timeIntervalSinceReferenceDate] - _startTime) / _duration];
}

#pragma mark - URSWindowEffect

- (NSTimeInterval)duration {
    return _duration;
}

- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect {
    return windowRect;
}

- (NSRect)reachOfWindowRect:(NSRect)windowRect {
    NSRect swept = [[self geometryForSize:windowRect.size] sweptRectFromAngle:self.fromAngle
                                                                      toAngle:self.toAngle];
    return NSOffsetRect(swept, NSMinX(windowRect), NSMinY(windowRect));
}

- (BOOL)getProjection:(URSWindowProjection *)projection
           atProgress:(double)t
           windowSize:(NSSize)size {
    return [[self geometryForSize:size] getProjection:projection atAngle:[self angleAtProgress:t]];
}

- (BOOL)holdsFinalFrame {
    return self.toAngle != 0.0;
}

- (BOOL)replacesRunningEffect {
    return YES;
}

@end
