/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which process a newly registered window manager may terminate.  Headless.
// Run with:  gnustep-tests test-previouswm

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSPreviousWindowManager.m"

static NSString *const ownExe = @"/System/Library/CoreServices/Applications/WindowManager.app/WindowManager";

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  // Two WindowManagers of the same user: pid 100 manages another display,
  // pid 300 is the one that owned WM_S0 on our own display.
  NSDictionary *processes = @{ @100: ownExe, @300: ownExe, @400: @"/usr/bin/twm" };
  NSString *(^exe)(pid_t) = ^NSString *(pid_t pid) { return processes[@(pid)]; };

  PASS(URSPreviousWindowManagerToTerminate(300, 200, ownExe, exe) == 300,
       "the same program that owned the selection on our display is terminated");
  PASS(URSPreviousWindowManagerToTerminate(0, 200, ownExe, exe) == 0,
       "no selection owner on our display: the WindowManager on another display is left alone");
  PASS(URSPreviousWindowManagerToTerminate(200, 200, ownExe, exe) == 0,
       "we never terminate ourselves");
  PASS(URSPreviousWindowManagerToTerminate(400, 200, ownExe, exe) == 0,
       "a different window manager is left to quit on SelectionClear");
  PASS(URSPreviousWindowManagerToTerminate(500, 200, ownExe, exe) == 0,
       "a process that is gone or unreadable is not signalled");
  PASS(URSPreviousWindowManagerToTerminate(300, 200, nil, exe) == 0,
       "without our own executable nothing can be matched");

  NSString *mine = URSExecutablePathForProcess(getpid());
  PASS(mine != nil && [mine hasSuffix: @"previouswm"],
       "the executable of a live process is found");

  [arp release];
  return 0;
}
