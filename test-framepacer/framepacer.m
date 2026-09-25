/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// When the compositor may paint while a client (a scrolling browser) damages
// its window faster than the screen refreshes.  Headless.
// Run with:  gnustep-tests test-framepacer

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSFramePacer.m"

static const NSTimeInterval frame = 1.0 / 60.0;

// The compositor's loop in miniature: every damage asks the pacer; a paint
// runs only when it says so, and a deferred paint runs when its delay is up.
// Returns how many paints the damage times produced up to `until`.
static int paintsForDamage(URSFramePacer *p, const NSTimeInterval *times, int n,
                           NSTimeInterval until)
{
  int paints = 0;
  NSTimeInterval deferredAt = 0;
  BOOL pending = NO;
  for (int i = 0; i < n; i++) {
    if (deferredAt > 0 && deferredAt <= times[i]) {
      [p notePaintAt: deferredAt];
      paints++;
      pending = NO;
      deferredAt = 0;
    }
    pending = YES;
    NSTimeInterval d = [p delayBeforePaintAt: times[i]];
    if (d == 0) {
      [p notePaintAt: times[i]];
      paints++;
      pending = NO;
    } else if (d > 0 && deferredAt == 0) {
      deferredAt = times[i] + d;
    }
  }
  if (pending && deferredAt > 0 && deferredAt <= until) {
    [p notePaintAt: deferredAt];
    paints++;
  }
  return paints;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("clock paced (no presentation feedback)")
  {
    URSFramePacer *p = [[URSFramePacer alloc] initWithMinimumInterval: frame];
    PASS([p delayBeforePaintAt: 10.0] == 0, "the first damage paints at once");
    [p notePaintAt: 10.0];
    NSTimeInterval d = [p delayBeforePaintAt: 10.005];
    PASS(d > 0.011 && d < 0.012,
         "damage within one frame is deferred to the end of the frame, not dropped");
    PASS([p delayBeforePaintAt: 10.0 + frame] == 0,
         "damage one frame later paints at once");
    [p notePresentationQueued];
    PASS(![p presentationPending],
         "without presentation feedback a queued frame never blocks painting");
    [p release];

    p = [[URSFramePacer alloc] initWithMinimumInterval: frame];
    [p notePaintAt: 20.0];
    NSTimeInterval burst[] = { 20.001, 20.003, 20.006, 20.009, 20.012 };
    PASS(paintsForDamage(p, burst, 5, 20.05) == 1,
         "five damage events within one frame yield exactly one deferred paint");
    [p release];
  }
  END_SET("clock paced (no presentation feedback)")

  START_SET("paced by presentation")
  {
    URSFramePacer *p = [[URSFramePacer alloc] initWithMinimumInterval: frame];
    p.pacedByPresentation = YES;
    PASS([p delayBeforePaintAt: 10.0] == 0, "an idle screen paints damage at once");
    [p notePaintAt: 10.0];
    [p notePresentationQueued];
    PASS([p presentationPending], "the presented frame is pending until shown");
    PASS([p delayBeforePaintAt: 10.004] == URSFramePacerWaitForPresentation,
         "damage while a frame waits for the screen waits for that frame");
    PASS([p delayBeforePaintAt: 10.030] == URSFramePacerWaitForPresentation,
         "no clock-driven paint is stacked on a frame that is still in flight");

    // The refresh of this display is slightly shorter than the clock's
    // frame: the next frame must be painted right away, or this refresh
    // would show the previous frame again.
    [p notePresentationCompleted];
    PASS(![p presentationPending], "a shown frame is no longer pending");
    PASS([p delayBeforePaintAt: 10.0 + 0.9 * frame] == 0,
         "the frame after a shown one paints at once, even within the clock's frame");

    [p notePaintAt: 10.02];
    [p notePresentationQueued];
    [p reset];
    PASS(![p presentationPending] && [p delayBeforePaintAt: 10.021] == 0,
         "replacing the presentation buffers forgets the frame in flight");
    [p release];
  }
  END_SET("paced by presentation")

  START_SET("a continuous scroll at 60.05 Hz refresh")
  {
    // A client damages every 4 ms; the display refreshes every 16.653 ms and
    // reports each shown frame at once.  Every refresh must get a new frame.
    URSFramePacer *p = [[URSFramePacer alloc] initWithMinimumInterval: frame];
    p.pacedByPresentation = YES;
    const NSTimeInterval refresh = 1.0 / 60.05;
    NSTimeInterval nextVblank = refresh;
    NSTimeInterval deferredAt = 0;
    int shown = 0, refreshes = 0, repeated = 0;
    BOOL damaged = NO, inFlight = NO;
    for (NSTimeInterval t = 0; t < 2.0; t += 0.001) {
      if (t >= nextVblank) {
        refreshes++;
        if (inFlight) {
          shown++;
          inFlight = NO;
          [p notePresentationCompleted];
        } else {
          repeated++;
        }
        nextVblank += refresh;
      }
      if (((int)(t * 1000.0 + 0.5)) % 4 == 0) {
        damaged = YES;
      }
      if (!damaged) {
        continue;
      }
      if (deferredAt > 0 && t < deferredAt) {
        continue;
      }
      NSTimeInterval d = [p delayBeforePaintAt: t];
      if (d == 0) {
        [p notePaintAt: t];
        [p notePresentationQueued];
        inFlight = YES;
        damaged = NO;
        deferredAt = 0;
      } else if (d > 0) {
        deferredAt = t + d;
      }
    }
    PASS(refreshes > 100, "the simulation covers %d refreshes", refreshes);
    PASS(repeated == 0,
         "no refresh repeats the previous frame during the scroll (%d of %d did)",
         repeated, refreshes);
    [p release];
  }
  END_SET("a continuous scroll at 60.05 Hz refresh")

  [arp release];
  return 0;
}
