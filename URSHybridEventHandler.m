//
//  URSHybridEventHandler.m
//  uroswm - Phase 1: NSApplication + NSRunLoop Integration
//
//  Created by Alessandro Sangiuliano on 22/06/20.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//
//  Phase 1 Enhancement: NSApplication delegate that integrates XCB event handling
//  with NSRunLoop using file descriptor monitoring (following libs-back pattern).
//

#import "URSHybridEventHandler.h"
#import <XCBKit/XCBScreen.h>
#import <xcb/xcb.h>
#import <XCBKit/services/EWMHService.h>
#import <XCBKit/XCBFrame.h>
#import "URSThemeIntegration.h"

@implementation URSHybridEventHandler

@synthesize connection;
@synthesize selectionManagerWindow;
@synthesize xcbEventsIntegrated;
@synthesize nsRunLoopActive;
@synthesize eventCount;

#pragma mark - Initialization

- (id)init
{
    self = [super init];

    if (self == nil) {
        NSLog(@"Unable to init URSHybridEventHandler...");
        return nil;
    }

    // Initialize event tracking
    self.xcbEventsIntegrated = NO;
    self.nsRunLoopActive = NO;
    self.eventCount = 0;

    // Initialize XCB connection (same as original)
    connection = [XCBConnection sharedConnectionAsWindowManager:YES];

    return self;
}

#pragma mark - NSApplicationDelegate Methods

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // Mark NSRunLoop as active
    self.nsRunLoopActive = YES;

    // Register as window manager (same as original)
    [self registerAsWindowManager];

    // Setup XCB event integration with NSRunLoop
    [self setupXCBEventIntegration];

    // Setup simple timer-based theme integration
    [self setupPeriodicThemeIntegration];
    NSLog(@"GSTheme integration initialized with periodic checking enabled");
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateNow;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    // Keep running even if no windows are visible (window manager behavior)
    return NO;
}

#pragma mark - Original URSEventHandler Methods (Preserved)

- (void)registerAsWindowManager
{
    XCBScreen *screen = [[connection screens] objectAtIndex:0];
    XCBVisual *visual = [[XCBVisual alloc] initWithVisualId:[screen screen]->root_visual];
    [visual setVisualTypeForScreen:screen];

    selectionManagerWindow = [connection createWindowWithDepth:[screen screen]->root_depth
                                                 withParentWindow:[screen rootWindow]
                                                    withXPosition:-1
                                                    withYPosition:-1
                                                        withWidth:1
                                                       withHeight:1
                                                 withBorrderWidth:0
                                                     withXCBClass:XCB_COPY_FROM_PARENT
                                                     withVisualId:visual
                                                    withValueMask:0
                                                    withValueList:NULL
                                                  registerWindow:YES];

    [connection registerAsWindowManager:YES screenId:0 selectionWindow:selectionManagerWindow];

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    [ewmhService putPropertiesForRootWindow:[screen rootWindow] andWmWindow:selectionManagerWindow];
    [connection flush];

    // ARC handles cleanup automatically

}

#pragma mark - NSRunLoop Integration (New for Phase 1)

- (void)setupXCBEventIntegration
{

    // Get XCB file descriptor for monitoring
    int xcbFD = xcb_get_file_descriptor([connection connection]);
    if (xcbFD < 0) {
        NSLog(@"ERROR Phase 1: Failed to get XCB file descriptor");
        return;
    }

    // Follow libs-back pattern for NSRunLoop file descriptor monitoring
    NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];

    // Add XCB file descriptor to NSRunLoop for read events
    [currentRunLoop addEvent:(void*)(uintptr_t)xcbFD
                        type:ET_RDESC
                     watcher:self
                     forMode:NSDefaultRunLoopMode];

    // Also add for NSRunLoopCommonModes to ensure events are processed
    [currentRunLoop addEvent:(void*)(uintptr_t)xcbFD
                        type:ET_RDESC
                     watcher:self
                     forMode:NSRunLoopCommonModes];

    self.xcbEventsIntegrated = YES;

    // Start monitoring for XCB events immediately
    [self performSelector:@selector(processAvailableXCBEvents)
               withObject:nil
               afterDelay:0.1];
}

#pragma mark - RunLoopEvents Protocol Implementation

- (void)receivedEvent:(void*)data
                 type:(RunLoopEventType)type
                extra:(void*)extra
              forMode:(NSString*)mode
{
    if (type == ET_RDESC) {
        // Process available XCB events (non-blocking)
        [self processAvailableXCBEvents];
    }
}

