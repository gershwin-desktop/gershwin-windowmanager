/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWobblyModel.h"
#import <math.h>

// Masses per side.  Few enough to stay cheap, enough for a soft bend.
#define URSWobblyNodes 5
// Painted mesh per side; finer than the masses so the bend looks smooth.
static const NSUInteger URSWobblyMeshCells = 10;

// Spring to each mass's place on the window: sets how fast the window
// catches up and how often it wobbles (about two times a second).
static const double URSWobblyHomeStiffness = 150.0;
// Springs between neighbours keep the window one piece rather than a cloud.
static const double URSWobblyNeighbourStiffness = 400.0;
// Damping of motion relative to the window: low enough to leave a few
// visible wobbles after letting go, high enough that they die down within
// about a second.
static const double URSWobblyDamping = 7.0;
// Damping of motion over the screen, as if brushing against it.  Makes a
// dragged window trail a little; much more would bend it into a peak at the
// pointer on every steady drag.
static const double URSWobblyDrag = 1.5;
static const double URSWobblySubstep = 1.0 / 240.0;
// After a stall (a busy event loop, a suspended process) the mesh moves on by
// one frame at most, not by the whole gap.
static const double URSWobblyMaxStep = 1.0 / 30.0;
// Resting thresholds, in pixels and pixels per second.
static const double URSWobblyRestBend = 0.25;
static const double URSWobblyRestSpeed = 3.0;
// However hard the window is flung, it never bends further than this share
// of its shorter side, which would read as broken rather than soft.
static const double URSWobblyMaxBendShare = 0.5;

typedef struct {
    double dx, dy;   // offset from the mass's place on the window
    double vx, vy;
} URSWobblyNode;

@implementation URSWobblyModel {
    URSWobblyNode _nodes[URSWobblyNodes][URSWobblyNodes];
    NSRect _windowRect;
    NSTimeInterval _time;
    // How fast each mass's place on the window moves, over the last step.
    double _homeVX[URSWobblyNodes][URSWobblyNodes];
    double _homeVY[URSWobblyNodes][URSWobblyNodes];
    NSUInteger _grabColumn;
    NSUInteger _grabRow;
    BOOL _grabbed;
}

- (instancetype)initWithWindowRect:(NSRect)windowRect
                         grabPoint:(NSPoint)grabPoint
                              time:(NSTimeInterval)now {
    self = [super init];
    if (self) {
        _windowRect = windowRect;
        _time = now;
        _grabbed = YES;
        double u = (grabPoint.x - NSMinX(windowRect)) / MAX(1.0, NSWidth(windowRect));
        double v = (grabPoint.y - NSMinY(windowRect)) / MAX(1.0, NSHeight(windowRect));
        _grabColumn = (NSUInteger)lround(MIN(1.0, MAX(0.0, u)) * (URSWobblyNodes - 1));
        _grabRow = (NSUInteger)lround(MIN(1.0, MAX(0.0, v)) * (URSWobblyNodes - 1));
    }
    return self;
}

- (BOOL)grabbed {
    return _grabbed;
}

- (void)releaseGrab {
    _grabbed = NO;
}

- (NSUInteger)columns {
    return URSWobblyMeshCells;
}

- (NSUInteger)rows {
    return URSWobblyMeshCells;
}

- (BOOL)isPinnedColumn:(NSUInteger)c row:(NSUInteger)r {
    return _grabbed && c == _grabColumn && r == _grabRow;
}

// The window moved or changed size: the masses stay where they are on the
// screen, so their offsets from their new places change by as much.
- (void)followWindowRect:(NSRect)windowRect over:(double)elapsed {
    for (NSUInteger r = 0; r < URSWobblyNodes; r++) {
        for (NSUInteger c = 0; c < URSWobblyNodes; c++) {
            double fu = (double)c / (URSWobblyNodes - 1);
            double fv = (double)r / (URSWobblyNodes - 1);
            double moveX = (NSMinX(windowRect) + NSWidth(windowRect) * fu)
                         - (NSMinX(_windowRect) + NSWidth(_windowRect) * fu);
            double moveY = (NSMinY(windowRect) + NSHeight(windowRect) * fv)
                         - (NSMinY(_windowRect) + NSHeight(_windowRect) * fv);
            _nodes[r][c].dx -= moveX;
            _nodes[r][c].dy -= moveY;
            _homeVX[r][c] = elapsed > 0 ? moveX / elapsed : 0;
            _homeVY[r][c] = elapsed > 0 ? moveY / elapsed : 0;
        }
    }
    _windowRect = windowRect;
}

