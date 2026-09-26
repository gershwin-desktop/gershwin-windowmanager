/* repairflush.m - pins that -[URSCompositingManager repairWindow:] does not
 * perform its own synchronous xcb_flush.
 *
 * Every DamageNotify for a tracked window reaches repairWindow: (see
 * -handleDamageNotify:area:).  URSHybridEventHandler already batches the
 * connection flush for a whole burst of XCB events (needFlush /
 * eventNeedsFlush: in -processAvailableXCBEvents), and unconditionally calls
 * -performRepairNow right after that batch whenever the compositor has
 * pending damage - which paints and flushes once for the whole batch.  A
 * synchronous flush inside repairWindow: itself defeats that batching: on a
 * desktop with continuously redrawing clients (e.g. a terminal scrolling
 * output) it turns one flush per batch into one flush per DamageNotify.
 *
 * The ARC-compiled unit under test lives in repairflush_unit.m (Testing.h's
 * PASS macro is not ARC-safe, so it cannot share a translation unit with
 * the #included URSCompositingManager.m).
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

extern int RFRunRepairWindowTest(int *outConnected, int *outScreenOk,
                                 int *outInitialized, int *outHasPendingDamage,
                                 int *outFlushCount);

int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  int connected = 0, screenOk = 0, initialized = 0;
  int hasPendingDamage = 0, flushCount = -1;
  RFRunRepairWindowTest(&connected, &screenOk, &initialized,
                        &hasPendingDamage, &flushCount);

  PASS(connected, "connects to the isolated test Xvfb display");
  PASS(screenOk, "reads the test display's screen");
  PASS(initialized, "initializes against the test display's XCB extensions");
  PASS(hasPendingDamage,
       "repairWindow: still registers the damage for the next paint pass");
  PASS(flushCount == 0,
       "repairWindow: does not flush the connection itself (batched flush handles it)");

  [pool release];
  return 0;
}