- (void)processAvailableXCBEvents
{
    xcb_generic_event_t *e;
    xcb_motion_notify_event_t *lastMotionEvent = NULL;
    BOOL needFlush = NO;
    NSUInteger eventsProcessed = 0;

    // Use xcb_poll_for_event (non-blocking) instead of xcb_wait_for_event (blocking)
    while ((e = xcb_poll_for_event([connection connection]))) {
        eventsProcessed++;

        // Handle motion event compression (same as original)
        if ((e->response_type & ~0x80) == XCB_MOTION_NOTIFY) {
            // Motion event compression: save the latest motion event
            if (lastMotionEvent) {
                free(lastMotionEvent);
            }
            lastMotionEvent = malloc(sizeof(xcb_motion_notify_event_t));
            memcpy(lastMotionEvent, e, sizeof(xcb_motion_notify_event_t));

            // Check if more events are queued - if so, skip processing this one
            xcb_generic_event_t *nextEvent = xcb_poll_for_event([connection connection]);
            if (nextEvent) {
                // There's another event queued, defer motion processing
                free(e);
                e = nextEvent;
                continue; // Process the next event instead
            } else {
                // No more events, process the motion
                [connection handleMotionNotify:lastMotionEvent];
                needFlush = YES;
                free(lastMotionEvent);
                lastMotionEvent = NULL;
                free(e);
                continue;
            }
        }

        [self processXCBEvent:e];

        // Check if we need to flush after this event
        if ([self eventNeedsFlush:e]) {
            needFlush = YES;
        }

        free(e);
    }

    // Clean up any remaining motion event
    if (lastMotionEvent) {
        free(lastMotionEvent);
    }

    // Batched flush: only flush when needed
    if (needFlush) {
        [connection flush];
        [connection setNeedFlush:NO];
    }

    // Update event statistics
    self.eventCount += eventsProcessed;

}

- (void)processXCBEvent:(xcb_generic_event_t*)event
{
    // Process individual XCB event (same logic as original startEventHandlerLoop)
    switch (event->response_type & ~0x80) {
        case XCB_VISIBILITY_NOTIFY: {
            xcb_visibility_notify_event_t *visibilityEvent = (xcb_visibility_notify_event_t *)event;
            [connection handleVisibilityEvent:visibilityEvent];
            break;
        }
        case XCB_EXPOSE: {
            xcb_expose_event_t *exposeEvent = (xcb_expose_event_t *)event;
            [connection handleExpose:exposeEvent];

            // Re-apply GSTheme if this is a titlebar expose event
            [self handleTitlebarExpose:exposeEvent];
            break;
        }
        case XCB_ENTER_NOTIFY: {
            xcb_enter_notify_event_t *enterEvent = (xcb_enter_notify_event_t *)event;
            [connection handleEnterNotify:enterEvent];
            break;
        }
        case XCB_LEAVE_NOTIFY: {
            xcb_leave_notify_event_t *leaveEvent = (xcb_leave_notify_event_t *)event;
            [connection handleLeaveNotify:leaveEvent];
            break;
        }
        case XCB_FOCUS_IN: {
            xcb_focus_in_event_t *focusInEvent = (xcb_focus_in_event_t *)event;
            [connection handleFocusIn:focusInEvent];
            break;
        }
        case XCB_FOCUS_OUT: {
            xcb_focus_out_event_t *focusOutEvent = (xcb_focus_out_event_t *)event;
            [connection handleFocusOut:focusOutEvent];
            break;
        }
        case XCB_BUTTON_PRESS: {
            xcb_button_press_event_t *pressEvent = (xcb_button_press_event_t *)event;
            [connection handleButtonPress:pressEvent];
            break;
        }
        case XCB_BUTTON_RELEASE: {
            xcb_button_release_event_t *releaseEvent = (xcb_button_release_event_t *)event;
            [connection handleButtonRelease:releaseEvent];
            break;
        }
        case XCB_MAP_NOTIFY: {
            xcb_map_notify_event_t *notifyEvent = (xcb_map_notify_event_t *)event;
            [connection handleMapNotify:notifyEvent];
            break;
        }
        case XCB_MAP_REQUEST: {
            xcb_map_request_event_t *mapRequestEvent = (xcb_map_request_event_t *)event;

            // Let XCBConnection handle the map request normally (this creates titlebar structure)
            [connection handleMapRequest:mapRequestEvent];

            // Immediately apply GSTheme after XCBConnection creates the structure
            [self performSelector:@selector(applyGSThemeToRecentlyMappedWindow:)
                       withObject:[NSNumber numberWithUnsignedInt:mapRequestEvent->window]
                       afterDelay:0.05]; // Very short delay
            break;
        }
        case XCB_UNMAP_NOTIFY: {
            xcb_unmap_notify_event_t *unmapNotifyEvent = (xcb_unmap_notify_event_t *)event;
            [connection handleUnMapNotify:unmapNotifyEvent];
            break;
        }
        case XCB_DESTROY_NOTIFY: {
            xcb_destroy_notify_event_t *destroyNotify = (xcb_destroy_notify_event_t *)event;
            [connection handleDestroyNotify:destroyNotify];
            break;
        }
        case XCB_CLIENT_MESSAGE: {
            xcb_client_message_event_t *clientMessageEvent = (xcb_client_message_event_t *)event;
            [connection handleClientMessage:clientMessageEvent];
            break;
        }
        case XCB_CONFIGURE_REQUEST: {
            xcb_configure_request_event_t *configRequest = (xcb_configure_request_event_t *)event;
            [connection handleConfigureWindowRequest:configRequest];
            break;
        }
        case XCB_CONFIGURE_NOTIFY: {
            xcb_configure_notify_event_t *configureNotify = (xcb_configure_notify_event_t *)event;
            [connection handleConfigureNotify:configureNotify];
            break;
        }
        case XCB_PROPERTY_NOTIFY: {
            xcb_property_notify_event_t *propEvent = (xcb_property_notify_event_t *)event;
            [connection handlePropertyNotify:propEvent];
            break;
        }
        default:
            break;
    }
}

