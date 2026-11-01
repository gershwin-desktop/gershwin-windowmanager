/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Whether the window manager may put a frame of the given current size at a
// requested size.  A window whose size is fixed (WM_NORMAL_HINTS) may be
// moved, but never resized: Center, snapping back and similar moves must
// work for it while any size change stays refused.
BOOL URSFrameSizeChangeAllowed(double currentWidth, double currentHeight,
                               double targetWidth, double targetHeight,
                               BOOL windowResizable);
