/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A plane-to-plane projective map in homogeneous coordinates, m[row][column],
// applied to column vectors (x, y, 1).  XRender takes exactly this matrix as
// a picture transform and divides by w itself, so a window turned in depth
// is drawn by the server in one composite.
typedef struct {
    double m[3][3];
} URSProjectiveMatrix;

URSProjectiveMatrix URSProjectiveMatrixIdentity(void);
URSProjectiveMatrix URSProjectiveMatrixTranslation(double tx, double ty);
// a applied after b.
URSProjectiveMatrix URSProjectiveMatrixMultiply(URSProjectiveMatrix a, URSProjectiveMatrix b);
// NO for a singular matrix (a plane seen exactly edge-on).
BOOL URSProjectiveMatrixInvert(URSProjectiveMatrix m, URSProjectiveMatrix *inverse);
NSPoint URSProjectiveMatrixMapPoint(URSProjectiveMatrix m, NSPoint p);
// Bounding box of a rect's image; a projective map keeps lines straight, so
// the four corners bound it as long as the rect stays in front of the viewer.
NSRect URSProjectiveMatrixMapRectBounds(URSProjectiveMatrix m, NSRect r);
// The same map scaled for an XRender transform, whose entries and whose
// results (x, y and w for every pixel of area, the points it is applied to)
// are all 16.16 fixed point: a map that only moves and scales is kept exact
// (w stays 1, so the server keeps its fast affine path); a perspective map
// is scaled up until the largest entry or result over area reaches
// URSProjectiveFixedPointLimit, because its perspective row is far below 1
// and would otherwise lose most of its bits.  A result beyond the range
// makes the server sample nothing (or garbage) for that pixel.
URSProjectiveMatrix URSProjectiveMatrixForFixedPoint(URSProjectiveMatrix m, NSRect area);
extern const double URSProjectiveFixedPointLimit;

// The pixels of area (whole pixels) whose centres toPicture sends at least
// margin inside a picture of the given size, as one rect per pixel row, top
// to bottom; returns how many (at most capacity).  pixman samples garbage
// for a pixel whose projective source point is negative instead of leaving
// it out, so a projective composite has to be clipped to these.
NSUInteger URSProjectiveInsideSpans(URSProjectiveMatrix toPicture, NSSize picture, double margin,
                                    NSRect area, NSRect *spans, NSUInteger capacity);

// One frame of a window turned in depth.  Coordinates are window-local:
// origin at the window's top left corner where it really is, y down, pixels.
typedef struct URSWindowProjection {
    // Face picture pixel to window-local screen pixel, and back.
    URSProjectiveMatrix toScreen;
    URSProjectiveMatrix toFace;
    // 0 paints the face as it is, 1 black.
    double shading;
    // The back of the window is in view: a plain panel, not the content.
    BOOL backFace;
} URSWindowProjection;