- (BOOL)eventNeedsFlush:(xcb_generic_event_t*)event
{
    // Determine if event requires immediate flush (same logic as original)
    switch (event->response_type & ~0x80) {
        case XCB_EXPOSE:
        case XCB_BUTTON_PRESS:
        case XCB_BUTTON_RELEASE:
        case XCB_MAP_REQUEST:
        case XCB_DESTROY_NOTIFY:
        case XCB_CLIENT_MESSAGE:
        case XCB_CONFIGURE_REQUEST:
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Phase 1 Validation Methods





#pragma mark - GSTheme Integration (NEW)

- (void)handleWindowCreated:(XCBTitleBar*)titlebar {
    if (!titlebar) {
        return;
    }

    NSLog(@"GSTheme: Applying theme to new titlebar for window: %@", titlebar.windowTitle);

    // Register with theme integration
    [[URSThemeIntegration sharedInstance] handleWindowCreated:titlebar];

    // Apply GSTheme rendering
    BOOL success = [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                                        title:titlebar.windowTitle
                                                       active:YES]; // Assume new windows are active

    if (!success) {
        NSLog(@"GSTheme rendering failed for titlebar, falling back to Cairo");
        // XCBTitleBar will fall back to its default Cairo rendering
    }
}

- (void)handleWindowFocusChanged:(XCBTitleBar*)titlebar isActive:(BOOL)active {
    if (!titlebar) {
        return;
    }

    NSLog(@"GSTheme: Focus changed for window %@ (active: %d)", titlebar.windowTitle, active);

    // Update theme integration
    [[URSThemeIntegration sharedInstance] handleWindowFocusChanged:titlebar isActive:active];

    // Re-render with new focus state
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:active];
}

- (void)refreshAllManagedWindows {
    NSLog(@"GSTheme: Refreshing all managed windows with current theme");
    [URSThemeIntegration refreshAllTitlebars];
}

// Simple periodic check for new windows that need GSTheme
- (void)setupPeriodicThemeIntegration {
    // Use a timer to periodically check for new windows (less frequent)
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(checkForNewWindows)
                                   userInfo:nil
                                    repeats:YES];
    NSLog(@"Periodic GSTheme integration timer started (5 second interval)");
}

