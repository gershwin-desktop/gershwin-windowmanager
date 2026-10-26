/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// -[XCBWindow configureForEvent:] handed a decorated client's STACK_MODE
// and SIBLING to the client window inside its frame, so a raise request
// (xdotool windowraise, libs-gui's orderFrontRegardless from
// -makeKeyAndOrderFront:) only reordered the client below its own
// titlebar and the window stayed buried.  It also dropped the size of a
// fixed-size window's own resize request, although ICCCM lets a client
// resize itself; Workspace's Find window could not grow when criteria
// were added.  Headless.
// Run with:  gnustep-tests test-configurerequest

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSConfigureRequestPolicy.m"

static URSConfigureRequestInput request(uint16_t mask, uint8_t mode)
{
  URSConfigureRequestInput in;
  memset(&in, 0, sizeof(in));
  in.valueMask = mask;
  in.stackMode = mode;
  return in;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  const uint16_t stackBits = XCB_CONFIG_WINDOW_STACK_MODE | XCB_CONFIG_WINDOW_SIBLING;
  const uint16_t sizeBits = XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT;
  URSConfigureRequestDecision d;
  URSConfigureRequestInput in;

  /* --- raise without a sibling (xdotool windowraise, orderFrontRegardless) --- */
  d = URSDecideConfigureRequest(request(XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_ABOVE));
  PASS(d.stackAction == URSFrameStackRaise, "Above without a sibling raises the frame");
  PASS((d.clientValueMask & stackBits) == 0, "the stack mode is not applied to the client inside the frame");

  /* --- lower without a sibling --- */
  d = URSDecideConfigureRequest(request(XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_BELOW));
  PASS(d.stackAction == URSFrameStackLowerAmongPeers, "Below lowers the frame among ordinary windows");
  PASS((d.clientValueMask & stackBits) == 0, "Below is not applied to the client either");

  /* --- relative to a sibling --- */
  d = URSDecideConfigureRequest(request(stackBits, XCB_STACK_MODE_ABOVE));
  PASS(d.stackAction == URSFrameStackRelative, "Above a sibling restacks the frame relative to the sibling's frame");
  PASS((d.clientValueMask & stackBits) == 0, "neither sibling nor stack mode reach the client");

  d = URSDecideConfigureRequest(request(XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_TOP_IF));
  PASS(d.stackAction == URSFrameStackRelative, "TopIf is evaluated by the server for the frame");

  /* --- a sibling without a stack mode is not a stacking request --- */
  d = URSDecideConfigureRequest(request(XCB_CONFIG_WINDOW_SIBLING, 0));
  PASS(d.stackAction == URSFrameStackNone, "a sibling alone does not restack");

  /* --- no stacking at all --- */
  d = URSDecideConfigureRequest(request(XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, 0));
  PASS(d.stackAction == URSFrameStackNone && d.clientValueMask == 0, "a plain move restacks nothing");

  /* --- the desktop stays at the bottom --- */
  in = request(XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_ABOVE);
  in.isDesktop = YES;
  d = URSDecideConfigureRequest(in);
  PASS(d.stackAction == URSFrameStackToBottom, "a desktop window asking to be raised goes back to the bottom");

  /* --- keep-below is not undone by the client --- */
  in = request(XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_ABOVE);
  in.keepBelow = YES;
  d = URSDecideConfigureRequest(in);
  PASS(d.stackAction == URSFrameStackNone, "a keep-below window is not raised by its own request");
  in.stackMode = XCB_STACK_MODE_BELOW;
  d = URSDecideConfigureRequest(in);
  PASS(d.stackAction == URSFrameStackLowerAmongPeers, "a keep-below window may still lower itself");

  /* --- the client's own size request --- */
  in = request(sizeBits, 0);
  in.fixedSize = YES;
  d = URSDecideConfigureRequest(in);
  PASS(d.clientValueMask == sizeBits, "a fixed-size window gets the size it asks for itself");

  in.fixedSize = NO;
  d = URSDecideConfigureRequest(in);
  PASS(d.clientValueMask == sizeBits, "a resizable window gets its size too");

  in = request(XCB_CONFIG_WINDOW_HEIGHT | XCB_CONFIG_WINDOW_STACK_MODE, XCB_STACK_MODE_ABOVE);
  in.fixedSize = YES;
  d = URSDecideConfigureRequest(in);
  PASS(d.clientValueMask == XCB_CONFIG_WINDOW_HEIGHT, "only the requested dimension changes");
  PASS(d.stackAction == URSFrameStackRaise, "a combined resize and raise still raises the frame");

  [arp release];
  return 0;
}
