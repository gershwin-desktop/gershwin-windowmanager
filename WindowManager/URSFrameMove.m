/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFrameMove.h"

BOOL URSFrameSizeChangeAllowed(double currentWidth, double currentHeight,
                               double targetWidth, double targetHeight,
                               BOOL windowResizable)
{
    if (windowResizable) {
        return YES;
    }
    return currentWidth == targetWidth && currentHeight == targetHeight;
}