- (void)handleMapRequestWithGSTheme:(xcb_map_request_event_t*)mapRequestEvent {
    @try {
        NSLog(@"Intercepting map request for window %u - using GSTheme-only decoration", mapRequestEvent->window);

        // Let XCBConnection handle the map request BUT don't let it decorate with XCBKit
        // We need to duplicate XCBConnection's handleMapRequest logic but skip the decorateClientWindow call

        xcb_window_t requestWindow = mapRequestEvent->window;

        // Get window geometry
        xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry([connection connection], requestWindow);
        xcb_get_geometry_reply_t *geom_reply = xcb_get_geometry_reply([connection connection], geom_cookie, NULL);

        if (geom_reply) {
            NSLog(@"Window geometry: %dx%d at %d,%d", geom_reply->width, geom_reply->height, geom_reply->x, geom_reply->y);

            // Create frame without XCBKit titlebar decoration
            XCBWindow *clientWindow = [connection windowForXCBId:requestWindow];
            if (!clientWindow) {
                // Create a basic client window object
                clientWindow = [[XCBWindow alloc] init];
                [clientWindow setWindow:requestWindow];
                [clientWindow setConnection:connection];
                [connection registerWindow:clientWindow];
            }

            // Create frame for the window (this will create the structure but we'll handle decoration)
            XCBFrame *frame = [[XCBFrame alloc] initWithClientWindow:clientWindow withConnection:connection];

            NSLog(@"Created frame for client window, will apply GSTheme-only decoration");

            // Map the frame and client window
            [connection mapWindow:frame];
            [connection registerWindow:clientWindow];

            // Apply ONLY GSTheme decoration (no XCBKit titlebar drawing)
            [self performSelector:@selector(applyGSThemeOnlyDecoration:)
                       withObject:frame
                       afterDelay:0.1]; // Short delay to let frame be fully mapped

            free(geom_reply);
        } else {
            NSLog(@"Failed to get geometry for window %u, falling back to normal handling", requestWindow);
            // Fallback to normal XCBConnection handling
            [connection handleMapRequest:mapRequestEvent];
        }

    } @catch (NSException *exception) {
        NSLog(@"Exception in GSTheme map request handler: %@", exception.reason);
        // Fallback to normal handling
        [connection handleMapRequest:mapRequestEvent];
    }
}

- (void)applyGSThemeOnlyDecoration:(XCBFrame*)frame {
    @try {
        NSLog(@"Applying GSTheme-only decoration to frame");

        // Get the titlebar from the frame
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

            // Apply ONLY GSTheme rendering (no Cairo/XCBKit drawing)
            BOOL success = [URSThemeIntegration renderGSThemeToWindow:frame
                                                                frame:frame
                                                                title:titlebar.windowTitle
                                                               active:YES];

            if (success) {
                NSLog(@"GSTheme-only decoration applied successfully");

                // Add to managed list
                URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];
                if (![integration.managedTitlebars containsObject:titlebar]) {
                    [integration.managedTitlebars addObject:titlebar];
                }
            } else {
                NSLog(@"GSTheme-only decoration failed");
            }
        } else {
            NSLog(@"No titlebar found in frame for GSTheme decoration");
        }

    } @catch (NSException *exception) {
        NSLog(@"Exception applying GSTheme-only decoration: %@", exception.reason);
    }
}

- (void)handleTitlebarExpose:(xcb_expose_event_t*)exposeEvent {
    @try {
        URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];
        if (!integration.enabled) {
            return;
        }

        xcb_window_t exposedWindow = exposeEvent->window;

        // Check if the exposed window is a titlebar we're managing
        for (XCBTitleBar *titlebar in integration.managedTitlebars) {
            if ([titlebar window] == exposedWindow) {
                // This titlebar was exposed, re-apply GSTheme to override XCBKit redrawing
                NSString *windowIdString = [NSString stringWithFormat:@"%u", exposedWindow];
                XCBWindow *window = [[self.connection windowsMap] objectForKey:windowIdString];

                if (window && [window isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *frame = (XCBFrame*)window;

                    NSLog(@"Titlebar %u exposed, re-applying GSTheme", exposedWindow);

                    // Re-apply GSTheme rendering to override the expose redraw
                    [URSThemeIntegration renderGSThemeToWindow:window
                                                         frame:frame
                                                         title:titlebar.windowTitle
                                                        active:YES];
                }
                break;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in titlebar expose handler: %@", exception.reason);
    }
}

- (void)applyGSThemeToRecentlyMappedWindow:(NSNumber*)windowIdNumber {
    @try {
        xcb_window_t windowId = [windowIdNumber unsignedIntValue];

        NSLog(@"Applying GSTheme to recently mapped window: %u", windowId);

        // Find the frame for this client window
        NSDictionary *windowsMap = [self.connection windowsMap];

        for (NSString *mapWindowId in windowsMap) {
            XCBWindow *window = [windowsMap objectForKey:mapWindowId];

            if (window && [window isKindOfClass:[XCBFrame class]]) {
                XCBFrame *frame = (XCBFrame*)window;
                XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];

                // Check if this frame contains our client window
                if (clientWindow && [clientWindow window] == windowId) {
                    XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];

                    if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
                        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

                        NSLog(@"Found frame for client window %u, applying GSTheme to titlebar", windowId);

                        // Apply GSTheme rendering (this will override XCBKit's decoration)
                        BOOL success = [URSThemeIntegration renderGSThemeToWindow:window
                                                                             frame:frame
                                                                             title:titlebar.windowTitle
                                                                            active:YES];

                        if (success) {
                            // Add to managed list so we can handle expose events
                            URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];
                            if (![integration.managedTitlebars containsObject:titlebar]) {
                                [integration.managedTitlebars addObject:titlebar];
                            }

                            NSLog(@"Successfully applied GSTheme to titlebar for window %u: %@",
                                  windowId, titlebar.windowTitle ?: @"(untitled)");

                            // Apply GSTheme again after a short delay to override any subsequent XCBKit drawing
                            [self performSelector:@selector(reapplyGSThemeToTitlebar:)
                                       withObject:titlebar
                                       afterDelay:0.1];
                        } else {
                            NSLog(@"Failed to apply GSTheme to titlebar for window %u", windowId);
                        }

                        return; // Found and processed
                    }
                }
            }
        }

        NSLog(@"Could not find frame for client window %u", windowId);

    } @catch (NSException *exception) {
        NSLog(@"Exception applying GSTheme to recently mapped window: %@", exception.reason);
    }
}