- (void)integrate:(double)dt {
    URSWobblyNode next[URSWobblyNodes][URSWobblyNodes];
    for (NSUInteger r = 0; r < URSWobblyNodes; r++) {
        for (NSUInteger c = 0; c < URSWobblyNodes; c++) {
            URSWobblyNode n = _nodes[r][c];
            // Between steps the places stand still, so v is the mass's speed
            // over the screen.
            double ax = -URSWobblyHomeStiffness * n.dx
                        - URSWobblyDamping * (n.vx - _homeVX[r][c]) - URSWobblyDrag * n.vx;
            double ay = -URSWobblyHomeStiffness * n.dy
                        - URSWobblyDamping * (n.vy - _homeVY[r][c]) - URSWobblyDrag * n.vy;
            static const int neighbours[4][2] = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} };
            for (int k = 0; k < 4; k++) {
                NSInteger nr = (NSInteger)r + neighbours[k][0];
                NSInteger nc = (NSInteger)c + neighbours[k][1];
                if (nr < 0 || nc < 0 || nr >= URSWobblyNodes || nc >= URSWobblyNodes) {
                    continue;
                }
                ax += URSWobblyNeighbourStiffness * (_nodes[nr][nc].dx - n.dx);
                ay += URSWobblyNeighbourStiffness * (_nodes[nr][nc].dy - n.dy);
            }
            n.vx += ax * dt;
            n.vy += ay * dt;
            n.dx += n.vx * dt;
            n.dy += n.vy * dt;
            next[r][c] = n;
        }
    }
    double maxBend = MIN(NSWidth(_windowRect), NSHeight(_windowRect)) * URSWobblyMaxBendShare;
    for (NSUInteger r = 0; r < URSWobblyNodes; r++) {
        for (NSUInteger c = 0; c < URSWobblyNodes; c++) {
            URSWobblyNode n = next[r][c];
            if ([self isPinnedColumn:c row:r]) {
                n = (URSWobblyNode){ 0, 0, 0, 0 };
            }
            double bend = hypot(n.dx, n.dy);
            if (bend > maxBend) {
                n.dx *= maxBend / bend;
                n.dy *= maxBend / bend;
                n.vx = 0;
                n.vy = 0;
            }
            _nodes[r][c] = n;
        }
    }
}

- (BOOL)atRest {
    for (NSUInteger r = 0; r < URSWobblyNodes; r++) {
        for (NSUInteger c = 0; c < URSWobblyNodes; c++) {
            URSWobblyNode n = _nodes[r][c];
            if (hypot(n.dx, n.dy) > URSWobblyRestBend ||
                hypot(n.vx, n.vy) > URSWobblyRestSpeed) {
                return NO;
            }
        }
    }
    return YES;
}

- (BOOL)stepToTime:(NSTimeInterval)now windowRect:(NSRect)windowRect {
    double elapsed = MIN(URSWobblyMaxStep, MAX(0.0, now - _time));
    [self followWindowRect:windowRect over:elapsed];
    _time = now;
    while (elapsed > 1e-9) {
        double dt = MIN(URSWobblySubstep, elapsed);
        [self integrate:dt];
        elapsed -= dt;
    }
    if (!_grabbed && [self atRest]) {
        memset(_nodes, 0, sizeof(_nodes));
        return NO;
    }
    return YES;
}

// Catmull-Rom weights: the curve passes through every mass and bends
// smoothly between them, where a straight blend would leave kinks.
static void URSWobblyCurveWeights(double t, double w[4]) {
    double t2 = t * t, t3 = t2 * t;
    w[0] = 0.5 * (-t3 + 2.0 * t2 - t);
    w[1] = 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0);
    w[2] = 0.5 * (-3.0 * t3 + 4.0 * t2 + t);
    w[3] = 0.5 * (t3 - t2);
}

- (NSPoint)pointAtColumn:(NSUInteger)column row:(NSUInteger)row {
    double u = (double)column / URSWobblyMeshCells * (URSWobblyNodes - 1);
    double v = (double)row / URSWobblyMeshCells * (URSWobblyNodes - 1);
    NSInteger c0 = MIN((NSInteger)u, URSWobblyNodes - 2);
    NSInteger r0 = MIN((NSInteger)v, URSWobblyNodes - 2);
    double wu[4], wv[4];
    URSWobblyCurveWeights(u - c0, wu);
    URSWobblyCurveWeights(v - r0, wv);
    double dx = 0, dy = 0;
    for (int j = 0; j < 4; j++) {
        NSInteger r = MIN(MAX(r0 - 1 + j, 0), URSWobblyNodes - 1);
        for (int i = 0; i < 4; i++) {
            NSInteger c = MIN(MAX(c0 - 1 + i, 0), URSWobblyNodes - 1);
            dx += wu[i] * wv[j] * _nodes[r][c].dx;
            dy += wu[i] * wv[j] * _nodes[r][c].dy;
        }
    }
    return NSMakePoint(NSMinX(_windowRect) + NSWidth(_windowRect) * column / URSWobblyMeshCells + dx,
                       NSMinY(_windowRect) + NSHeight(_windowRect) * row / URSWobblyMeshCells + dy);
}

- (NSRect)reach {
    double x1 = INFINITY, y1 = INFINITY, x2 = -INFINITY, y2 = -INFINITY;
    for (NSUInteger r = 0; r <= URSWobblyMeshCells; r++) {
        for (NSUInteger c = 0; c <= URSWobblyMeshCells; c++) {
            NSPoint p = [self pointAtColumn:c row:r];
            x1 = MIN(x1, p.x);
            y1 = MIN(y1, p.y);
            x2 = MAX(x2, p.x);
            y2 = MAX(y2, p.y);
        }
    }
    return NSMakeRect(x1, y1, x2 - x1, y2 - y1);
}

@end
