/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSConfigureRequestPolicy.h"

URSConfigureRequestDecision URSDecideConfigureRequest(URSConfigureRequestInput input)
{
    URSConfigureRequestDecision d;
    memset(&d, 0, sizeof(d));

    // fixedSize is deliberately not consulted: it comes from the client's
    // own hints, and a client that changes its size breaks no promise.
    d.clientValueMask = input.valueMask & (XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT);

    // The protocol rejects a sibling without a stack mode, so it is not a
    // stacking request at all.
    if (!(input.valueMask & XCB_CONFIG_WINDOW_STACK_MODE))
        return d;

    if (input.isDesktop)
    {
        d.stackAction = URSFrameStackToBottom;
        return d;
    }

    uint8_t mode = input.stackMode;
    BOOL lifts = (mode == XCB_STACK_MODE_ABOVE ||
                  mode == XCB_STACK_MODE_TOP_IF ||
                  mode == XCB_STACK_MODE_OPPOSITE);
    if (input.keepBelow && lifts)
        return d;

    if (input.valueMask & XCB_CONFIG_WINDOW_SIBLING)
        d.stackAction = URSFrameStackRelative;
    else if (mode == XCB_STACK_MODE_ABOVE)
        d.stackAction = URSFrameStackRaise;
    else if (mode == XCB_STACK_MODE_BELOW)
        d.stackAction = URSFrameStackLowerAmongPeers;
    else
        d.stackAction = URSFrameStackRelative;

    return d;
}
