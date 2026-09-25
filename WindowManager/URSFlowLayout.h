/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Where the Alt-Tab flow shows each window: one row across the screen, the
// window at the current position centred, big and in front, the others
// turned away and receding to both sides, as in the ItemFlow view of
// gershwin-components.  ItemFlow draws with OpenGL and turns its pictures in
// space; the compositor can only move and scale a picture, so the same
// geometry is given here as the rectangles that turn produces on the screen
// (depth as a smaller scale, the turn as a narrower picture).
// Rects are in root pixels, y down.  Positions are item indexes; a position
// between two indexes is a row sliding from one to the other.
@interface URSFlowLayout : NSObject

+ (NSRect)slotForWindowSize:(NSSize)windowSize
                    atIndex:(NSUInteger)index
                   position:(double)position
                     inArea:(NSRect)area;

// One slot per window size (NSValue), in the same order.
+ (NSArray *)slotsForWindowSizes:(NSArray *)windowSizes
                        position:(double)position
                          inArea:(NSRect)area;

// Item indexes (NSNumber) back to front: the farthest from the position
// first, the one at the position last, so it covers its neighbours.
+ (NSArray *)paintOrderForCount:(NSUInteger)count position:(double)position;

// The index step items away from index, going round at either end.
+ (NSUInteger)indexFrom:(NSUInteger)index step:(NSInteger)step count:(NSUInteger)count;

// stack with the objects that appear in order moved so that they come in
// that order, each taking one of the places those objects had; every other
// object keeps its place.  order must hold only objects of stack.
+ (NSArray *)stack:(NSArray *)stack reorderedAs:(NSArray *)order;

@end
