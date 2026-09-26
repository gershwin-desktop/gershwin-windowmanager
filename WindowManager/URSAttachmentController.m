/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentController.h"
#import "URSAttachmentRegistry.h"
#import "URSWindowRole.h"
#import "URSCompositingManager.h"
#import "URSShapePath.h"
#import "XCBAtomService.h"
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "XCBScreen.h"

@implementation URSAttachmentController
{
    XCBConnection *_connection;
    xcb_atom_t _roleAtom;
    URSAttachmentRegistry *_registry;
    // Parent client -> where its client window sits in its frame (left,
    // top, right, bottom insets in an NSRect), measured on the last
    // placement, so that following a dragged frame needs no round trip.
    NSMutableDictionary<NSNumber *, NSValue *> *_contentInsets;
    // Attached window -> the rect it was last given.  XCBKit does not track
    // ConfigureNotify for windows it has not framed, so this is the only
    // record that needs no round trip.
    NSMutableDictionary<NSNumber *, NSValue *> *_placedRects;
}

- (instancetype)initWithConnection:(XCBConnection *)connection
{
    self = [super init];
    if (self) {
        _connection = connection;
        _registry = [URSAttachmentRegistry new];
        _contentInsets = [NSMutableDictionary new];
        _placedRects = [NSMutableDictionary new];
        const char *name = [URSWindowRolePropertyName UTF8String];
        xcb_connection_t *c = [connection connection];
        xcb_intern_atom_reply_t *reply =
            xcb_intern_atom_reply(c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
        _roleAtom = reply ? reply->atom : XCB_NONE;
        free(reply);
        if (_roleAtom == XCB_NONE) {
            NSLog(@"[Attachments] Cannot intern %@; %@ windows are shown as ordinary windows",
                  URSWindowRolePropertyName, [self role]);
        }
    }
    return self;
}

- (URSAttachmentRegistry *)registry
{
    return _registry;
}

#pragma mark - What subclasses decide

- (NSString *)role
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (BOOL)focusesOnMap
{
    return NO;
}

- (BOOL)attachesExclusively
{
    return NO;
}

- (BOOL)stacksAboveParent
{
    return YES;
}

- (BOOL)takesParentFocus
{
    return NO;
}

- (URSAttachmentEdge)slideEdgeOfWindow:(xcb_window_t)window
{
    return URSAttachmentEdgeBottom;
}

- (BOOL)prepareAttachmentOfWindow:(xcb_window_t)window
                             rect:(NSRect)rect
                      parentFrame:(NSRect)parentFrame
                    parentContent:(NSRect)parentContent
{
    return YES;
}

- (NSSize)sizeOfWindow:(xcb_window_t)window
            forRequest:(xcb_configure_request_event_t *)event
           currentSize:(NSSize)size
{
    return size;
}

- (NSRect)rectForWindow:(xcb_window_t)window
                   size:(NSSize)size
            parentFrame:(NSRect)parentFrame
          parentContent:(NSRect)parentContent
                 screen:(NSRect)screen
{
    [self doesNotRecognizeSelector:_cmd];
    return NSZeroRect;
}

- (void)forgetAttachmentOfWindow:(xcb_window_t)window
{
}

#pragma mark - Recognising an attached window

// The window it hangs from, or XCB_NONE: both the role and
// WM_TRANSIENT_FOR must be there, since the role alone does not say whose
// window it is and WM_TRANSIENT_FOR alone is any dialog or child window.
- (xcb_window_t)markedParentOfWindow:(xcb_window_t)window
{
    if (_roleAtom == XCB_NONE) {
        return XCB_NONE;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_get_property_cookie_t markCookie =
        xcb_get_property(c, 0, window, _roleAtom, XCB_ATOM_STRING, 0, 16);
    xcb_get_property_cookie_t transientCookie =
        xcb_get_property(c, 0, window, XCB_ATOM_WM_TRANSIENT_FOR, XCB_ATOM_WINDOW, 0, 1);
    xcb_get_property_reply_t *mark = xcb_get_property_reply(c, markCookie, NULL);
    xcb_get_property_reply_t *transient = xcb_get_property_reply(c, transientCookie, NULL);

    xcb_window_t parent = XCB_NONE;
    NSString *role = mark ? [URSWindowRole roleFromPropertyBytes:xcb_get_property_value(mark)
                                                          length:xcb_get_property_value_length(mark)]
                          : nil;
    if ([role isEqualToString:[self role]] &&
        transient && xcb_get_property_value_length(transient) >= 4) {
        parent = *(xcb_window_t *)xcb_get_property_value(transient);
    }
    free(mark);
    free(transient);
    return parent;
}

- (XCBFrame *)frameOfClient:(xcb_window_t)client
{
    XCBWindow *window = [_connection windowForXCBId:client];
    XCBWindow *frame = [window parentWindow];
    return [frame isKindOfClass:[XCBFrame class]] ? (XCBFrame *)frame : nil;
}

- (NSRect)screenRect
{
    XCBScreen *screen = [[_connection screens] firstObject];
    return NSMakeRect(0, 0, [screen width], [screen height]);
}

#pragma mark - Placement

// Where the parent's frame and client are now, asked from the server, and
// the window's own rect.  NO when any of them is gone.
- (BOOL)getParentFrame:(NSRect *)parentFrame
         parentContent:(NSRect *)parentContent
            windowRect:(NSRect *)windowRect
             forWindow:(xcb_window_t)window
                parent:(xcb_window_t)parent
{
    XCBFrame *frame = [self frameOfClient:parent];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!frame || !screen) {
        return NO;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_window_t root = [[screen rootWindow] window];
    xcb_translate_coordinates_cookie_t originCookie =
        xcb_translate_coordinates(c, parent, root, 0, 0);
    xcb_get_geometry_cookie_t parentCookie = xcb_get_geometry(c, parent);
    xcb_get_geometry_cookie_t frameCookie = xcb_get_geometry(c, [frame window]);
    xcb_get_geometry_cookie_t windowCookie = xcb_get_geometry(c, window);
    xcb_translate_coordinates_reply_t *origin =
        xcb_translate_coordinates_reply(c, originCookie, NULL);
    xcb_get_geometry_reply_t *parentGeometry = xcb_get_geometry_reply(c, parentCookie, NULL);
    xcb_get_geometry_reply_t *frameGeometry = xcb_get_geometry_reply(c, frameCookie, NULL);
    xcb_get_geometry_reply_t *windowGeometry = xcb_get_geometry_reply(c, windowCookie, NULL);

    BOOL ok = origin && parentGeometry && frameGeometry && windowGeometry;
    if (ok) {
        // The client's own rect, not the frame's: an attached window keeps
        // clear of the titlebar, whatever height the theme gives it.
        *parentContent = NSMakeRect(origin->dst_x, origin->dst_y,
                                    parentGeometry->width, parentGeometry->height);
        *parentFrame = NSMakeRect(frameGeometry->x, frameGeometry->y,
                                  frameGeometry->width + 2 * frameGeometry->border_width,
                                  frameGeometry->height + 2 * frameGeometry->border_width);
        // Unmapped top-level windows are children of the root, so this is
        // where the client put the window.
        *windowRect = NSMakeRect(windowGeometry->x, windowGeometry->y,
                                 windowGeometry->width, windowGeometry->height);
        _contentInsets[@(parent)] = [NSValue valueWithRect:
            NSMakeRect(NSMinX(*parentContent) - NSMinX(*parentFrame),
                       NSMinY(*parentContent) - NSMinY(*parentFrame),
                       NSMaxX(*parentFrame) - NSMaxX(*parentContent),
                       NSMaxY(*parentFrame) - NSMaxY(*parentContent))];
    }
    free(origin);
    free(parentGeometry);
    free(frameGeometry);
    free(windowGeometry);
    return ok;
}

- (void)configureWindow:(xcb_window_t)window
                 toRect:(NSRect)r
            currentSize:(NSSize)current
            parentFrame:(xcb_window_t)frameWindow
{
    uint16_t mask = XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y;
    uint32_t values[7];
    int n = 0;
    values[n++] = (uint32_t)(int32_t)NSMinX(r);
    values[n++] = (uint32_t)(int32_t)NSMinY(r);
    BOOL resized = !NSEqualSizes(r.size, current);
    if (resized) {
        mask |= XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT;
        values[n++] = (uint32_t)MAX(1.0, NSWidth(r));
        values[n++] = (uint32_t)MAX(1.0, NSHeight(r));
    }
    mask |= XCB_CONFIG_WINDOW_BORDER_WIDTH | XCB_CONFIG_WINDOW_SIBLING |
            XCB_CONFIG_WINDOW_STACK_MODE;
    values[n++] = 0;
    values[n++] = frameWindow;
    values[n++] = [self stacksAboveParent] ? XCB_STACK_MODE_ABOVE : XCB_STACK_MODE_BELOW;
    xcb_configure_window([_connection connection], window, mask, values);
    _placedRects[@(window)] = [NSValue valueWithRect:r];
}

- (void)placeWindow:(xcb_window_t)window
{
    xcb_window_t parent = [_registry parentOfWindow:window];
    XCBFrame *frame = [self frameOfClient:parent];
    NSRect parentFrame, parentContent, current;
    if (!frame || ![self getParentFrame:&parentFrame parentContent:&parentContent
                             windowRect:&current forWindow:window parent:parent]) {
        return;
    }
    NSRect r = [self rectForWindow:window size:current.size parentFrame:parentFrame
                     parentContent:parentContent screen:[self screenRect]];
    if (NSIsEmptyRect(r)) {
        return;
    }
    [self configureWindow:window toRect:r currentSize:current.size parentFrame:[frame window]];
    [_connection flush];
}

- (void)followFrame:(XCBFrame *)frame
{
    NSArray<NSNumber *> *attached = [self attachedWindowsOfWindow:[frame window]];
    if ([attached count] == 0) {
        return;
    }
    XCBRect f = [frame windowRect];
    NSRect parentFrame = NSMakeRect(f.position.x, f.position.y, f.size.width, f.size.height);
    BOOL composited = [self.compositingManager compositingActive];
    for (NSNumber *number in attached) {
        xcb_window_t window = [number unsignedIntValue];
        xcb_window_t parent = [_registry parentOfWindow:window];
        NSValue *insets = _contentInsets[@(parent)];
        NSValue *placed = _placedRects[number];
        if (insets == nil || placed == nil || [_registry isWindowHiddenWithParent:window]) {
            continue;
        }
        NSRect i = [insets rectValue];
        NSRect parentContent = NSMakeRect(NSMinX(parentFrame) + NSMinX(i),
                                          NSMinY(parentFrame) + NSMinY(i),
                                          NSWidth(parentFrame) - NSMinX(i) - NSWidth(i),
                                          NSHeight(parentFrame) - NSMinY(i) - NSHeight(i));
        NSSize current = [placed rectValue].size;
        NSRect r = [self rectForWindow:window size:current parentFrame:parentFrame
                         parentContent:parentContent screen:[self screenRect]];
        if (NSIsEmptyRect(r)) {
            continue;
        }
        [self configureWindow:window toRect:r currentSize:current parentFrame:[frame window]];
        // The compositor would otherwise learn of the move only from the
        // ConfigureNotify a round trip later and paint one frame behind.  A
        // new size is left to that ConfigureNotify: told early, the
        // compositor keeps the picture of the old size and never paints the
        // part the window grew by.
        if (composited && NSEqualSizes(r.size, current)) {
            [self.compositingManager moveWindow:window x:NSMinX(r) y:NSMinY(r)];
        }
    }
    [_connection flush];
}

#pragma mark - Showing an attached window

// An attached window is not framed, so the frame's handling of the
// _WM_SHAPE_PATH outline does not reach it; the compositor is given the
// outline directly (a drawer's rounded outer corners).  The client sets it
// before mapping.
- (void)applyOutlineOfWindow:(xcb_window_t)window
{
    if (![self.compositingManager compositingActive]) {
        return;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_atom_t atom = [[XCBAtomService sharedInstanceWithConnection:_connection]
                          cacheAtom:@"_WM_SHAPE_PATH"];
    xcb_get_property_reply_t *reply =
        xcb_get_property_reply(c, xcb_get_property(c, 0, window, atom, XCB_ATOM_INTEGER, 0, 65536),
                               NULL);
    URSShapePath *path = nil;
    if (reply && reply->type == XCB_ATOM_INTEGER && reply->format == 32) {
        path = [URSShapePath shapePathWithValues:(const int32_t *)xcb_get_property_value(reply)
                                           count:(NSUInteger)xcb_get_property_value_length(reply) / 4];
    }
    free(reply);
    [self.compositingManager setShapePath:path clientOriginX:0 y:0 forWindow:window];
}

// Registers, places and maps a window that hangs from a decorated window;
// the caller has made sure it is one.
- (void)attachWindow:(xcb_window_t)window
            toParent:(xcb_window_t)parent
      mapStackParent:(xcb_window_t)stackParent
{
    XCBWindow *attached = [_connection windowForXCBId:window];
    if (attached == nil) {
        attached = [[XCBWindow alloc] initWithXCBWindow:window andConnection:_connection];
        [attached updateAttributes];
        [attached setParentWindow:[[XCBWindow alloc] initWithXCBWindow:stackParent
                                                         andConnection:_connection]];
        [_connection registerWindow:attached];
        // Like other undecorated windows: a click on it must give it the
        // focus back after the user clicked elsewhere.
        [attached grabButton];
        // Its FocusIn is what draws the parent's titlebar active.
        uint32_t mask = XCB_EVENT_MASK_FOCUS_CHANGE;
        xcb_change_window_attributes([_connection connection], window,
                                     XCB_CW_EVENT_MASK, &mask);
    }
    [attached setDecorated:NO];
    [attached updatePid];

    [_registry attachWindow:window toParent:parent exclusive:[self attachesExclusively]];
    [self applyOutlineOfWindow:window];
    [self placeWindow:window];
    [_connection mapWindow:attached];
    [attached setNormalState];
    [_connection flush];
}

// The parent it can hang from, or XCB_NONE when the window is not of this
// kind or has nothing to hang from (an undecorated or unknown parent) and
// so is shown as an ordinary window.
- (xcb_window_t)attachableParentOfWindow:(xcb_window_t)window
{
    xcb_window_t parent = [self markedParentOfWindow:window];
    if (parent == XCB_NONE || [self frameOfClient:parent] == nil) {
        return XCB_NONE;
    }
    if ([[[_connection windowForXCBId:window] parentWindow] isKindOfClass:[XCBFrame class]]) {
        // Still framed from being shown as an ordinary window before.
        return XCB_NONE;
    }
    NSRect parentFrame, parentContent, rect;
    if (![self getParentFrame:&parentFrame parentContent:&parentContent
                   windowRect:&rect forWindow:window parent:parent] ||
        ![self prepareAttachmentOfWindow:window rect:rect parentFrame:parentFrame
                           parentContent:parentContent]) {
        return XCB_NONE;
    }
    return parent;
}

- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event
{
    xcb_window_t parent = [self attachableParentOfWindow:event->window];
    if (parent == XCB_NONE) {
        return NO;
    }
    [self attachWindow:event->window toParent:parent mapStackParent:event->parent];
    return YES;
}

- (BOOL)isAttachedKind:(xcb_window_t)window
{
    return [self markedParentOfWindow:window] != XCB_NONE;
}

- (BOOL)adoptMappedWindow:(xcb_window_t)window
{
    xcb_window_t parent = [self attachableParentOfWindow:window];
    if (parent == XCB_NONE) {
        return NO;
    }
    XCBScreen *screen = [[_connection screens] firstObject];
    [self attachWindow:window toParent:parent mapStackParent:[[screen rootWindow] window]];
    // No MapNotify follows for a window that is mapped already, and the
    // slide-out after its unmap needs the picture kept.
    if ([self.compositingManager compositingActive]) {
        [self.compositingManager setKeepsContentAfterUnmap:YES forWindow:window];
    }
    return YES;
}

- (BOOL)handleConfigureRequest:(xcb_configure_request_event_t *)event
{
    if ([_registry parentOfWindow:event->window] == XCB_NONE) {
        return NO;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_get_geometry_reply_t *g =
        xcb_get_geometry_reply(c, xcb_get_geometry(c, event->window), NULL);
    if (g == NULL) {
        return YES;
    }
    NSSize current = NSMakeSize(g->width, g->height);
    free(g);
    NSSize size = [self sizeOfWindow:event->window forRequest:event currentSize:current];
    if (!NSEqualSizes(size, current)) {
        uint32_t values[2] = { (uint32_t)MAX(1.0, size.width), (uint32_t)MAX(1.0, size.height) };
        xcb_configure_window(c, event->window,
                             XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);
    }
    // Placed again, whatever the client asked for: a sheet that grows stays
    // centred, a drawer stays against its edge and next to its parent in
    // the stacking order.
    [self placeWindow:event->window];
    return YES;
}

#pragma mark - Following the parent

- (xcb_window_t)parentOfWindow:(xcb_window_t)window
{
    return [_registry parentOfWindow:window];
}

// Given as its client or its frame.
- (NSArray<NSNumber *> *)attachedWindowsOfWindow:(xcb_window_t)window
{
    NSArray<NSNumber *> *attached = [_registry windowsOfParent:window];
    return [attached count] > 0 ? attached : [self attachedWindowsOfFrame:window];
}

// Only the frame says whether the parent is shown: its client is also
// unmapped and mapped again when it is reparented into a new frame (every
// window the window manager adopts when it starts), which must not hide
// the attached windows.
- (NSArray<NSNumber *> *)attachedWindowsOfFrame:(xcb_window_t)window
{
    NSMutableArray<NSNumber *> *found = [NSMutableArray array];
    for (NSNumber *candidate in [_registry windows]) {
        XCBFrame *frame = [self frameOfClient:[_registry parentOfWindow:[candidate unsignedIntValue]]];
        if (frame && [frame window] == window) {
            [found addObject:candidate];
        }
    }
    return found;
}

- (BOOL)passFocusToAttachedWindowOfWindow:(xcb_window_t)window
{
    if (![self takesParentFocus]) {
        return NO;
    }
    xcb_window_t attached = [[[self attachedWindowsOfWindow:window] firstObject] unsignedIntValue];
    if (attached == XCB_NONE || [_registry isWindowHiddenWithParent:attached]) {
        return NO;
    }
    [[_connection windowForXCBId:attached] focus];
    [_connection flush];
    return YES;
}

- (void)windowMapped:(xcb_window_t)window
{
    if ([_registry isWindowHiddenWithParent:window]) {
        // Back with its restored parent: no slide, it was never dismissed.
        [_registry setWindow:window hiddenWithParent:NO];
        // The restored parent may have been focused before the attached
        // window was back; that focus is the attached window's.
        xcb_connection_t *c = [_connection connection];
        xcb_get_input_focus_reply_t *focus =
            xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL);
        xcb_window_t focused = focus ? focus->focus : XCB_NONE;
        free(focus);
        if (focused != XCB_NONE &&
            [[self attachedWindowsOfWindow:focused] containsObject:@(window)]) {
            [self passFocusToAttachedWindowOfWindow:focused];
        }
        return;
    }
    BOOL broughtBack = NO;
    for (NSNumber *hidden in [self attachedWindowsOfFrame:window]) {
        if ([_registry isWindowHiddenWithParent:[hidden unsignedIntValue]]) {
            [self placeWindow:[hidden unsignedIntValue]];
            xcb_map_window([_connection connection], [hidden unsignedIntValue]);
            broughtBack = YES;
        }
    }
    if (broughtBack) {
        [_connection flush];
        return;
    }
    if ([_registry parentOfWindow:window] == XCB_NONE ||
        ![self.compositingManager compositingActive]) {
        return;
    }
    [self.compositingManager setKeepsContentAfterUnmap:YES forWindow:window];
    [self.compositingManager playEffect:[[URSAttachmentSlideEffect alloc]
                                            initAppearing:YES
                                                  outward:[self slideEdgeOfWindow:window]]
                               onWindow:window];
}

- (void)windowWillUnmap:(xcb_window_t)window
{
    if ([_registry parentOfWindow:window] != XCB_NONE) {
        if ([_registry isWindowHiddenWithParent:window]) {
            // Unmapped by us along with its parent; still attached.
            return;
        }
        xcb_window_t parent = [_registry parentOfWindow:window];
        URSAttachmentEdge edge = [self slideEdgeOfWindow:window];
        [_registry detachWindow:window];
        [self forgetAttachmentOfWindow:window];
        [self returnFocusFromWindow:window toParent:parent];
        if ([self.compositingManager compositingActive]) {
            [self.compositingManager playEffect:[[URSAttachmentSlideEffect alloc]
                                                    initAppearing:NO outward:edge]
                                       onWindow:window];
        }
        return;
    }
    // A minimised or otherwise unmapped parent takes its attached windows
    // along; they would otherwise hang in the air where the parent was.
    BOOL hid = NO;
    for (NSNumber *attached in [self attachedWindowsOfFrame:window]) {
        if (![_registry isWindowHiddenWithParent:[attached unsignedIntValue]]) {
            [_registry setWindow:[attached unsignedIntValue] hiddenWithParent:YES];
            xcb_unmap_window([_connection connection], [attached unsignedIntValue]);
            hid = YES;
        }
    }
    if (hid) {
        [_connection flush];
    }
}

// The window manager never tracked the attached window as the focused
// window (it has no titlebar), so nothing else would give the focus back
// once it is gone.  By the time the unmap is seen the X server has already
// dropped its focus on the root window (or none), so that also counts as
// it having had it; a focus on any other window is the user's.
- (void)returnFocusFromWindow:(xcb_window_t)window toParent:(xcb_window_t)parent
{
    xcb_connection_t *c = [_connection connection];
    xcb_window_t root = [[[[_connection screens] firstObject] rootWindow] window];
    xcb_get_input_focus_reply_t *focus =
        xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL);
    BOOL hadFocus = focus && (focus->focus == window || focus->focus == root ||
                              focus->focus == XCB_NONE ||
                              focus->focus == XCB_INPUT_FOCUS_POINTER_ROOT);
    free(focus);
    XCBWindow *parentWindow = [_connection windowForXCBId:parent];
    if (hadFocus && parentWindow && [self frameOfClient:parent]) {
        [parentWindow focus];
        [_connection flush];
    }
}

- (void)windowDestroyed:(xcb_window_t)window
{
    if ([_registry parentOfWindow:window] != XCB_NONE) {
        [self forgetAttachmentOfWindow:window];
    }
    // The compositor keys outlines by window id, and X reuses ids.
    if (_placedRects[@(window)] != nil && [self.compositingManager compositingActive]) {
        [self.compositingManager setShapePath:nil clientOriginX:0 y:0 forWindow:window];
    }
    for (NSNumber *attached in [_registry windowsOfParent:window]) {
        [self forgetAttachmentOfWindow:[attached unsignedIntValue]];
    }
    [_registry forgetWindow:window];
    [_contentInsets removeObjectForKey:@(window)];
    [_placedRects removeObjectForKey:@(window)];
}

- (void)windowConfigured:(xcb_configure_notify_event_t *)event
{
    xcb_window_t parent = [_registry parentOfWindow:event->window];
    if (parent != XCB_NONE) {
        // Something restacked a sheet away from its parent.  A drawer below
        // the frame has some other window below it, which says nothing; the
        // frame's own ConfigureNotify puts it back.
        XCBFrame *frame = [self frameOfClient:parent];
        if ([self stacksAboveParent] && frame && event->above_sibling != [frame window]) {
            [self placeWindow:event->window];
        }
        return;
    }
    for (NSNumber *attached in [self attachedWindowsOfWindow:event->window]) {
        [self placeWindow:[attached unsignedIntValue]];
    }
}

@end
