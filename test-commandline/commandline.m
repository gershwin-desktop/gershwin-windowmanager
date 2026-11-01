/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// What the command line asks of the window manager.  Headless.
// Run with:  gnustep-tests test-commandline

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSCommandLine.m"

static URSCommandLine *parse(const char *a1, const char *a2)
{
  const char *argv[] = { "WindowManager", a1, a2, NULL };
  int argc = a2 ? 3 : (a1 ? 2 : 1);
  return [URSCommandLine commandLineWithArguments: argv count: argc];
}

int main(int argc, char **argv)
{
  START_SET("URSCommandLine")
    URSCommandLine *plain = parse(NULL, NULL);
    PASS(plain.compositingEnabled, "compositing is on by default");
    PASS(!plain.replaceRequested, "an existing window manager is not replaced by default");
    PASS(!plain.helpRequested, "no help by default");

    PASS(parse("--replace", NULL).replaceRequested, "--replace asks to replace");
    PASS(parse("--replace", NULL).compositingEnabled, "--replace leaves compositing on");
    PASS(!parse("-dc", NULL).compositingEnabled, "-dc turns compositing off");
    PASS(!parse("--disable-compositing", NULL).compositingEnabled, "long form turns compositing off");

    URSCommandLine *both = parse("-dc", "--replace");
    PASS(!both.compositingEnabled && both.replaceRequested,
         "-dc before --replace keeps both");
    PASS(parse("--help", NULL).helpRequested, "--help asks for help");
    PASS(!parse("-replace", NULL).replaceRequested, "only the double-dash spelling counts");
  END_SET("URSCommandLine")

  START_SET("takeover")
    PASS([URSCommandLine takeoverActionWithReplaceRequested: NO otherManagerRunning: NO fromTerminal: NO]
         == URSTakeoverProceed, "a free screen is taken without asking");
    PASS([URSCommandLine takeoverActionWithReplaceRequested: NO otherManagerRunning: YES fromTerminal: YES]
         == URSTakeoverRefuse, "from a terminal a running manager is not replaced unasked");
    PASS([URSCommandLine takeoverActionWithReplaceRequested: NO otherManagerRunning: YES fromTerminal: NO]
         == URSTakeoverAsk, "from a launcher the user is asked");
    PASS([URSCommandLine takeoverActionWithReplaceRequested: YES otherManagerRunning: YES fromTerminal: NO]
         == URSTakeoverProceed, "--replace needs no question");
  END_SET("takeover")
  return 0;
}
