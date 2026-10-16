/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef URSConfigureRequestPolicy_h
#define URSConfigureRequestPolicy_h

#import <Foundation/Foundation.h>
#include <xcb/xproto.h>

// What a ConfigureRequest from a decorated client does to its frame.
// The client sits inside the frame, so a stacking request applied to the
// client only reorders it among the frame's own children (the titlebar)
// and never changes where the window is on the screen.
typedef enum {
    URSFrameStackNone = 0,
    // Raise the frame and re-assert the layers that stay above it (Dock,
    // menus, the application's floating panels).
    URSFrameStackRaise,
    // Lower the frame beneath the other ordinary windows, but not beneath
    // the desktop.
    URSFrameStackLowerAmongPeers,
    // A desktop window always goes back to the very bottom.
    URSFrameStackToBottom,
    // Hand the stack mode (and the sibling, translated to its frame) to
    // the frame; the X server then evaluates it among the root's children.
    URSFrameStackRelative
} URSFrameStackAction;

typedef struct {
    uint16_t valueMask;
    uint8_t stackMode;
    BOOL isDesktop;
    // _NET_WM_STATE_BELOW: the window asked to stay below the others.
    BOOL keepBelow;
    // Min == max in WM_NORMAL_HINTS.  Only refuses resizing by the user;
    // ICCCM lets a client resize its own window regardless of its hints.
    BOOL fixedSize;
} URSConfigureRequestInput;

typedef struct {
    // Bits of the request that go to the client window itself: only its
    // size, never a stack mode or sibling.
    uint16_t clientValueMask;
    URSFrameStackAction stackAction;
} URSConfigureRequestDecision;

URSConfigureRequestDecision URSDecideConfigureRequest(URSConfigureRequestInput input);

#endif
