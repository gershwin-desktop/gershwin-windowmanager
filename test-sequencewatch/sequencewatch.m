/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// The sequence watch must notice when the X server numbers packets beyond
// the requests libxcb counted, even when the lead is far smaller than half
// the 16-bit range, and its probe must measure the lead.
// Needs an X server: DISPLAY=:<n> gnustep-tests test-sequencewatch

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSSequenceWatch.m"
#include <unistd.h>
#include <string.h>

// Requests written to the socket behind libxcb's back: the server numbers
// them, libxcb does not.
static BOOL writeUncountedRequests(xcb_connection_t *c, unsigned count)
{
    xcb_flush(c);
    uint8_t noop[4] = { 127, 0, 1, 0 };
    for (unsigned i = 0; i < count; i++) {
        if (write(xcb_get_file_descriptor(c), noop, sizeof(noop)) != sizeof(noop)) {
            return NO;
        }
    }
    return YES;
}

// Feeds every packet that arrives within a short time to the watch.
static void drain(URSSequenceWatch *watch, xcb_connection_t *c,
                  BOOL *sawOverrun, BOOL *sawProbe)
{
    for (int round = 0; round < 50; round++) {
        xcb_generic_event_t *e;
        xcb_flush(c);
        while ((e = xcb_poll_for_event(c))) {
            URSSequenceWatchResult r = URSSequenceWatchPacket(watch, c, e);
            if (r == URSSequenceWatchOverrun) *sawOverrun = YES;
            if (r == URSSequenceWatchProbeAnswered) *sawProbe = YES;
            free(e);
        }
        usleep(10000);
    }
}

static void changeProperty(xcb_connection_t *c, xcb_window_t w)
{
    uint32_t v = 1;
    xcb_change_property(c, XCB_PROP_MODE_REPLACE, w, XCB_ATOM_WM_NAME,
                        XCB_ATOM_CARDINAL, 32, 1, &v);
}

int main(void)
{
    NSAutoreleasePool *pool = [NSAutoreleasePool new];

    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(c)) {
        NSLog(@"No X server; set DISPLAY to a private Xvfb");
        PASS(0, "an X server is reachable");
        [pool release];
        return 0;
    }
    xcb_screen_t *screen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    xcb_window_t w = xcb_generate_id(c);
    uint32_t mask = XCB_EVENT_MASK_PROPERTY_CHANGE;
    xcb_create_window(c, XCB_COPY_FROM_PARENT, w, screen->root, 0, 0, 10, 10, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual,
                      XCB_CW_EVENT_MASK, &mask);

    URSSequenceWatch watch;
    memset(&watch, 0, sizeof(watch));
    BOOL overrun = NO, probe = NO;

    START_SET("sequence watch")

    // In step: events never run ahead of the requests sent.
    for (int i = 0; i < 3; i++) {
        changeProperty(c, w);
        for (int k = 0; k < 600; k++) xcb_no_operation(c);
        drain(&watch, c, &overrun, &probe);
    }
    PASS(!overrun, "no overrun while libxcb and the server agree");

    // A lead of 1500 requests is far below half the 16-bit range, where a
    // check on big jumps alone sees nothing.
    PASS(writeUncountedRequests(c, 1500), "uncounted requests written");
    changeProperty(c, w);
    drain(&watch, c, &overrun, &probe);
    PASS(overrun, "an event numbered beyond the requests sent is reported");
    PASS(probe, "the probe request's error comes back");
    PASS(watch.probeDifference == 1500,
         "the probe measures the server's lead (%d)", watch.probeDifference);

    END_SET("sequence watch")

    xcb_disconnect(c);
    [pool release];
    return 0;
}
