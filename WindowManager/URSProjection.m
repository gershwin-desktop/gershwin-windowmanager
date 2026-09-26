/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSProjection.h"
#import <math.h>

// Half the 16.16 range: headroom for the server multiplying entries by
// coordinates of the same magnitude.
const double URSProjectiveFixedPointLimit = 16384.0;

URSProjectiveMatrix URSProjectiveMatrixIdentity(void) {
    return URSProjectiveMatrixTranslation(0.0, 0.0);
}

URSProjectiveMatrix URSProjectiveMatrixTranslation(double tx, double ty) {
    URSProjectiveMatrix r = {{ { 1.0, 0.0, tx }, { 0.0, 1.0, ty }, { 0.0, 0.0, 1.0 } }};
    return r;
}

URSProjectiveMatrix URSProjectiveMatrixMultiply(URSProjectiveMatrix a, URSProjectiveMatrix b) {
    URSProjectiveMatrix r;
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            r.m[i][j] = a.m[i][0] * b.m[0][j] + a.m[i][1] * b.m[1][j] + a.m[i][2] * b.m[2][j];
        }
    }
    return r;
}

BOOL URSProjectiveMatrixInvert(URSProjectiveMatrix a, URSProjectiveMatrix *inverse) {
    const double (*m)[3] = a.m;
    double c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1];
    double c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2];
    double c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0];
    double det = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02;
    if (fabs(det) < 1e-12) {
        return NO;
    }
    URSProjectiveMatrix r = {{
        { c00, m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1] },
        { c01, m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2] },
        { c02, m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0] },
    }};
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            r.m[i][j] /= det;
        }
    }
    *inverse = r;
    return YES;
}

NSPoint URSProjectiveMatrixMapPoint(URSProjectiveMatrix a, NSPoint p) {
    double x = a.m[0][0] * p.x + a.m[0][1] * p.y + a.m[0][2];
    double y = a.m[1][0] * p.x + a.m[1][1] * p.y + a.m[1][2];
    double w = a.m[2][0] * p.x + a.m[2][1] * p.y + a.m[2][2];
    return NSMakePoint(x / w, y / w);
}

NSRect URSProjectiveMatrixMapRectBounds(URSProjectiveMatrix a, NSRect r) {
    NSPoint corners[4] = {
        { NSMinX(r), NSMinY(r) }, { NSMaxX(r), NSMinY(r) },
        { NSMaxX(r), NSMaxY(r) }, { NSMinX(r), NSMaxY(r) },
    };
    double x1 = INFINITY, y1 = INFINITY, x2 = -INFINITY, y2 = -INFINITY;
    for (int i = 0; i < 4; i++) {
        NSPoint p = URSProjectiveMatrixMapPoint(a, corners[i]);
        x1 = MIN(x1, p.x);
        y1 = MIN(y1, p.y);
        x2 = MAX(x2, p.x);
        y2 = MAX(y2, p.y);
    }
    return NSMakeRect(x1, y1, x2 - x1, y2 - y1);
}

URSProjectiveMatrix URSProjectiveMatrixForFixedPoint(URSProjectiveMatrix a, NSRect area) {
    double scale;
    if (a.m[2][0] == 0.0 && a.m[2][1] == 0.0) {
        scale = 1.0 / a.m[2][2];
    } else {
        // Each of x, y and w is linear in the point, so over a rect it is
        // largest in magnitude at a corner.
        NSPoint corners[4] = {
            { NSMinX(area), NSMinY(area) }, { NSMaxX(area), NSMinY(area) },
            { NSMaxX(area), NSMaxY(area) }, { NSMinX(area), NSMaxY(area) },
        };
        double largest = 0.0;
        for (int i = 0; i < 3; i++) {
            for (int j = 0; j < 3; j++) {
                largest = MAX(largest, fabs(a.m[i][j]));
            }
            for (int k = 0; k < 4; k++) {
                largest = MAX(largest, fabs(a.m[i][0] * corners[k].x + a.m[i][1] * corners[k].y
                                            + a.m[i][2]));
            }
        }
        scale = URSProjectiveFixedPointLimit / largest;
    }
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            a.m[i][j] *= scale;
        }
    }
    return a;
}

NSUInteger URSProjectiveInsideSpans(URSProjectiveMatrix toPicture, NSSize picture, double margin,
                                    NSRect area, NSRect *spans, NSUInteger capacity) {
    return 0;
}