- (void)reapplyGSThemeToTitlebar:(XCBTitleBar*)titlebar {
    @try {
        if (!titlebar) return;

        NSLog(@"Reapplying GSTheme to titlebar: %@", titlebar.windowTitle);

        // Find the frame containing this titlebar
        NSDictionary *windowsMap = [self.connection windowsMap];

        for (NSString *windowId in windowsMap) {
            XCBWindow *window = [windowsMap objectForKey:windowId];

            if (window && [window isKindOfClass:[XCBFrame class]]) {
                XCBFrame *frame = (XCBFrame*)window;
                XCBWindow *frameTitle = [frame childWindowForKey:TitleBar];

                if (frameTitle && frameTitle == titlebar) {
                    // Reapply GSTheme rendering
                    [URSThemeIntegration renderGSThemeToWindow:window
                                                         frame:frame
                                                         title:titlebar.windowTitle
                                                        active:YES];
                    NSLog(@"GSTheme reapplied to titlebar: %@", titlebar.windowTitle);
                    return;
                }
            }
        }

        NSLog(@"Could not find frame for titlebar reapplication");

    } @catch (NSException *exception) {
        NSLog(@"Exception in GSTheme reapplication: %@", exception.reason);
    }
}

- (void)checkForNewWindows {
    @try {
        // Check if GSTheme integration is enabled
        URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];
        if (!integration.enabled) {
            return; // Skip if disabled
        }

        // Check all windows in the connection for new frames/titlebars
        NSDictionary *windowsMap = [self.connection windowsMap];
        NSUInteger newTitlebarsFound = 0;

        for (NSString *windowId in windowsMap) {
            XCBWindow *window = [windowsMap objectForKey:windowId];

            // Look for XCBFrame objects (which contain titlebars)
            if (window && [window isKindOfClass:[XCBFrame class]]) {
                XCBFrame *frame = (XCBFrame*)window;
                XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];

                if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
                    XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

                    // Check if we've already processed this titlebar
                    if (![integration.managedTitlebars containsObject:titlebar]) {
                        newTitlebarsFound++;

                        // Apply standalone GSTheme rendering
                        BOOL success = [URSThemeIntegration renderGSThemeToWindow:window
                                                                             frame:frame
                                                                             title:titlebar.windowTitle
                                                                            active:YES];

                        if (success) {
                            // Add to managed list only if successful
                            [integration.managedTitlebars addObject:titlebar];
                            NSLog(@"Applied GSTheme to new titlebar: %@", titlebar.windowTitle ?: @"(untitled)");
                        }
                    }
                }
            }
        }

        // Only log if we found new titlebars
        if (newTitlebarsFound > 0) {
            NSLog(@"GSTheme periodic check: processed %lu new titlebars", (unsigned long)newTitlebarsFound);
        }

    } @catch (NSException *exception) {
        NSLog(@"Exception in periodic window check: %@", exception.reason);
    }
}

#pragma mark - Cleanup

- (void)dealloc
{

    // Remove from run loop if integrated
    if (self.xcbEventsIntegrated && connection) {
        int xcbFD = xcb_get_file_descriptor([connection connection]);
        if (xcbFD >= 0) {
            NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];
            [currentRunLoop removeEvent:(void*)(uintptr_t)xcbFD
                                   type:ET_RDESC
                                forMode:NSDefaultRunLoopMode
                                   all:YES];
        }
    }

    // Remove notification center observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // ARC handles memory management automatically
}

@end