/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Headless: the window flip's perspective, shading, damage and timing are
// pure maths, checked here without an X server.

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSFlipGeometry.m"

static NSString * const URSFlipTestName = @"window flip geometry";

static BOOL near(double a, double b, double tolerance) {
    return fabs(a - b) <= tolerance;
}

static BOOL pointNear(NSPoint a, NSPoint b, double tolerance) {
    return near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance);
}

static BOOL cornersAreRect(NSPoint *c, NSRect r, double tolerance) {
    return pointNear(c[0], NSMakePoint(NSMinX(r), NSMinY(r)), tolerance)
        && pointNear(c[1], NSMakePoint(NSMaxX(r), NSMinY(r)), tolerance)
        && pointNear(c[2], NSMakePoint(NSMaxX(r), NSMaxY(r)), tolerance)
        && pointNear(c[3], NSMakePoint(NSMinX(r), NSMaxY(r)), tolerance);
}

static BOOL rectContainsPoint(NSRect r, NSPoint p) {
    return p.x >= NSMinX(r) && p.x <= NSMaxX(r) && p.y >= NSMinY(r) && p.y <= NSMaxY(r);
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    START_SET([URSFlipTestName UTF8String])

    NSSize size = NSMakeSize(400, 300);
    NSRect window = NSMakeRect(0, 0, size.width, size.height);
    URSFlipGeometry *g = [[URSFlipGeometry alloc] initWithSize:size];
    NSPoint c[4];

    // At rest the picture is exactly where the window is, front and back,
    // so a flip starts and ends without a jump.
    [g getCorners:c atAngle:0.0];
    PASS(cornersAreRect(c, window, 1e-9), "at 0 degrees the front covers the window rect exactly");
    PASS(![g showsBackFaceAtAngle:0.0], "at 0 degrees the front is in view");
    [g getCorners:c atAngle:180.0];
    PASS(cornersAreRect(c, window, 1e-9), "at 180 degrees the back covers the window rect exactly");
    PASS([g showsBackFaceAtAngle:180.0], "at 180 degrees the back is in view");
    PASS([g showsBackFaceAtAngle:91.0] && ![g showsBackFaceAtAngle:89.0],
         "the back comes into view past 90 degrees");

    // Perspective, not a scale: the edge coming towards the viewer grows.
    [g getCorners:c atAngle:45.0];
    double leftHeight = c[3].y - c[0].y;
    double rightHeight = c[2].y - c[1].y;
    PASS(rightHeight > leftHeight + 20.0, "at 45 degrees the near edge is taller than the far edge (%.1f vs %.1f)",
         rightHeight, leftHeight);
    PASS(rightHeight > size.height && leftHeight < size.height,
         "the near edge grows beyond the window height and the far edge shrinks");
    PASS(near(c[0].y + c[3].y, size.height, 1e-9) && near(c[1].y + c[2].y, size.height, 1e-9),
         "the turned window stays centred vertically");
    double projectedWidth = c[1].x - c[0].x;
    PASS(projectedWidth < size.width && projectedWidth > 0.5 * size.width,
         "at 45 degrees the face is narrower than the window");

    // Turning on from 45 to 135 degrees is the mirror image: the same
    // outline, flipped about the vertical centre line.
    NSPoint m[4];
    [g getCorners:m atAngle:135.0];
    BOOL mirrored = YES;
    for (int i = 0; i < 4; i++) {
        NSPoint expected = NSMakePoint(size.width - c[i].x, c[i].y);
        BOOL found = NO;
        for (int j = 0; j < 4; j++) {
            found = found || pointNear(m[j], expected, 1e-6);
        }
        mirrored = mirrored && found;
    }
    PASS(mirrored, "the outline at 135 degrees mirrors the one at 45 degrees");
    PASS(m[0].x < m[1].x, "the back face reads left to right (it is not shown mirrored)");

    URSWindowProjection p;
    PASS(![g getProjection:&p atAngle:90.0], "edge-on at 90 degrees there is nothing to paint");
    PASS([g getProjection:&p atAngle:45.0] && !p.backFace, "at 45 degrees the front is painted");

    // The map from the screen back into the picture is what XRender gets;
    // it must land on the picture's corners, also after rounding to 16.16.
    URSProjectiveMatrix fixed = URSProjectiveMatrixForFixedPoint(p.toFace);
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            fixed.m[i][j] = round(fixed.m[i][j] * 65536.0) / 65536.0;
        }
    }
    NSPoint faceCorners[4] = { {0, 0}, {size.width, 0}, {size.width, size.height}, {0, size.height} };
    BOOL roundTrip = YES, fixedRoundTrip = YES;
    double worst = 0.0;
    for (int i = 0; i < 4; i++) {
        NSPoint back = URSProjectiveMatrixMapPoint(p.toFace, c[i]);
        roundTrip = roundTrip && pointNear(back, faceCorners[i], 1e-6);
        NSPoint backFixed = URSProjectiveMatrixMapPoint(fixed, c[i]);
        worst = MAX(worst, MAX(fabs(backFixed.x - faceCorners[i].x), fabs(backFixed.y - faceCorners[i].y)));
    }
    fixedRoundTrip = worst < 0.25;
    PASS(roundTrip, "screen to face undoes face to screen");
    PASS(fixedRoundTrip, "in 16.16 fixed point the corners still land within a quarter pixel (%.3f)", worst);
    double largest = 0.0;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            largest = MAX(largest, fabs(URSProjectiveMatrixForFixedPoint(p.toFace).m[i][j]));
        }
    }
    PASS(near(largest, URSProjectiveFixedPointLimit, 1e-6), "a perspective map is scaled to use the fixed point range");
    URSProjectiveMatrix shift = URSProjectiveMatrixForFixedPoint(URSProjectiveMatrixTranslation(-12.0, 7.0));
    PASS(shift.m[2][2] == 1.0 && shift.m[0][2] == -12.0 && shift.m[0][0] == 1.0,
         "a plain shift is left exact, so the server keeps its affine path");

    [g getProjection:&p atAngle:180.0];
    PASS(p.backFace && pointNear(URSProjectiveMatrixMapPoint(p.toFace, NSMakePoint(10, 20)), NSMakePoint(10, 20), 1e-9),
         "at 180 degrees the back face maps one to one onto the window");

    // Shading: none at rest, darkest edge-on, growing as the face turns away.
    PASS([g shadingAtAngle:0.0] == 0.0 && [g shadingAtAngle:180.0] == 0.0, "no shading at rest");
    PASS([g shadingAtAngle:30.0] < [g shadingAtAngle:60.0] && [g shadingAtAngle:60.0] < [g shadingAtAngle:89.0],
         "the face darkens as it turns away");
    PASS([g shadingAtAngle:89.0] <= 0.5, "the shading stays light");
    PASS(near([g shadingAtAngle:120.0], [g shadingAtAngle:60.0], 1e-9), "the back lightens the way the front darkened");

    // Damage: the swept rect holds every corner of every frame, including
    // the near edge reaching beyond the window rect.
    NSRect swept = [g sweptRectFromAngle:0.0 toAngle:180.0];
    BOOL containsAll = YES;
    for (int a = 0; a <= 1800; a++) {
        [g getCorners:c atAngle:a / 10.0];
        for (int i = 0; i < 4; i++) {
            containsAll = containsAll && rectContainsPoint(swept, c[i]);
        }
    }
    PASS(containsAll, "the damage of a full flip contains every projected corner");
    PASS(NSMinX(swept) < 0.0 && NSMaxX(swept) > size.width && NSMinY(swept) < 0.0 && NSMaxY(swept) > size.height,
         "the damage reaches beyond the window rect on every side");
    NSRect part = [g sweptRectFromAngle:170.0 toAngle:100.0];
    BOOL containsPart = YES;
    for (int a = 1000; a <= 1700; a++) {
        [g getCorners:c atAngle:a / 10.0];
        for (int i = 0; i < 4; i++) {
            containsPart = containsPart && rectContainsPoint(part, c[i]);
        }
    }
    PASS(containsPart, "the damage of a partial turn back contains every projected corner");
    PASS(NSWidth(part) <= NSWidth(swept) && NSHeight(part) < NSHeight(swept),
         "a partial turn damages no more than a full flip");
    PASS(NSEqualRects(swept, NSIntegralRect(swept)), "the damage is in whole pixels");

    // Timing: eased in and out, from start to end without going back.
    PASS([URSFlipGeometry angleAtProgress:0.0 fromAngle:0.0 toAngle:180.0] == 0.0, "the turn starts at its start angle");
    PASS([URSFlipGeometry angleAtProgress:1.0 fromAngle:0.0 toAngle:180.0] == 180.0, "the turn ends at its end angle");
    PASS([URSFlipGeometry angleAtProgress:1.0 fromAngle:180.0 toAngle:0.0] == 0.0, "the turn back ends at 0");
    BOOL monotonic = YES;
    double previous = 0.0;
    for (int i = 1; i <= 100; i++) {
        double angle = [URSFlipGeometry angleAtProgress:i / 100.0 fromAngle:0.0 toAngle:180.0];
        monotonic = monotonic && angle >= previous;
        previous = angle;
    }
    PASS(monotonic, "the angle never turns back during a flip");
    PASS([URSFlipGeometry angleAtProgress:0.1 fromAngle:0.0 toAngle:180.0] < 18.0 &&
         [URSFlipGeometry angleAtProgress:0.9 fromAngle:0.0 toAngle:180.0] > 162.0,
         "the turn eases in and out");
    PASS(near([URSFlipGeometry angleAtProgress:0.5 fromAngle:0.0 toAngle:180.0], 90.0, 1e-9),
         "the turn is symmetric in time");
    PASS([URSFlipGeometry angleAtProgress:2.0 fromAngle:0.0 toAngle:180.0] == 180.0 &&
         [URSFlipGeometry angleAtProgress:-1.0 fromAngle:0.0 toAngle:180.0] == 0.0,
         "progress outside 0..1 stays at the ends");

    END_SET([URSFlipTestName UTF8String])
    [pool release];
    return 0;
}
