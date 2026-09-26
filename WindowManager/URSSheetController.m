/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetController.h"
#import "URSSheetLayout.h"
#import "URSWindowRole.h"

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
