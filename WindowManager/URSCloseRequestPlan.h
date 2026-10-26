/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// What asking a client window to close does (its titlebar close button,
// the titlebar menu's Close, the close shortcut).
typedef NS_ENUM(NSInteger, URSCloseRequestAction) {
    // Send WM_DELETE_WINDOW and watch whether the window goes.
    URSCloseRequestActionAskClient,
    // The client cannot be asked (an orphaned flip side from a Terminal
    // that does not take WM_DELETE_WINDOW): the window manager ends it.
    URSCloseRequestActionRunHandler,
    // Nothing can ask it; only watch whether it goes, so force quit is
    // offered if it does not.
    URSCloseRequestActionWatch,
    // Asked before and still there: offer force quit at once.
    URSCloseRequestActionOfferForceQuit,
    // The window shows a sheet: the client is asking the user (whether to
    // close, typically), so neither asking again nor force quit makes sense.
    URSCloseRequestActionWaitForUser,
};

@interface URSCloseRequestPlan : NSObject

+ (URSCloseRequestAction)actionWithRequestPending:(BOOL)requestPending
                                       showsSheet:(BOOL)showsSheet
                              acceptsCloseRequest:(BOOL)acceptsCloseRequest
                                  hasCloseHandler:(BOOL)hasCloseHandler;

// When the watch on an unanswered request runs out.  The window carries no
// _NET_WM_PING answer to go by (the window manager does not ping), so a
// sheet is what shows the client is alive and waiting for the user.
+ (BOOL)offersForceQuitWithSheet:(BOOL)showsSheet frontmost:(BOOL)frontmost;

@end
