/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSDrawerController.h"
#import "URSDrawerLayout.h"
#import "URSWindowRole.h"

@implementation URSDrawerController
{
    // Drawer -> URSDrawerAttachment, read off its rect when it was shown.
    NSMutableDictionary<NSNumber *, NSValue *> *_attachments;
}

- (instancetype)initWithConnection:(XCBConnection *)connection
{
    self = [super initWithConnection:connection];
    if (self) {
        _attachments = [NSMutableDictionary new];
    }
    return self;
}

- (NSString *)role
{
    return URSWindowRoleDrawer;
}

- (BOOL)stacksAboveParent
{
    return NO;
}

- (BOOL)getAttachment:(URSDrawerAttachment *)attachment ofWindow:(xcb_window_t)window
{
    NSValue *value = _attachments[@(window)];
    if (value == nil) {
        return NO;
    }
    [value getValue:attachment];
    return YES;
}

- (URSAttachmentEdge)slideEdgeOfWindow:(xcb_window_t)window
{
    URSDrawerAttachment a;
    return [self getAttachment:&a ofWindow:window] ? a.edge : URSAttachmentEdgeRight;
}

// The client computes the drawer's rect from its parent's frame when it is
// opened, so that is when the edge and offsets are read.  Later requests
// are computed from whatever the client last heard of a parent the window
// manager may be moving, so they are not trusted for the position.
- (BOOL)prepareAttachmentOfWindow:(xcb_window_t)window
                             rect:(NSRect)rect
                      parentFrame:(NSRect)parentFrame
                    parentContent:(NSRect)parentContent
{
    URSDrawerAttachment a;
    if (![URSDrawerLayout getAttachment:&a ofDrawerRect:rect
                            parentFrame:parentFrame parentContent:parentContent]) {
        NSLog(@"[Drawers] Window %u at %@ lies over its parent %@; shown as an ordinary window",
              window, NSStringFromRect(rect), NSStringFromRect(parentFrame));
        return NO;
    }
    _attachments[@(window)] = [NSValue valueWithBytes:&a objCType:@encode(URSDrawerAttachment)];
    return YES;
}

// Only how far it sticks out is the client's to change (its content size);
// its length follows the parent.
- (NSSize)sizeOfWindow:(xcb_window_t)window
            forRequest:(xcb_configure_request_event_t *)event
           currentSize:(NSSize)size
{
    URSDrawerAttachment a;
    if (![self getAttachment:&a ofWindow:window]) {
        return size;
    }
    BOOL sideways = a.edge == URSAttachmentEdgeLeft || a.edge == URSAttachmentEdgeRight;
    if (sideways && (event->value_mask & XCB_CONFIG_WINDOW_WIDTH)) {
        a.thickness = event->width;
        size.width = event->width;
    } else if (!sideways && (event->value_mask & XCB_CONFIG_WINDOW_HEIGHT)) {
        a.thickness = event->height;
        size.height = event->height;
    }
    _attachments[@(window)] = [NSValue valueWithBytes:&a objCType:@encode(URSDrawerAttachment)];
    return size;
}

- (NSRect)rectForWindow:(xcb_window_t)window
                   size:(NSSize)size
            parentFrame:(NSRect)parentFrame
          parentContent:(NSRect)parentContent
                 screen:(NSRect)screen
{
    URSDrawerAttachment a;
    if (![self getAttachment:&a ofWindow:window]) {
        return NSZeroRect;
    }
    return [URSDrawerLayout frameForAttachment:a parentFrame:parentFrame
                                 parentContent:parentContent];
}

- (void)forgetAttachmentOfWindow:(xcb_window_t)window
{
    [_attachments removeObjectForKey:@(window)];
}

@end
