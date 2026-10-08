/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Headless: where the titlebar strip and the terminal go on a window's
// back, what "Flip Window" does, and which orphaned terminal goes back
// onto a restarted application's window, checked without an X server.

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSFlipSideGeometry.m"
#include "../WindowManager/URSFlipSidePlan.m"
#include "../WindowManager/URSFlipSideOrphans.m"
#import "URSFlipGeometry.h"

static BOOL near(double a, double b, double tolerance) {
    return fabs(a - b) <= tolerance;
}

static BOOL pointNear(NSPoint a, NSPoint b, double tolerance) {
    return near(a.x, b.x, tolerance) && near(a.y, b.y, tolerance);
}

static URSFlipSideAction plan(BOOL backInView, BOOL waiting, BOOL enabled,
                              BOOL hasFlipSide, BOOL helperRunning) {
    return [URSFlipSidePlan actionWithBackInView:backInView waiting:waiting enabled:enabled
                                     hasFlipSide:hasFlipSide helperRunning:helperRunning];
}

int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    START_SET("flip side layout")
    NSSize frame = NSMakeSize(400, 300);
    NSPoint offset = NSMakePoint(0, 22);
    NSSize side = NSMakeSize(400, 278);
    URSFlipSideGeometry *g = [[[URSFlipSideGeometry alloc] initWithFrameSize:frame
                                                                clientOffset:offset
                                                                flipSideSize:side] autorelease];

    PASS(NSEqualRects([g titlebarStrip], NSMakeRect(0, 0, 400, 22)),
         "the titlebar strip is the frame's full width down to the client area");
    PASS(NSEqualRects([g flipSideRect], NSMakeRect(0, 22, 400, 278)),
         "the flip side fills the client area");
    PASS(NSMaxY([g titlebarStrip]) == NSMinY([g flipSideRect]),
         "strip and flip side meet without a gap or an overlap");

    URSFlipSideGeometry *none = [[[URSFlipSideGeometry alloc] initWithFrameSize:frame
                                                                   clientOffset:NSMakePoint(0, 0)
                                                                   flipSideSize:frame] autorelease];
    PASS(NSIsEmptyRect([none titlebarStrip]), "a window without a titlebar shows no strip");
    URSFlipSideGeometry *outside = [[[URSFlipSideGeometry alloc] initWithFrameSize:frame
                                                                      clientOffset:NSMakePoint(0, 320)
                                                                      flipSideSize:side] autorelease];
    PASS(NSIsEmptyRect([outside titlebarStrip]),
         "a flip side that does not start inside the frame shows no strip");

    // A plain face: screen and face coincide, so the matrix only moves the
    // client offset away.
    URSProjectiveMatrix flat = [g flipSideMatrixForFaceMatrix:URSProjectiveMatrixIdentity()];
    PASS(pointNear(URSProjectiveMatrixMapPoint(flat, NSMakePoint(10, 27)), NSMakePoint(10, 5), 1e-9),
         "a face point in the client area samples the flip side at the same place in it");
    URSFlipSideGeometry *shifted = [[[URSFlipSideGeometry alloc] initWithFrameSize:frame
                                                                      clientOffset:NSMakePoint(5, 22)
                                                                      flipSideSize:NSMakeSize(390, 273)] autorelease];
    PASS(pointNear(URSProjectiveMatrixMapPoint([shifted flipSideMatrixForFaceMatrix:URSProjectiveMatrixIdentity()],
                                               NSMakePoint(15, 27)), NSMakePoint(10, 5), 1e-9),
         "a side border moves the flip side along with the client");
    END_SET("flip side layout")

    START_SET("flip side on the turned window")
    NSSize frame = NSMakeSize(400, 300);
    NSPoint offset = NSMakePoint(0, 22);
    NSSize side = NSMakeSize(400, 278);
    URSFlipSideGeometry *g = [[[URSFlipSideGeometry alloc] initWithFrameSize:frame
                                                                clientOffset:offset
                                                                flipSideSize:side] autorelease];
    URSFlipGeometry *turn = [[[URSFlipGeometry alloc] initWithSize:frame] autorelease];
    URSWindowProjection back;
    PASS([turn getProjection:&back atAngle:180.0] && back.backFace, "at 180 degrees the back is in view");

    // At rest on the back the terminal sits exactly where the client is,
    // so a click lands on the character drawn under it.
    URSProjectiveMatrix toSide = [g flipSideMatrixForFaceMatrix:back.toFace];
    PASS(pointNear(URSProjectiveMatrixMapPoint(toSide, NSMakePoint(10, 27)), NSMakePoint(10, 5), 1e-9),
         "at rest on the back the flip side lies exactly over the client area");
    NSPoint left = URSProjectiveMatrixMapPoint(toSide, NSMakePoint(100, 150));
    NSPoint right = URSProjectiveMatrixMapPoint(toSide, NSMakePoint(300, 150));
    PASS(left.x < right.x, "the flip side reads left to right, not mirrored");
    NSPoint top = URSProjectiveMatrixMapPoint(toSide, NSMakePoint(200, 50));
    NSPoint bottom = URSProjectiveMatrixMapPoint(toSide, NSMakePoint(200, 250));
    PASS(top.y < bottom.y, "the flip side is upright");
    NSRect strip = [g titlebarStrip];
    PASS(pointNear(URSProjectiveMatrixMapPoint(back.toScreen, NSMakePoint(NSMinX(strip), NSMinY(strip))),
                   NSMakePoint(0, 0), 1e-9) &&
         pointNear(URSProjectiveMatrixMapPoint(back.toScreen, NSMakePoint(NSMaxX(strip), NSMaxY(strip))),
                   NSMakePoint(400, 22), 1e-9),
         "the titlebar strip is painted where the real titlebar is, so its buttons work");

    // While turning, a point of the flip side goes to the screen through
    // the face and comes back through the matrix to the same pixel.
    URSWindowProjection turning;
    PASS([turn getProjection:&turning atAngle:150.0] && turning.backFace,
         "at 150 degrees the back is in view");
    URSProjectiveMatrix toSideTurning = [g flipSideMatrixForFaceMatrix:turning.toFace];
    NSPoint sidePoint = NSMakePoint(37, 91);
    NSPoint onScreen = URSProjectiveMatrixMapPoint(turning.toScreen,
                                                   NSMakePoint(sidePoint.x + offset.x, sidePoint.y + offset.y));
    PASS(pointNear(URSProjectiveMatrixMapPoint(toSideTurning, onScreen), sidePoint, 1e-6),
         "during the turn the flip side stays fixed on the back");
    NSPoint sideLeft = URSProjectiveMatrixMapPoint(turning.toScreen, NSMakePoint(offset.x, offset.y + 139));
    NSPoint sideRight = URSProjectiveMatrixMapPoint(turning.toScreen,
                                                    NSMakePoint(offset.x + side.width, offset.y + 139));
    PASS(sideLeft.x < sideRight.x, "during the turn the flip side is not mirrored either");
    END_SET("flip side on the turned window")

    START_SET("flip side plan")
    PASS(plan(YES, NO, YES, YES, YES) == URSFlipSideActionTurnToFront &&
         plan(YES, NO, NO, NO, NO) == URSFlipSideActionTurnToFront,
         "with the back in view the window turns to its front, whatever else is known");
    PASS(plan(NO, YES, YES, NO, YES) == URSFlipSideActionCancelWait,
         "asking again while the terminal starts calls the turn off");
    PASS(plan(NO, NO, NO, NO, NO) == URSFlipSideActionPlainTurn,
         "switched off, the window turns to its plain back");
    PASS(plan(NO, NO, NO, YES, YES) == URSFlipSideActionEndFlipSideAndPlainTurn &&
         plan(NO, NO, NO, NO, YES) == URSFlipSideActionEndFlipSideAndPlainTurn,
         "switched off, a terminal from before goes and the back is plain");
    PASS(plan(NO, NO, YES, YES, YES) == URSFlipSideActionTurnToFlipSide &&
         plan(NO, NO, YES, YES, NO) == URSFlipSideActionTurnToFlipSide,
         "with its flip side there the window turns at once");
    PASS(plan(NO, NO, YES, NO, YES) == URSFlipSideActionWaitForFlipSide,
         "a terminal still starting is waited for, not started twice");
    PASS(plan(NO, NO, YES, NO, NO) == URSFlipSideActionLookUpSourceDirectory,
         "without anything yet the source directory decides");
    PASS([URSFlipSidePlan flipSideStacksAboveParentWithBackShown:YES] &&
         ![URSFlipSidePlan flipSideStacksAboveParentWithBackShown:NO],
         "the flip side takes the input over the client area only with the back shown");
    END_SET("flip side plan")

    START_SET("orphaned flip sides")
    URSFlipSideOrphans *orphans = [[URSFlipSideOrphans new] autorelease];
    NSObject *taskA = [[NSObject new] autorelease];
    PASS([orphans count] == 0 && [[orphans orphans] count] == 0 &&
         [orphans oldestOrphanOfApplication:@"TextEdit" directory:@"/src/TextEdit"] == nil,
         "nothing is orphaned at first");

    [orphans addOrphanWindow:10 application:@"TextEdit" directory:@"/src/TextEdit" token:taskA];
    [orphans addOrphanWindow:20 application:@"TextEdit" directory:@"/src/TextEdit" token:@(4321)];
    [orphans addOrphanWindow:30 application:@"Ink" directory:@"/src/Ink" token:nil];
    PASS([orphans count] == 3, "three orphans are kept");
    PASS([orphans hasOrphansOfApplication:@"TextEdit"] && [orphans hasOrphansOfApplication:@"Ink"] &&
         ![orphans hasOrphansOfApplication:@"Terminal"] && ![orphans hasOrphansOfApplication:nil],
         "the application alone says whether a directory lookup is worth it");
    PASS([[orphans oldestOrphanOfApplication:@"TextEdit" directory:@"/src/TextEdit"] window] == 10,
         "a restarted application gets the orphan that waited longest");
    PASS([orphans oldestOrphanOfApplication:@"TextEdit" directory:@"/src/Ink"] == nil &&
         [orphans oldestOrphanOfApplication:@"Ink" directory:@"/src/TextEdit"] == nil,
         "application and directory must both match");
    PASS([orphans oldestOrphanOfApplication:nil directory:@"/src/TextEdit"] == nil &&
         [orphans oldestOrphanOfApplication:@"TextEdit" directory:nil] == nil,
         "an unknown application or directory matches nothing");

    URSFlipSideOrphan *ink = [orphans orphanWithWindow:30];
    PASS(ink != nil && [[ink application] isEqualToString:@"Ink"] &&
         [[ink directory] isEqualToString:@"/src/Ink"] && [ink token] == nil,
         "an orphan is found by its window");
    PASS([[orphans orphanWithToken:taskA] window] == 10 &&
         [[orphans orphanWithToken:@(4321)] window] == 20 &&
         [orphans orphanWithToken:@(1)] == nil && [orphans orphanWithToken:nil] == nil,
         "an orphan is found by what ends its terminal, a process id by value");

    [orphans removeOrphanWithWindow:10];
    PASS([orphans count] == 2 && [orphans orphanWithWindow:10] == nil &&
         [[orphans oldestOrphanOfApplication:@"TextEdit" directory:@"/src/TextEdit"] window] == 20,
         "once taken, the next oldest is next");
    [orphans removeOrphanWithWindow:99];
    PASS([orphans count] == 2, "removing an unknown window changes nothing");

    [orphans addOrphanWindow:40 application:@"TextEdit" directory:@"/src/TextEdit" token:nil];
    [orphans addOrphanWindow:20 application:@"TextEdit" directory:@"/src/TextEdit" token:@(4321)];
    PASS([orphans count] == 3 &&
         [[orphans oldestOrphanOfApplication:@"TextEdit" directory:@"/src/TextEdit"] window] == 40,
         "a window orphaned again is not kept twice and counts as the newest");
    PASS([[[orphans orphans] valueForKey:@"window"] isEqual:(@[ @30, @40, @20 ])],
         "the orphans are listed oldest first");

    [orphans addOrphanWindow:50 application:@"Ink" directory:nil token:nil];
    PASS([[orphans oldestOrphanOfApplication:@"Ink" directory:@"/src/Ink"] window] == 30 &&
         [orphans hasOrphansOfApplication:@"Ink"],
         "an orphan whose directory is unknown never goes back onto a window");
    [orphans removeOrphanWithWindow:30];
    PASS([orphans oldestOrphanOfApplication:@"Ink" directory:@"/src/Ink"] == nil,
         "nor is it taken once it is the only one left");
    END_SET("orphaned flip sides")

    [pool drain];
    return 0;
}
