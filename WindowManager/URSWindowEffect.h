/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A short effect the compositor plays on a window where it stands.  The
// window itself is never moved or resized: an effect only decides where,
// and how big, the window's picture is painted, so the client sees nothing
// of it.  Rects are in root window pixels, y down, borders included.
@protocol URSWindowEffect <NSObject>

@property (readonly, nonatomic) NSTimeInterval duration;

// Where to paint a window whose real rect is windowRect, at progress t
// (0 at the start, 1 at the end).
- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect;

// Every rect paintRectAtProgress:forWindowRect: can return during the run;
// the compositor repaints this much on every frame.
- (NSRect)reachOfWindowRect:(NSRect)windowRect;

@end
