/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSSheetController.h"
#import "URSSheetLayout.h"
#import "URSAttachmentRegistry.h"
#import "URSSheetSlideEffect.h"
#import "URSWindowRole.h"
#import "URSCompositingManager.h"
#import "XCBConnection.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "XCBScreen.h"

@implementation URSSheetController
{
    XCBConnection *_connection;
    xcb_atom_t _roleAtom;
    URSAttachmentRegistry *_registry;
}

- (instancetype)initWithConnection:(XCBConnection *)connection
{
    self = [super init];
    if (self) {
        _connection = connection;
        _registry = [URSAttachmentRegistry new];
        const char *name = [URSWindowRolePropertyName UTF8String];
        xcb_connection_t *c = [connection connection];
        xcb_intern_atom_reply_t *reply =
            xcb_intern_atom_reply(c, xcb_intern_atom(c, 0, strlen(name), name), NULL);
        _roleAtom = reply ? reply->atom : XCB_NONE;
        free(reply);
        if (_roleAtom == XCB_NONE) {
            NSLog(@"[Sheets] Cannot intern %@; sheets are shown as dialogs", URSWindowRolePropertyName);
        }
    }
    return self;
}

#pragma mark - Recognising a sheet

// The window it is a sheet of, or XCB_NONE: both the sheet role and
// WM_TRANSIENT_FOR must be there, since the role alone does not say whose
// sheet it is and WM_TRANSIENT_FOR alone is any dialog or child window.
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
    if ([role isEqualToString:URSWindowRoleSheet] &&
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

#pragma mark - Placement

- (void)placeSheet:(xcb_window_t)sheet
{
    xcb_window_t parent = [_registry parentOfWindow:sheet];
    XCBFrame *frame = [self frameOfClient:parent];
    XCBScreen *screen = [[_connection screens] firstObject];
    if (!frame || !screen) {
        return;
    }
    xcb_connection_t *c = [_connection connection];
    xcb_window_t root = [[screen rootWindow] window];

    // The client's own rect, not the frame's: the sheet hangs from where
    // the titlebar ends, whatever height the theme gives it.
    xcb_translate_coordinates_cookie_t originCookie =
        xcb_translate_coordinates(c, parent, root, 0, 0);
    xcb_get_geometry_cookie_t parentCookie = xcb_get_geometry(c, parent);
    xcb_get_geometry_cookie_t sheetCookie = xcb_get_geometry(c, sheet);
    xcb_translate_coordinates_reply_t *origin =
        xcb_translate_coordinates_reply(c, originCookie, NULL);
    xcb_get_geometry_reply_t *parentGeometry = xcb_get_geometry_reply(c, parentCookie, NULL);
    xcb_get_geometry_reply_t *sheetGeometry = xcb_get_geometry_reply(c, sheetCookie, NULL);

    if (origin && parentGeometry && sheetGeometry) {
        NSRect content = NSMakeRect(origin->dst_x, origin->dst_y,
                                    parentGeometry->width, parentGeometry->height);
        NSRect f = [URSSheetLayout frameForSheetSize:NSMakeSize(sheetGeometry->width,
                                                                sheetGeometry->height)
                                   parentContentRect:content
                                          screenRect:NSMakeRect(0, 0, [screen width],
                                                                [screen height])];
        uint32_t values[] = {
            (uint32_t)(int32_t)NSMinX(f), (uint32_t)(int32_t)NSMinY(f), 0,
            [frame window], XCB_STACK_MODE_ABOVE
        };
        xcb_configure_window(c, sheet,
                             XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                             XCB_CONFIG_WINDOW_BORDER_WIDTH |
                             XCB_CONFIG_WINDOW_SIBLING | XCB_CONFIG_WINDOW_STACK_MODE,
                             values);
        [_connection flush];
    }
    free(origin);
    free(parentGeometry);
    free(sheetGeometry);
}

#pragma mark - Showing a sheet

// Registers, places and maps a window that is a sheet of a decorated
// window; the caller has made sure it is one.
- (void)attachSheet:(xcb_window_t)window
           toParent:(xcb_window_t)parent
      mapStackParent:(xcb_window_t)stackParent
{
    XCBWindow *sheet = [_connection windowForXCBId:window];
    if (sheet == nil) {
        sheet = [[XCBWindow alloc] initWithXCBWindow:window andConnection:_connection];
        [sheet updateAttributes];
        [sheet setParentWindow:[[XCBWindow alloc] initWithXCBWindow:stackParent
                                                      andConnection:_connection]];
        [_connection registerWindow:sheet];
        // Like other undecorated windows: a click on it must give it the
        // focus back after the user clicked elsewhere.
        [sheet grabButton];
        // Its FocusIn is what draws the parent's titlebar active.
        uint32_t mask = XCB_EVENT_MASK_FOCUS_CHANGE;
        xcb_change_window_attributes([_connection connection], window,
                                     XCB_CW_EVENT_MASK, &mask);
    }
    [sheet setDecorated:NO];
    [sheet updatePid];

    [_registry attachWindow:window toParent:parent exclusive:YES];
    [self placeSheet:window];
    [_connection mapWindow:sheet];
    [sheet setNormalState];
    [_connection flush];
}

// The parent it can hang from, or XCB_NONE when the window is no sheet or
// has nothing to hang from (an undecorated or unknown parent) and so is
// shown as an ordinary window.
- (xcb_window_t)attachableParentOfSheet:(xcb_window_t)window
{
    xcb_window_t parent = [self markedParentOfWindow:window];
    if (parent == XCB_NONE || [self frameOfClient:parent] == nil) {
        return XCB_NONE;
    }
    if ([[[_connection windowForXCBId:window] parentWindow] isKindOfClass:[XCBFrame class]]) {
        // Still framed from being shown as an ordinary dialog before.
        return XCB_NONE;
    }
    return parent;
}

- (BOOL)handleMapRequest:(xcb_map_request_event_t *)event
{
    xcb_window_t parent = [self attachableParentOfSheet:event->window];
    if (parent == XCB_NONE) {
        return NO;
    }
    [self attachSheet:event->window toParent:parent mapStackParent:event->parent];
    return YES;
}

- (BOOL)isSheet:(xcb_window_t)window
{
    return [self markedParentOfWindow:window] != XCB_NONE;
}

- (BOOL)adoptMappedSheet:(xcb_window_t)window
{
    xcb_window_t parent = [self attachableParentOfSheet:window];
    if (parent == XCB_NONE) {
        return NO;
    }
    XCBScreen *screen = [[_connection screens] firstObject];
    [self attachSheet:window toParent:parent mapStackParent:[[screen rootWindow] window]];
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
    uint16_t mask = 0;
    uint32_t values[2];
    int n = 0;
    if (event->value_mask & XCB_CONFIG_WINDOW_WIDTH) {
        mask |= XCB_CONFIG_WINDOW_WIDTH;
        values[n++] = event->width;
    }
    if (event->value_mask & XCB_CONFIG_WINDOW_HEIGHT) {
        mask |= XCB_CONFIG_WINDOW_HEIGHT;
        values[n++] = event->height;
    }
    if (mask != 0) {
        xcb_configure_window([_connection connection], event->window, mask, values);
    }
    // A sheet that grows stays centred under the titlebar.
    [self placeSheet:event->window];
    return YES;
}

#pragma mark - Following the parent

- (xcb_window_t)parentOfSheet:(xcb_window_t)window
{
    return [_registry parentOfWindow:window];
}

// The sheet hanging from a window given as its client or its frame.
- (xcb_window_t)sheetOfWindow:(xcb_window_t)window
{
    xcb_window_t sheet = [_registry windowOfParent:window];
    return sheet != XCB_NONE ? sheet : [self sheetOfFrame:window];
}

// Only the frame says whether the parent is shown: its client is also
// unmapped and mapped again when it is reparented into a new frame (every
// window the window manager adopts when it starts), which must not hide
// the sheet.
- (xcb_window_t)sheetOfFrame:(xcb_window_t)window
{
    for (NSNumber *candidate in [_registry windows]) {
        XCBFrame *frame = [self frameOfClient:[_registry parentOfWindow:[candidate unsignedIntValue]]];
        if (frame && [frame window] == window) {
            return [candidate unsignedIntValue];
        }
    }
    return XCB_NONE;
}

- (BOOL)passFocusToSheetOfWindow:(xcb_window_t)window
{
    xcb_window_t sheet = [self sheetOfWindow:window];
    if (sheet == XCB_NONE || [_registry isWindowHiddenWithParent:sheet]) {
        return NO;
    }
    [[_connection windowForXCBId:sheet] focus];
    [_connection flush];
    return YES;
}

- (void)windowMapped:(xcb_window_t)window
{
    if ([_registry isWindowHiddenWithParent:window]) {
        // Back with its restored parent: no slide, it was never dismissed.
        [_registry setWindow:window hiddenWithParent:NO];
        // The restored parent may have been focused before the sheet was
        // back; that focus is the sheet's.
        xcb_connection_t *c = [_connection connection];
        xcb_get_input_focus_reply_t *focus =
            xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL);
        xcb_window_t focused = focus ? focus->focus : XCB_NONE;
        free(focus);
        if (focused != XCB_NONE && [self sheetOfWindow:focused] == window) {
            [self passFocusToSheetOfWindow:focused];
        }
        return;
    }
    xcb_window_t hidden = [self sheetOfFrame:window];
    if (hidden != XCB_NONE && [_registry isWindowHiddenWithParent:hidden]) {
        [self placeSheet:hidden];
        xcb_map_window([_connection connection], hidden);
        [_connection flush];
        return;
    }
    if ([_registry parentOfWindow:window] == XCB_NONE ||
        ![self.compositingManager compositingActive]) {
        return;
    }
    [self.compositingManager setKeepsContentAfterUnmap:YES forWindow:window];
    [self.compositingManager playEffect:[[URSSheetSlideEffect alloc] initAppearing:YES]
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
        [_registry detachWindow:window];
        [self returnFocusFromSheet:window toParent:parent];
        if ([self.compositingManager compositingActive]) {
            [self.compositingManager playEffect:[[URSSheetSlideEffect alloc] initAppearing:NO]
                                       onWindow:window];
        }
        return;
    }
    // A minimised or otherwise unmapped parent takes its sheet along; the
    // sheet would otherwise hang in the air where the parent was.
    xcb_window_t sheet = [self sheetOfFrame:window];
    if (sheet != XCB_NONE && ![_registry isWindowHiddenWithParent:sheet]) {
        [_registry setWindow:sheet hiddenWithParent:YES];
        xcb_unmap_window([_connection connection], sheet);
        [_connection flush];
    }
}

