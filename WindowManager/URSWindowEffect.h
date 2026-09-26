/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "URSProjection.h"

// A short effect the compositor plays on a window where it stands.  The
// window itself is never moved or resized: an effect only decides where,
// and how big, the window's picture is painted, so the client sees nothing
// of it.  Rects are in root window pixels, y down, borders included.
@protocol URSWindowEffect <NSObject>

@property (readonly, nonatomic) NSTimeInterval duration;

// Where to paint a window whose real rect is windowRect, at progress t
// (0 at the start, 1 at the end).
- (NSRect)paintRectAtProgress:(double)t forWindowRect:(NSRect)windowRect;

// Every rect paintRectAtProgress:forWindowRect: can return during the run,
// as far as the clip below lets it be seen; the compositor repaints this
// much on every frame.
- (NSRect)reachOfWindowRect:(NSRect)windowRect;

@optional
// The only part of the screen the window's picture and shadow may cover
// while the effect runs, for effects that make the window come out from
// behind something (a sheet from under its parent's titlebar).
- (NSRect)clipRectForWindowRect:(NSRect)windowRect;

// An effect that turns the window in depth rather than moving it: fills in
// the frame at progress t for a window of this size (borders included), or
// returns NO when there is nothing to see (the window edge-on).  The
// compositor then paints through the projection and ignores
// paintRectAtProgress:forWindowRect:.
- (BOOL)getProjection:(URSWindowProjection *)projection
           atProgress:(double)t
           windowSize:(NSSize)size;

// YES keeps the effect's last frame on screen once it has run, until the
// window unmaps or another effect replaces it (a window left turned over).
- (BOOL)holdsFinalFrame;

// YES when the effect may cut short an effect still running or held on the
// window.  Without it a new effect is ignored meanwhile, so that repeating
// an attention effect (an Alt-Tab hop) does not restart it; turning a
// window back while it is still turning over has to start at once, though.
- (BOOL)replacesRunningEffect;

@end
