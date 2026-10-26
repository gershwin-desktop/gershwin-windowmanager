/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCloseRequestPlan.h"

@implementation URSCloseRequestPlan

+ (URSCloseRequestAction)actionWithRequestPending:(BOOL)requestPending
                                       showsSheet:(BOOL)showsSheet
                              acceptsCloseRequest:(BOOL)acceptsCloseRequest
                                  hasCloseHandler:(BOOL)hasCloseHandler
{
    if (showsSheet) {
        return URSCloseRequestActionWaitForUser;
    }
    if (requestPending) {
        return URSCloseRequestActionOfferForceQuit;
    }
    // A client that takes the request decides itself, and may ask the user
    // first; a close handler is only for clients that cannot be asked.
    if (acceptsCloseRequest) {
        return URSCloseRequestActionAskClient;
    }
    if (hasCloseHandler) {
        return URSCloseRequestActionRunHandler;
    }
    return URSCloseRequestActionWatch;
}

+ (BOOL)offersForceQuitWithSheet:(BOOL)showsSheet frontmost:(BOOL)frontmost
{
    return !showsSheet && frontmost;
}

@end