// The window manager never tracked the sheet as the focused window (it
// has no titlebar), so nothing else would give the focus back once it is
// gone.  By the time the unmap is seen the X server has already dropped
// the sheet's focus on the root window (or none), so that also counts as
// the sheet having had it; a focus on any other window is the user's.
- (void)returnFocusFromSheet:(xcb_window_t)sheet toParent:(xcb_window_t)parent
{
    xcb_connection_t *c = [_connection connection];
    xcb_window_t root = [[[[_connection screens] firstObject] rootWindow] window];
    xcb_get_input_focus_reply_t *focus =
        xcb_get_input_focus_reply(c, xcb_get_input_focus(c), NULL);
    BOOL sheetHadFocus = focus && (focus->focus == sheet || focus->focus == root ||
                                   focus->focus == XCB_NONE ||
                                   focus->focus == XCB_INPUT_FOCUS_POINTER_ROOT);
    free(focus);
    XCBWindow *parentWindow = [_connection windowForXCBId:parent];
    if (sheetHadFocus && parentWindow && [self frameOfClient:parent]) {
        [parentWindow focus];
        [_connection flush];
    }
}

- (void)windowDestroyed:(xcb_window_t)window
{
    [_registry forgetWindow:window];
}

- (void)windowConfigured:(xcb_configure_notify_event_t *)event
{
    xcb_window_t parent = [_registry parentOfWindow:event->window];
    if (parent != XCB_NONE) {
        // Something restacked the sheet away from its parent.
        XCBFrame *frame = [self frameOfClient:parent];
        if (frame && event->above_sibling != [frame window]) {
            [self placeSheet:event->window];
        }
        return;
    }
    xcb_window_t sheet = [self sheetOfWindow:event->window];
    if (sheet != XCB_NONE) {
        [self placeSheet:sheet];
    }
}

@end
