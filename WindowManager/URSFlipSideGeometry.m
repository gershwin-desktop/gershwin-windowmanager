/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipSideGeometry.h"

@implementation URSFlipSideGeometry

- (instancetype)initWithFrameSize:(NSSize)frameSize
                     clientOffset:(NSPoint)clientOffset
                     flipSideSize:(NSSize)flipSideSize
{
    self = [super init];
    if (self) {
        _frameSize = frameSize;
        _clientOffset = clientOffset;
        _flipSideSize = flipSideSize;
    }
    return self;
}

- (NSRect)titlebarStrip
{
    if (self.clientOffset.y <= 0.0 || self.clientOffset.y >= self.frameSize.height) {
        return NSZeroRect;
    }
    return NSMakeRect(0.0, 0.0, self.frameSize.width, self.clientOffset.y);
}

- (NSRect)flipSideRect
{
    return NSMakeRect(self.clientOffset.x, self.clientOffset.y,
                      self.flipSideSize.width, self.flipSideSize.height);
}

- (URSProjectiveMatrix)flipSideMatrixForFaceMatrix:(URSProjectiveMatrix)toFace
{
    return URSProjectiveMatrixMultiply(
        URSProjectiveMatrixTranslation(-self.clientOffset.x, -self.clientOffset.y), toFace);
}

@end
