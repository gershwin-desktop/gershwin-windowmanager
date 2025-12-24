//
//  UROSWindowDecorator.m
//  uroswm - Independent Window Decoration
//
//  Implementation of independent window decoration that completely
//  bypasses XCBKit and uses only our GSTheme titlebar system.
//

#import "UROSWindowDecorator.h"

static NSMutableDictionary *windowTitlebars = nil;

@implementation UROSWindowDecorator

+ (void)initialize {
    if (self == [UROSWindowDecorator class]) {
        windowTitlebars = [[NSMutableDictionary alloc] init];
    }
}

+ (void)decorateWindow:(xcb_window_t)clientWindow
        withConnection:(XCBConnection*)connection
                 title:(NSString*)title {

    NSLog(@"UROSWindowDecorator: Decorating window %u with independent GSTheme titlebar", clientWindow);

    // Get client window geometry
    xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry([connection connection], clientWindow);
    xcb_get_geometry_reply_t *geom_reply = xcb_get_geometry_reply([connection connection], geom_cookie, NULL);

    if (!geom_reply) {
        NSLog(@"UROSWindowDecorator: Failed to get geometry for window %u", clientWindow);
        return;
    }

    // Create frame window to hold the client window and titlebar
    xcb_window_t frameWindow = [self createFrameWindow:connection
                                               geometry:geom_reply
                                           clientWindow:clientWindow];

    // Calculate titlebar position (top of frame)
    NSRect titlebarFrame = NSMakeRect(0, 0, geom_reply->width, 25);

    // Create our independent titlebar
    UROSTitleBar *titlebar = [[UROSTitleBar alloc] initWithConnection:connection
                                                                frame:titlebarFrame
                                                         parentWindow:frameWindow];

    [titlebar setTitle:title];
    [titlebar show];

    // Reparent client window into frame, below titlebar
    [self reparentClientWindow:clientWindow
                      intoFrame:frameWindow
                  withTitlebarHeight:25
                        connection:connection];

    // Store titlebar for this client window
    NSString *windowKey = [NSString stringWithFormat:@"%u", clientWindow];
    windowTitlebars[windowKey] = titlebar;

    // Show the frame window
    xcb_map_window([connection connection], frameWindow);
    [connection flush];

    free(geom_reply);

    NSLog(@"UROSWindowDecorator: Window %u decorated with independent GSTheme titlebar", clientWindow);
}

+ (xcb_window_t)createFrameWindow:(XCBConnection*)connection
                         geometry:(xcb_get_geometry_reply_t*)geom
                     clientWindow:(xcb_window_t)clientWindow {

    XCBScreen *screen = [[connection screens] objectAtIndex:0];

    // Frame is larger than client to accommodate titlebar
    uint16_t frameWidth = geom->width;
    uint16_t frameHeight = geom->height + 25; // +25 for titlebar

    xcb_window_t frameWindow = xcb_generate_id([connection connection]);

    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t values[2];
    values[0] = [screen screen]->white_pixel;
    values[1] = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
                XCB_EVENT_MASK_EXPOSURE;

    xcb_create_window([connection connection],
                      XCB_COPY_FROM_PARENT,
                      frameWindow,
                      [screen screen]->root,
                      geom->x, geom->y - 25, // Position frame to show titlebar above client
                      frameWidth, frameHeight,
                      1, // border width
                      XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      [screen screen]->root_visual,
                      mask,
                      values);

    NSLog(@"UROSWindowDecorator: Created frame window %u (%dx%d)",
          frameWindow, frameWidth, frameHeight);

    return frameWindow;
}

+ (void)reparentClientWindow:(xcb_window_t)clientWindow
                   intoFrame:(xcb_window_t)frameWindow
           withTitlebarHeight:(int)titlebarHeight
                  connection:(XCBConnection*)connection {

    // Reparent client window into frame, positioned below titlebar
    xcb_reparent_window([connection connection],
                        clientWindow,
                        frameWindow,
                        0, titlebarHeight);

    NSLog(@"UROSWindowDecorator: Reparented client window %u into frame %u",
          clientWindow, frameWindow);
}

+ (void)updateWindowTitle:(xcb_window_t)clientWindow title:(NSString*)title {
    UROSTitleBar *titlebar = [self titlebarForWindow:clientWindow];
    if (titlebar) {
        [titlebar setTitle:title];
        NSLog(@"UROSWindowDecorator: Updated title for window %u: %@", clientWindow, title);
    }
}

+ (void)setWindowActive:(xcb_window_t)clientWindow active:(BOOL)active {
    UROSTitleBar *titlebar = [self titlebarForWindow:clientWindow];
    if (titlebar) {
        [titlebar setActive:active];
        NSLog(@"UROSWindowDecorator: Set window %u active: %d", clientWindow, active);
    }
}

+ (void)undecoateWindow:(xcb_window_t)clientWindow {
    NSString *windowKey = [NSString stringWithFormat:@"%u", clientWindow];
    UROSTitleBar *titlebar = windowTitlebars[windowKey];

    if (titlebar) {
        [titlebar destroy];
        [windowTitlebars removeObjectForKey:windowKey];
        NSLog(@"UROSWindowDecorator: Undecorated window %u", clientWindow);
    }
}

+ (UROSTitleBar*)titlebarForWindow:(xcb_window_t)clientWindow {
    NSString *windowKey = [NSString stringWithFormat:@"%u", clientWindow];
    return windowTitlebars[windowKey];
}

+ (BOOL)handleExposeEvent:(xcb_expose_event_t*)event {
    // Find titlebar that owns this window and redraw
    for (UROSTitleBar *titlebar in [windowTitlebars allValues]) {
        if (titlebar.windowId == event->window) {
            [titlebar renderWithGSTheme];
            return YES; // We handled this expose event
        }
    }
    return NO; // Not our titlebar
}

+ (BOOL)handleButtonEvent:(xcb_button_press_event_t*)event {
    // Find titlebar that owns this window and handle button press
    for (UROSTitleBar *titlebar in [windowTitlebars allValues]) {
        if (titlebar.windowId == event->event) {
            [titlebar handleButtonPress:event];
            return YES; // We handled this button press
        }
    }
    return NO; // Not our titlebar
}

@end