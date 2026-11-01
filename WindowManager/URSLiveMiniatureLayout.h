/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Geometry of the live miniature of a minimized window: the window's own
// content, scaled down and kept live, painted into the Dock tile that stands
// for the window.  Rects are in root pixels, y down.
@interface URSLiveMiniatureLayout : NSObject

// Where the window's content is painted inside its tile: as large as fits
// inside the tile less the inset on every side, with the window's aspect
// ratio, centred, on whole pixels.  NSZeroRect when nothing can be shown.
+ (NSRect)paintRectForTile:(NSRect)tile
                windowSize:(NSSize)windowSize
                     inset:(CGFloat)inset;

// How long to wait before the miniature may be repainted, given when it was
// last painted: 0 when it may be repainted now.  A miniature is a few dozen
// pixels, and a client redrawing at full rate (a video) would otherwise make
// the compositor repaint for it at that rate too.
+ (NSTimeInterval)repaintDelaySinceLastPaint:(NSTimeInterval)lastPaint
                                         now:(NSTimeInterval)now
                                 minInterval:(NSTimeInterval)minInterval;

@end
