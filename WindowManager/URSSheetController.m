/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetController.h"
#import "URSSheetLayout.h"
#import "URSWindowRole.h"
#import "XCBConnection.h"
#import "XCBWindow.h"

@implementation URSSheetController

- (NSString *)role
{
    return URSWindowRoleSheet;
}

// The sheet is what the user answers now.
- (BOOL)focusesOnMap
{
    return YES;
}

- (BOOL)attachesExclusively
{
    return YES;
}

- (BOOL)stacksAboveParent
{
    return YES;
}

// The parent does not take input while its sheet is up.
- (BOOL)takesParentFocus
{
    return YES;
}

// A sheet that comes up after a close request is the client answering it,
// typically asking the user whether to close: the watch that would offer
// force quit ends, so a second close after Cancel asks again instead.
- (void)willShowAttachedWindow:(xcb_window_t)window parent:(xcb_window_t)parent
{
    xcb_window_t named = [self namedParentOfWindow:window];
    [[self.connection windowForXCBId:named != XCB_NONE ? named : parent] cancelCloseTimer];
}

- (URSAttachmentEdge)slideEdgeOfWindow:(xcb_window_t)window
{
    return URSAttachmentEdgeBottom;
}

- (NSSize)sizeOfWindow:(xcb_window_t)window
            forRequest:(xcb_configure_request_event_t *)event
           currentSize:(NSSize)size
{
    if (event->value_mask & XCB_CONFIG_WINDOW_WIDTH) {
        size.width = event->width;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_HEIGHT) {
        size.height = event->height;
    }
    return size;
}

- (NSRect)rectForWindow:(xcb_window_t)window
                   size:(NSSize)size
            parentFrame:(NSRect)parentFrame
          parentContent:(NSRect)parentContent
                 screen:(NSRect)screen
{
    return [URSSheetLayout frameForSheetSize:size
                           parentContentRect:parentContent
                                  screenRect:screen];
}

@end
