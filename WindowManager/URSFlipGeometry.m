/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipGeometry.h"

@implementation URSFlipGeometry

- (instancetype)initWithSize:(NSSize)size {
    self = [super init];
    if (self) {
        _size = size;
    }
    return self;
}

- (BOOL)showsBackFaceAtAngle:(double)degrees {
    return NO;
}

- (URSProjectiveMatrix)faceToScreenAtAngle:(double)degrees {
    return URSProjectiveMatrixIdentity();
}

- (void)getCorners:(NSPoint *)corners atAngle:(double)degrees {
    for (int i = 0; i < 4; i++) {
        corners[i] = NSZeroPoint;
    }
}

- (double)shadingAtAngle:(double)degrees {
    return 0.0;
}

- (BOOL)getProjection:(URSWindowProjection *)projection atAngle:(double)degrees {
    return NO;
}

- (NSRect)sweptRectFromAngle:(double)from toAngle:(double)to {
    return NSZeroRect;
}

+ (double)angleAtProgress:(double)t fromAngle:(double)from toAngle:(double)to {
    return 0.0;
}

@end
