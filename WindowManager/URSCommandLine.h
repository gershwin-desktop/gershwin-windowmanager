/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// What to do about a window manager that is already running.
typedef NS_ENUM(NSInteger, URSTakeoverAction) {
    URSTakeoverProceed,   // nothing in the way, or --replace was given
    URSTakeoverRefuse,    // report on the terminal and exit
    URSTakeoverAsk        // ask the user in a dialog
};

// What the command line asks of the window manager.  Kept apart from main()
// so the rules can be tested without starting an application.
@interface URSCommandLine : NSObject

// argv[0] is skipped; unknown arguments are left to GNUstep's own options.
+ (instancetype)commandLineWithArguments:(const char * const *)argv count:(int)argc;

// YES unless -dc / --disable-compositing was given.
@property (nonatomic, readonly) BOOL compositingEnabled;
// YES with --replace: take over from a window manager that is already running.
@property (nonatomic, readonly) BOOL replaceRequested;
// YES with -h / --help.
@property (nonatomic, readonly) BOOL helpRequested;

// Started from a terminal the user can simply pass --replace, so a refusal
// is enough; started from a launcher (double click) there is no terminal to
// read a message or pass options on, so the user is asked instead.
+ (URSTakeoverAction)takeoverActionWithReplaceRequested:(BOOL)replaceRequested
                                    otherManagerRunning:(BOOL)otherManagerRunning
                                           fromTerminal:(BOOL)fromTerminal;

@end
