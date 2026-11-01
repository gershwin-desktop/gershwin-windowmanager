/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSDeckLayout.h"

// The front window is at most this share of the area wide, and as tall as it
// comes from its shape.  Its middle lies at the golden section of the area's
// height, counted from the top, so it sits low on the screen and the windows
// behind show above it; its lower edge stays above this share of the area's
// height, which leaves some room under the deck for the title.
static const double URSDeckFrontWidth = 0.60;
static const double URSDeckFrontCentre = 0.618033988749895;
static const double URSDeckBottomEdge = 0.94;

// The places of the deck, front first, measured from the reference
// animation: the width of a window in a place as a share of the front one,
// and where its top edge lies as a share of the area's height.  The top of
// the front place is the window's own, from where its middle has to lie.
#define URS_DECK_PLACES 5
static const double URSDeckWidthShare[URS_DECK_PLACES] = { 1.0, 0.75, 0.5, 0.3, 0.1 };
static const double URSDeckTopShare[URS_DECK_PLACES] = { 0.247, 0.117, 0.058, 0.018, 0.007 };

// A window that is passed falls out at the bottom in the first half of its
// way round, growing as it comes nearer to the viewer, and in the second
// half it comes in again from behind, growing from nothing into the deepest
// place of the deck.  These are per place of the way (a whole way is one
// place): at half a place the window is below the screen.
static const double URSDeckPassedGrowth = 0.7;
static const double URSDeckPassedFall = 1.6;
static const double URSDeckFallEnds = 0.5;

@implementation URSDeckLayout

// Where an item stands in the deck: 0 in front, more further back up to
// count - 1, between -1 and 0 while it goes round from the front to the back.
// The deck is a ring: the item that has gone out at the bottom is the one
// that comes in at the back.
static double URSDeckPlace(NSUInteger index, NSUInteger count, double position) {
    double n = (double)MAX(count, (NSUInteger)1);
    double place = fmod((double)index - position, n);
    if (place < 0.0) {
        place += n;
    }
    return place > n - 1.0 ? place - n : place;
}

// The rect of a place in the deck at the places of the table, for a window
// of the given size scaled by fit.
static NSRect URSDeckRect(NSSize windowSize, double fit, double place,
                          double growth, double frontTop, NSRect area) {
    double share;
    double top;
    if (place >= URS_DECK_PLACES - 1) {
        share = URSDeckWidthShare[URS_DECK_PLACES - 1];
        top = URSDeckTopShare[URS_DECK_PLACES - 1];
    } else {
        NSUInteger near = (NSUInteger)floor(place);
        double part = place - (double)near;
        double from = near == 0 ? frontTop : URSDeckTopShare[near];
        share = URSDeckWidthShare[near] + (URSDeckWidthShare[near + 1] - URSDeckWidthShare[near]) * part;
        top = from + (URSDeckTopShare[near + 1] - from) * part;
    }
    double width = windowSize.width * fit * share * growth;
    double height = windowSize.height * fit * share * growth;
    return NSMakeRect(NSMidX(area) - width * 0.5,
                      NSMinY(area) + NSHeight(area) * top,
                      width, height);
}

+ (NSRect)slotForWindowSize:(NSSize)windowSize
                    atIndex:(NSUInteger)index
                      count:(NSUInteger)count
                   position:(double)position
                     inArea:(NSRect)area {
    double boxWidth = NSWidth(area) * URSDeckFrontWidth;
    // As tall as fits between the golden section and the lower edge, which
    // is the same above the middle line as below it.
    double boxHeight = NSHeight(area) * 2.0 * (URSDeckBottomEdge - URSDeckFrontCentre);
    // Never enlarged at rest: a window is shown at most at its own size, as a
    // blown up picture turns blurry.
    double fit = MIN(1.0, MIN(boxWidth / MAX(windowSize.width, 1.0),
                              boxHeight / MAX(windowSize.height, 1.0)));

    double frontTop = URSDeckFrontCentre - windowSize.height * fit / NSHeight(area) * 0.5;
    double place = URSDeckPlace(index, count, position);
    if (place >= 0.0) {
        return URSDeckRect(windowSize, fit, place, 1.0, frontTop, area);
    }
    double way = -place;
    if (way < URSDeckFallEnds) {
        // It comes nearer to the viewer, so it is larger than itself while it
        // falls: that is what makes the deck look deep.  At rest no window is.
        NSRect front = URSDeckRect(windowSize, fit, 0.0, 1.0 + URSDeckPassedGrowth * way, frontTop, area);
        front.origin.y += NSHeight(area) * URSDeckPassedFall * way;
        return front;
    }
    // Coming in from behind into the place the deck ends with.
    double coming = (way - URSDeckFallEnds) / (1.0 - URSDeckFallEnds);
    double last = (double)MAX(count, (NSUInteger)1) - 1.0;
    return URSDeckRect(windowSize, fit, last, coming, frontTop, area);
}

// Without a count the deck is taken as not going round: it is as long as the
// window is far from the front.
+ (NSRect)slotForWindowSize:(NSSize)windowSize
                    atIndex:(NSUInteger)index
                   position:(double)position
                     inArea:(NSRect)area {
    return [self slotForWindowSize:windowSize
                           atIndex:index
                             count:(NSUInteger)ceil(MAX(position, (double)index)) + 2
                          position:position
                            inArea:area];
}

// A window coming in from behind is painted with the deepest ones, one that is
// falling with the nearest.
static double URSDeckPaintPlace(NSUInteger index, NSUInteger count, double position) {
    double place = URSDeckPlace(index, count, position);
    if (place < -URSDeckFallEnds) {
        return (double)MAX(count, (NSUInteger)1);
    }
    return place;
}

// The nearest window is painted last: the one that has been passed, then the
// front, then the others by their places.
+ (NSArray *)paintOrderForCount:(NSUInteger)count position:(double)position {
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [order addObject:@(i)];
    }
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        double pa = URSDeckPaintPlace([a unsignedIntegerValue], count, position);
        double pb = URSDeckPaintPlace([b unsignedIntegerValue], count, position);
        if (pa > pb) {
            return NSOrderedAscending;
        }
        return pa < pb ? NSOrderedDescending : NSOrderedSame;
    }];
    return order;
}

@end
