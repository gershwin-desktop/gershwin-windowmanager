/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Bends a window's picture over a mesh for as long as it wants to, e.g. to
// let a dragged window trail behind the pointer like jelly.  Like an effect
// it changes only how the picture is painted, never the window.  The mesh
// has (columns + 1) x (rows + 1) points; point (c, r) is where the window's
// picture point (width * c / columns, height * r / rows) is painted.  Rects
// and points are in root pixels, y down, borders included.
@protocol URSWindowDeformation <NSObject>

@property (readonly, nonatomic) NSUInteger columns;
@property (readonly, nonatomic) NSUInteger rows;

// Moves the mesh on to the given time for a window now at windowRect.
// Returns NO once the mesh lies flat on the window and will stay so; the
// compositor then drops the deformation and paints the window as usual.
- (BOOL)stepToTime:(NSTimeInterval)now windowRect:(NSRect)windowRect;

- (NSPoint)pointAtColumn:(NSUInteger)column row:(NSUInteger)row;

// Bounding box of the mesh as last stepped.
- (NSRect)reach;

@end
