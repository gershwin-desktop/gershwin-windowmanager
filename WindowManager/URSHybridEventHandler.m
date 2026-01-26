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
#import <XCBKit/XCBQueryTreeReply.h>
#import <XCBKit/XCBAttributesReply.h>
#import <xcb/xcb.h>
#import <xcb/xcb_icccm.h>
#import <xcb/xcb_aux.h>
#import <xcb/damage.h>
#import <X11/keysym.h>
#import <XCBKit/services/EWMHService.h>
#import <XCBKit/services/XCBAtomService.h>
#import <XCBKit/services/ICCCMService.h>
#import <XCBKit/XCBFrame.h>
#import "URSThemeIntegration.h"
#import "GSThemeTitleBar.h"
#import "URSWindowSwitcher.h"

@implementation URSHybridEventHandler

@synthesize connection;
@synthesize selectionManagerWindow;
@synthesize xcbEventsIntegrated;
@synthesize nsRunLoopActive;
@synthesize eventCount;
@synthesize lastFocusedWindowId;
@synthesize previousFocusedWindowId;
@synthesize windowSwitcher;
@synthesize altKeyPressed;
@synthesize shiftKeyPressed;
@synthesize compositingManager;
@synthesize compositingRequested;
@synthesize windowStruts;
@synthesize recentlyAutoFocusedWindowIds;

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
    self.lastFocusedWindowId = XCB_NONE;
    self.previousFocusedWindowId = XCB_NONE;

    // Initialize XCB connection (same as original)
    connection = [XCBConnection sharedConnectionAsWindowManager:YES];

    // Initialize window switcher
    self.windowSwitcher = [URSWindowSwitcher sharedSwitcherWithConnection:connection];
    self.altKeyPressed = NO;
    self.shiftKeyPressed = NO;
    
    // Initialize strut tracking dictionary
    self.windowStruts = [[NSMutableDictionary alloc] init];
    
    // Initialize set to track recently auto-focused windows (to prevent double-focus)
    self.recentlyAutoFocusedWindowIds = [[NSMutableSet alloc] init];
    
    // Check if compositing was requested via command-line
    self.compositingRequested = [[NSUserDefaults standardUserDefaults] 
                                  boolForKey:@"URSCompositingEnabled"];
    
    if (self.compositingRequested) {
        NSLog(@"[WindowManager] Compositing requested - will attempt to initialize");
    } else {
        NSLog(@"[WindowManager] Compositing disabled - using direct rendering");
    }

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
    BOOL registered = [self registerAsWindowManager];
    if (!registered) {
        NSLog(@"[WindowManager] Failed to register as WM; terminating");
        [NSApp terminate:nil];
        return;
    }
    
    // Initialize compositing if requested
    if (self.compositingRequested) {
        [self initializeCompositing];
    }

    // Decorate any existing windows already on screen
    [self decorateExistingWindowsOnStartup];

    // Setup XCB event integration with NSRunLoop
    [self setupXCBEventIntegration];

    // Setup simple timer-based theme integration
    [self setupPeriodicThemeIntegration];
    NSLog(@"GSTheme integration initialized with periodic checking enabled");
    
    // Setup keyboard grabbing for Alt-Tab
    [self setupKeyboardGrabbing];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"[WindowManager] Application terminating - performing full cleanup");
    [self cleanupBeforeExit];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    // Keep running even if no windows are visible (window manager behavior)
    return NO;
}

#pragma mark - Compositing Management

- (void)initializeCompositing {
    NSLog(@"[WindowManager] ================================================");
    NSLog(@"[WindowManager] Initializing XRender compositing (experimental)");
    NSLog(@"[WindowManager] ================================================");
    
    @try {
        // Create compositing manager singleton
        self.compositingManager = [URSCompositingManager sharedManager];
        
        // Initialize with our XCB connection
        BOOL initialized = [self.compositingManager initializeWithConnection:self.connection];
        
        if (!initialized) {
            NSLog(@"[WindowManager] ⚠️  Compositing initialization failed");
            NSLog(@"[WindowManager] ⚠️  Falling back to direct rendering (traditional mode)");
            NSLog(@"[WindowManager] ⚠️  Windows will render normally without compositing");
            self.compositingManager = nil;
            return;
        }
        
        // Attempt to activate compositing
        BOOL activated = [self.compositingManager activateCompositing];
        
        if (!activated) {
            NSLog(@"[WindowManager] ⚠️  Compositing activation failed");
            NSLog(@"[WindowManager] ⚠️  Falling back to direct rendering (traditional mode)");
            NSLog(@"[WindowManager] ⚠️  Windows will render normally without compositing");
            [self.compositingManager cleanup];
            self.compositingManager = nil;
            return;
        }
        
        NSLog(@"[WindowManager] ✓ Compositing successfully activated!");
        NSLog(@"[WindowManager] ✓ Windows will use XRender for transparency effects");
        NSLog(@"[WindowManager] ================================================");
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] ❌ EXCEPTION initializing compositing: %@", exception.reason);
        NSLog(@"[WindowManager] ❌ Falling back to non-compositing mode");
        if (self.compositingManager) {
            [self.compositingManager cleanup];
            self.compositingManager = nil;
        }
    }
}

#pragma mark - Original URSEventHandler Methods (Preserved)

- (BOOL)registerAsWindowManager
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

    NSLog(@"[WindowManager] Attempting to become WM (replace existing if needed)...");
    BOOL registered = [connection registerAsWindowManager:YES screenId:0 selectionWindow:selectionManagerWindow];

    if (!registered) {
        NSLog(@"[WindowManager] Existing WM detected; trying to replace it");
        registered = [connection registerAsWindowManager:NO screenId:0 selectionWindow:selectionManagerWindow];
    }

    if (!registered) {
        NSLog(@"[WindowManager] Could not acquire WM ownership even after replace attempt");
        return NO;
    }

    NSLog(@"[WindowManager] Successfully registered as window manager");

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    [ewmhService putPropertiesForRootWindow:[screen rootWindow] andWmWindow:selectionManagerWindow];
    
    // Set initial workarea to full screen (no struts yet)
    [ewmhService updateWorkareaForRootWindow:[screen rootWindow] 
                                           x:0 
                                           y:0 
                                       width:[screen screen]->width_in_pixels 
                                      height:[screen screen]->height_in_pixels];
    
    [connection flush];

    // ARC handles cleanup automatically
    return YES;
}

#pragma mark - Existing Windows Decoration

- (void)decorateExistingWindowsOnStartup {
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [screen rootWindow];
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];

        XCBQueryTreeReply *tree = [rootWindow queryTree];
        xcb_window_t *children = [tree queryTreeAsArray];
        uint32_t childCount = tree.childrenLen;

        NSLog(@"[WindowManager] Decorating %u pre-existing windows", childCount);

        for (uint32_t i = 0; i < childCount; i++) {
            xcb_window_t winId = children[i];

            // Skip our own helper/selection window and root
            if (winId == [rootWindow window] || winId == [self.selectionManagerWindow window]) {
                continue;
            }

            XCBWindow *win = [[XCBWindow alloc] initWithXCBWindow:winId andConnection:connection];
            [win updateAttributes];
            XCBAttributesReply *attrs = [win attributes];

            if (!attrs) {
                NSLog(@"[WindowManager] Skipping window %u (no attributes)", winId);
                continue;
            }

            // Ignore override-redirect windows for decoration
            if (attrs.overrideRedirect) {
                NSLog(@"[WindowManager] Skipping window %u (override-redirect)", winId);
                continue;
            }

            if (attrs.mapState != XCB_MAP_STATE_VIEWABLE) {
                NSLog(@"[WindowManager] Skipping window %u (mapState %u)", winId, attrs.mapState);
                continue;
            }
            
            // Check if this is a dock window with struts - scan for struts even if already managed
            if ([ewmhService isWindowTypeDock:win]) {
                NSLog(@"[WindowManager] Found dock window %u at startup - checking for struts", winId);
                [self readAndRegisterStrutForWindow:winId];
            }

            // Skip already-managed windows
            if ([connection windowForXCBId:winId]) {
                NSLog(@"[WindowManager] Window %u already managed; skipping", winId);
                continue;
            }

            NSLog(@"[WindowManager] Adopting existing window %u", winId);

            // Synthesize a map request so normal decoration flow runs
            xcb_map_request_event_t mapEvent = {0};
            mapEvent.response_type = XCB_MAP_REQUEST;
            mapEvent.parent = [rootWindow window];
            mapEvent.window = winId;

            [connection handleMapRequest:&mapEvent];
        }

        [connection flush];
        
        // Recalculate workarea after scanning all existing windows for struts
        [self recalculateWorkarea];
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception while decorating existing windows: %@", exception.reason);
    }
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
    const NSUInteger maxEventsPerCall = 50; // Limit to prevent CPU hogging
    BOOL moreEventsAvailable = NO;

    // Use xcb_poll_for_event (non-blocking) instead of xcb_wait_for_event (blocking)
    while ((e = xcb_poll_for_event([connection connection])) &&
           eventsProcessed < maxEventsPerCall) {
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
                // STEP 1: Clear background pixmap BEFORE resize to prevent X11 tiling
                [self clearTitlebarBackgroundBeforeResize:lastMotionEvent];
                // STEP 2: Let xcbkit resize the windows
                [connection handleMotionNotify:lastMotionEvent];
                // STEP 3: Render new content and set as background
                [self handleResizeDuringMotion:lastMotionEvent];
                // STEP 4: Update compositor for drag or resize (immediate update for responsiveness)
                [self handleCompositingDuringMotion:lastMotionEvent];
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
    
    // CRITICAL: If compositor has pending damage, flush it immediately
    // This ensures cursor blinking and rapid updates are displayed without delay
    if (self.compositingManager && [self.compositingManager compositingActive]) {
        [self.compositingManager performRepairNow];
    }

    // If we hit the event limit, assume more events may be available
    // Don't poll again here as both xcb_poll_for_event and xcb_poll_for_queued_event
    // remove events from the queue, which would cause lost events
    if (eventsProcessed >= maxEventsPerCall) {
        moreEventsAvailable = YES;
    }

    // Update event statistics
    self.eventCount += eventsProcessed;

    // If we hit the limit and there are more events, reschedule processing
    // This prevents CPU hogging while maintaining responsiveness
    if (eventsProcessed >= maxEventsPerCall && moreEventsAvailable) {
        [self performSelector:@selector(processAvailableXCBEvents)
                   withObject:nil
                   afterDelay:0.001]; // Very short delay to yield CPU
    }

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

            // Trigger compositor update for the exposed window
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                // BUGFIX: Handle expose event to force NameWindowPixmap recreation.
                // This fixes corruption with fixed-size windows (like About dialogs)
                // that don't redraw themselves when exposed after being obscured.
                [self.compositingManager handleExposeEvent:exposeEvent->window];

                // Update the specific window that was exposed for efficient redraw
                [self.compositingManager updateWindow:exposeEvent->window];
                // Force immediate repair for expose events (e.g., cursor blinking)
                // Only on the final expose event in a sequence (count == 0)
                if (exposeEvent->count == 0) {
                    [self.compositingManager performRepairNow];
                }
            }
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
            NSLog(@"XCB_FOCUS_IN received for window %u", focusInEvent->event);
            [connection handleFocusIn:focusInEvent];
            // Re-render titlebar with GSTheme as active
            [self handleFocusChange:focusInEvent->event isActive:YES];
            
            // Focus change typically means stacking order changed (window raised)
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager markStackingOrderDirty];
            }
            break;
        }
        case XCB_FOCUS_OUT: {
            xcb_focus_out_event_t *focusOutEvent = (xcb_focus_out_event_t *)event;
            NSLog(@"XCB_FOCUS_OUT received for window %u", focusOutEvent->event);
            [connection handleFocusOut:focusOutEvent];
            // Re-render titlebar with GSTheme as inactive
            [self handleFocusChange:focusOutEvent->event isActive:NO];
            break;
        }
        case XCB_BUTTON_PRESS: {
            xcb_button_press_event_t *pressEvent = (xcb_button_press_event_t *)event;
            NSLog(@"EVENT: XCB_BUTTON_PRESS received for window %u at (%d, %d)",
                  pressEvent->event, pressEvent->event_x, pressEvent->event_y);
            // Check if this is a button click on a GSThemeTitleBar
            if (![self handleTitlebarButtonPress:pressEvent]) {
                // Not a titlebar button, let xcbkit handle normally
                // This follows the complete XCBKit activation path:
                // 1. Focus the client window (WM_TAKE_FOCUS, _NET_ACTIVE_WINDOW, ungrab keyboard)
                // 2. Raise the frame
                // 3. Update titlebar states (active/inactive for all windows)
                [connection handleButtonPress:pressEvent];
            }
            
            // Button press typically raises the window (changes stacking order)
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager markStackingOrderDirty];
            }
            break;
        }
        case XCB_BUTTON_RELEASE: {
            xcb_button_release_event_t *releaseEvent = (xcb_button_release_event_t *)event;
            // Let xcbkit handle the release first
            [connection handleButtonRelease:releaseEvent];
            // After resize completes, update the titlebar with GSTheme
            [self handleResizeComplete:releaseEvent];

            // If this was a move/drag end on a titlebar or frame, refresh compositor pixmap
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                XCBWindow *releasedWindow = [connection windowForXCBId:releaseEvent->event];
                XCBFrame *frame = nil;
                if ([releasedWindow isKindOfClass:[XCBFrame class]]) {
                    frame = (XCBFrame *)releasedWindow;
                } else if ([releasedWindow isKindOfClass:[XCBTitleBar class]]) {
                    frame = (XCBFrame *)[releasedWindow parentWindow];
                } else if ([releasedWindow parentWindow] && [[releasedWindow parentWindow] isKindOfClass:[XCBFrame class]]) {
                    frame = (XCBFrame *)[releasedWindow parentWindow];
                }

                if (frame) {
                    [self.compositingManager invalidateWindowPixmap:[frame window]];
                    [self.compositingManager performRepairNow];
                }
            }
            break;
        }
        case XCB_MAP_NOTIFY: {
            xcb_map_notify_event_t *notifyEvent = (xcb_map_notify_event_t *)event;
            [connection handleMapNotify:notifyEvent];
            
            // Notify compositor of map event
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager mapWindow:notifyEvent->window];
                // Track mapped child windows (e.g., GPU/GL subwindows) to receive damage events
                [self registerChildWindowsForCompositor:notifyEvent->window depth:2];
            }
            break;
        }
        case XCB_MAP_REQUEST: {
            xcb_map_request_event_t *mapRequestEvent = (xcb_map_request_event_t *)event;

            // Check if this is a dock window with struts
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
            XCBWindow *tempWindow = [[XCBWindow alloc] initWithXCBWindow:mapRequestEvent->window andConnection:connection];
            if ([ewmhService isWindowTypeDock:tempWindow]) {
                NSLog(@"[WindowManager] Dock window %u being mapped - checking for struts", mapRequestEvent->window);
                [self readAndRegisterStrutForWindow:mapRequestEvent->window];
                [self recalculateWorkarea];
            }
            tempWindow = nil;
            ewmhService = nil;

            // Resize window to 70% of screen size before mapping
            [self resizeWindowTo70Percent:mapRequestEvent->window];

            // Let XCBConnection handle the map request normally (this creates titlebar structure)
            [connection handleMapRequest:mapRequestEvent];

            // Register window with compositor if active
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                NSLog(@"[HybridEventHandler] Registering window %u with compositor (compositingActive=%d)", mapRequestEvent->window, (int)[self.compositingManager compositingActive]);
                [self.compositingManager registerWindow:mapRequestEvent->window];
                NSLog(@"[HybridEventHandler] Registered client window %u", mapRequestEvent->window);
                // Register any existing child windows so their damage events are tracked
                [self registerChildWindowsForCompositor:mapRequestEvent->window depth:3];
                // If the client got framed, register children of the frame too
                XCBWindow *clientWindow = [connection windowForXCBId:mapRequestEvent->window];
                if (clientWindow && [[clientWindow parentWindow] isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *frame = (XCBFrame *)[clientWindow parentWindow];
                    NSLog(@"[HybridEventHandler] Registering frame window %u for client %u", [frame window], mapRequestEvent->window);
                    [self.compositingManager registerWindow:[frame window]];
                    [self registerChildWindowsForCompositor:[frame window] depth:3];
                }
            }

            // Hide borders for windows with fixed sizes (like info panels and logout)
            [self adjustBorderForFixedSizeWindow:mapRequestEvent->window];

            // Apply GSTheme immediately with no delay
            [self applyGSThemeToRecentlyMappedWindow:[NSNumber numberWithUnsignedInt:mapRequestEvent->window]];

            // Fallback: Try to focus the client window if it's focusable but GSTheme wasn't applied
            // This ensures dialogs, alerts, sheets and other special windows get focused too
            XCBWindow *clientWindow = [connection windowForXCBId:mapRequestEvent->window];
            if (clientWindow && [self isWindowFocusable:clientWindow allowDesktop:NO]) {
                // Schedule focus after a brief delay to ensure the window is fully set up
                [self performSelector:@selector(focusWindowAfterThemeApplied:)
                           withObject:clientWindow
                           afterDelay:0.1];
            }
            break;
        }
        case XCB_UNMAP_NOTIFY: {
            xcb_unmap_notify_event_t *unmapNotifyEvent = (xcb_unmap_notify_event_t *)event;
            xcb_window_t removedClientId = [self clientWindowIdForWindowId:unmapNotifyEvent->window];
            [connection handleUnMapNotify:unmapNotifyEvent];
            
            // Notify compositor of unmap event
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager unmapWindow:unmapNotifyEvent->window];
            }

            [self ensureFocusAfterWindowRemovalOfClientWindow:removedClientId];
            break;
        }
        case XCB_DESTROY_NOTIFY: {
            xcb_destroy_notify_event_t *destroyNotify = (xcb_destroy_notify_event_t *)event;
            xcb_window_t removedClientId = [self clientWindowIdForWindowId:destroyNotify->window];
            
            // Unregister window from compositor before connection handles destroy
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager unregisterWindow:destroyNotify->window];
            }
            
            // Remove any struts for this window
            [self removeStrutForWindow:destroyNotify->window];
            // Check if strut removal requires workarea recalculation
            if ([self.windowStruts count] > 0 || [[self.windowStruts allKeys] count] == 0) {
                [self recalculateWorkarea];
            }
            
            [connection handleDestroyNotify:destroyNotify];
            [self ensureFocusAfterWindowRemovalOfClientWindow:removedClientId];
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
        case XCB_CREATE_NOTIFY: {
            xcb_create_notify_event_t *createNotify = (xcb_create_notify_event_t *)event;
            [connection handleCreateNotify:createNotify];
            // Track newly created child windows for damage (e.g., GL subwindows)
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager registerWindow:createNotify->window];
                [self registerChildWindowsForCompositor:createNotify->window depth:2];
            }
            break;
        }
        case XCB_CONFIGURE_NOTIFY: {
            xcb_configure_notify_event_t *configureNotify = (xcb_configure_notify_event_t *)event;
            [connection handleConfigureNotify:configureNotify];
            
            // Notify compositor of window resize/move
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager resizeWindow:configureNotify->window 
                                                    x:configureNotify->x
                                                    y:configureNotify->y
                                                width:configureNotify->width
                                               height:configureNotify->height];
                // Stacking can also change via ConfigureNotify (stack mode), ensure repaint
                [self.compositingManager markStackingOrderDirty];
            }
            break;
        }
        case XCB_REPARENT_NOTIFY: {
            xcb_reparent_notify_event_t *reparentNotify = (xcb_reparent_notify_event_t *)event;
            [connection handleReparentNotify:reparentNotify];

            if (self.compositingManager && [self.compositingManager compositingActive]) {
                // Re-register to refresh parent/geometry and avoid stale artifacts
                [self.compositingManager unregisterWindow:reparentNotify->window];
                [self.compositingManager registerWindow:reparentNotify->window];
                [self.compositingManager scheduleComposite];
            }
            break;
        }
        case XCB_PROPERTY_NOTIFY: {
            xcb_property_notify_event_t *propEvent = (xcb_property_notify_event_t *)event;
            // Check if this is a strut property change
            [self handleStrutPropertyChange:propEvent];
            [self handleWindowTitlePropertyChange:propEvent];
            [connection handlePropertyNotify:propEvent];
            break;
        }
        case XCB_KEY_PRESS: {
            xcb_key_press_event_t *keyPressEvent = (xcb_key_press_event_t *)event;
            [self handleKeyPressEvent:keyPressEvent];
            break;
        }
        case XCB_KEY_RELEASE: {
            xcb_key_release_event_t *keyReleaseEvent = (xcb_key_release_event_t *)event;
            [self handleKeyReleaseEvent:keyReleaseEvent];
            break;
        }
        case XCB_SELECTION_CLEAR: {
            xcb_selection_clear_event_t *selectionClearEvent = (xcb_selection_clear_event_t *)event;
            [self handleSelectionClear:selectionClearEvent];
            break;
        }
        default: {
            // Check for extension events (damage, etc.)
            // Only log truly unhandled events (not damage events)
            uint8_t responseType = event->response_type & ~0x80;
            uint8_t damageBase = self.compositingManager ? [self.compositingManager damageEventBase] : 0;
            if (responseType > 64 && responseType != damageBase) { // Extension events except DAMAGE
                NSLog(@"[Event] Unhandled extension event: response_type=%u", responseType);
            }
            [self handleExtensionEvent:event];
            break;
        }
    }
}

- (void)registerChildWindowsForCompositor:(xcb_window_t)parentWindow depth:(NSUInteger)depth
{
    if (!self.compositingManager || ![self.compositingManager compositingActive]) {
        return;
    }
    if (depth == 0 || parentWindow == XCB_NONE) {
        return;
    }

    xcb_connection_t *xcbConn = [connection connection];
    xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(xcbConn, parentWindow);
    xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(xcbConn, tree_cookie, NULL);
    if (!tree_reply) {
        return;
    }

    xcb_window_t *children = xcb_query_tree_children(tree_reply);
    int num_children = xcb_query_tree_children_length(tree_reply);

    for (int i = 0; i < num_children; i++) {
        xcb_window_t child = children[i];
        [self.compositingManager registerWindow:child];
        [self registerChildWindowsForCompositor:child depth:depth - 1];
    }

    free(tree_reply);
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
        case XCB_SELECTION_CLEAR:
            return YES;
        default:
            return NO;
    }
}

- (void)handleExtensionEvent:(xcb_generic_event_t*)event
{
    // Handle extension events (DAMAGE, etc.)
    if (!self.compositingManager) {
        return;
    }
    
    uint8_t responseType = event->response_type & ~0x80;
    uint8_t damageEventBase = [self.compositingManager damageEventBase];
    
    // DAMAGE notify events are at base_event + XCB_DAMAGE_NOTIFY (0)
    // Check if this is a DAMAGE event
    if (responseType == damageEventBase + XCB_DAMAGE_NOTIFY) {
        // This is a DAMAGE notify event
        xcb_damage_notify_event_t *damageEvent = (xcb_damage_notify_event_t *)event;
        
        // The drawable field contains the window that was damaged
        [self.compositingManager handleDamageNotify:damageEvent->drawable];
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

- (void)handleFocusChange:(xcb_window_t)windowId isActive:(BOOL)isActive {
    @try {
        NSLog(@"handleFocusChange: window %u, isActive: %d", windowId, isActive);

        // Find the window that received focus change
        XCBWindow *window = [connection windowForXCBId:windowId];
        if (!window) {
            NSLog(@"handleFocusChange: window %u not found in windowsMap, searching for frame containing it", windowId);
            // The focus event might be for a client window - search all frames
            NSDictionary *windowsMap = [connection windowsMap];
            for (NSString *mapWindowId in windowsMap) {
                XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
                if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *testFrame = (XCBFrame*)mapWindow;
                    XCBWindow *clientWindow = [testFrame childWindowForKey:ClientWindow];
                    if (clientWindow && [clientWindow window] == windowId) {
                        NSLog(@"handleFocusChange: Found frame containing client window %u", windowId);
                        window = testFrame;
                        break;
                    }
                }
            }
            if (!window) {
                NSLog(@"handleFocusChange: Could not find any frame for window %u", windowId);
                return;
            }
        }

        NSLog(@"handleFocusChange: Found window of type %@", NSStringFromClass([window class]));

        // Find the frame and titlebar
        XCBFrame *frame = nil;
        XCBTitleBar *titlebar = nil;

        if ([window isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame*)window;
        } else if ([window isKindOfClass:[XCBTitleBar class]]) {
            titlebar = (XCBTitleBar*)window;
            frame = (XCBFrame*)[titlebar parentWindow];
        } else if ([window parentWindow] && [[window parentWindow] isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame*)[window parentWindow];
        }

        if (frame) {
            XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
            if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
                titlebar = (XCBTitleBar*)titlebarWindow;
            }
        }

        if (!titlebar) {
            NSLog(@"handleFocusChange: No titlebar found for window %u", windowId);
            return;
        }

        NSLog(@"GSTheme: Focus %@ for window %@", isActive ? @"gained" : @"lost", titlebar.windowTitle);

        if (isActive) {
            XCBWindow *clientWindow = [self clientWindowForWindow:window fallbackFrame:frame];
            if (clientWindow) {
                xcb_window_t clientId = [clientWindow window];
                if (clientId != XCB_NONE && clientId != self.lastFocusedWindowId) {
                    self.previousFocusedWindowId = self.lastFocusedWindowId;
                    self.lastFocusedWindowId = clientId;
                }
            }
        }

        // Re-render titlebar with GSTheme using the correct active/inactive state
        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:[titlebar windowTitle]
                                            active:isActive];

        // Update background pixmap and redraw
        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];
        [connection flush];
        
        // Notify compositor about the titlebar content change
        if (self.compositingManager && [self.compositingManager compositingActive]) {
            [self.compositingManager updateWindow:[frame window]];
            // Mark stacking order dirty since focused windows are typically raised
            [self.compositingManager markStackingOrderDirty];
        }

    } @catch (NSException *exception) {
        NSLog(@"Exception in handleFocusChange: %@", exception.reason);
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
                // Find the frame by checking the titlebar's parent window
                XCBWindow *parentWindow = [titlebar parentWindow];
                XCBFrame *frame = nil;
                
                if (parentWindow && [parentWindow isKindOfClass:[XCBFrame class]]) {
                    frame = (XCBFrame*)parentWindow;
                }

                if (frame) {
                    NSLog(@"Titlebar %u exposed, re-applying GSTheme", exposedWindow);

                    // Re-apply GSTheme rendering to override the expose redraw
                    [URSThemeIntegration renderGSThemeToWindow:frame
                                                         frame:frame
                                                         title:titlebar.windowTitle
                                                        active:YES];
                    
                    // Notify compositor about the content change (updateWindow already called in XCB_EXPOSE handler)
                }
                break;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in titlebar expose handler: %@", exception.reason);
    }
}

- (void)adjustBorderForFixedSizeWindow:(xcb_window_t)clientWindowId {
    @try {
        // Check if window has fixed size (min == max in WM_NORMAL_HINTS)
        xcb_size_hints_t sizeHints;
        if (xcb_icccm_get_wm_normal_hints_reply([connection connection],
                                                 xcb_icccm_get_wm_normal_hints([connection connection], clientWindowId),
                                                 &sizeHints,
                                                 NULL)) {
            if ((sizeHints.flags & XCB_ICCCM_SIZE_HINT_P_MIN_SIZE) &&
                (sizeHints.flags & XCB_ICCCM_SIZE_HINT_P_MAX_SIZE) &&
                sizeHints.min_width == sizeHints.max_width &&
                sizeHints.min_height == sizeHints.max_height) {

                NSLog(@"Fixed-size window %u detected - removing border and extra buttons", clientWindowId);

                // Register as fixed-size window (for button hiding in GSTheme rendering)
                [URSThemeIntegration registerFixedSizeWindow:clientWindowId];

                // Find the frame for this client window and set its border to 0
                NSDictionary *windowsMap = [connection windowsMap];
                for (NSString *mapWindowId in windowsMap) {
                    XCBWindow *window = [windowsMap objectForKey:mapWindowId];

                    if (window && [window isKindOfClass:[XCBFrame class]]) {
                        XCBFrame *frame = (XCBFrame*)window;
                        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];

                        if (clientWindow && [clientWindow window] == clientWindowId) {
                            // Set the frame's border width to 0
                            uint32_t borderWidth[] = {0};
                            xcb_configure_window([connection connection],
                                                 [frame window],
                                                 XCB_CONFIG_WINDOW_BORDER_WIDTH,
                                                 borderWidth);
                            [connection flush];
                            NSLog(@"Removed border from frame %u for fixed-size window %u", [frame window], clientWindowId);
                            return;
                        }
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in adjustBorderForFixedSizeWindow: %@", exception.reason);
    }
}

- (void)resizeWindowTo70Percent:(xcb_window_t)clientWindowId {
    @try {
        // Get the screen dimensions
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        uint16_t screenWidth = [screen width];
        uint16_t screenHeight = [screen height];
        
        // Get the current workarea (respects struts from dock windows like menu bar)
        NSRect workarea = [self currentWorkarea];
        
        // Calculate 70% of workarea size (not screen size - respects struts)
        uint16_t newWidth = (uint16_t)(workarea.size.width * 0.7);
        uint16_t newHeight = (uint16_t)(workarea.size.height * 0.7);
        
        // Golden ratio positioning (0.618) within the workarea
        // Position window at (1 - φ) ≈ 0.382 to lean left and top
        uint16_t goldenPosX = (uint16_t)(workarea.origin.x + workarea.size.width * 0.382);
        uint16_t goldenPosY = (uint16_t)(workarea.origin.y + workarea.size.height * 0.382);
        
        // Get current geometry to check if resizing is needed
        xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry([connection connection], clientWindowId);
        xcb_get_geometry_reply_t *geom_reply = xcb_get_geometry_reply([connection connection], geom_cookie, NULL);
        
        if (geom_reply) {
            // Check if window is desktop or explicitly fullscreen - skip WM defaults for these
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
            
            // Create an XCBWindow object from the xcb_window_t for EWMH queries
            XCBWindow *queryWindow = [[XCBWindow alloc] initWithXCBWindow:clientWindowId andConnection:connection];
            
            // Check window type
            void *windowTypeReply = [ewmhService getProperty:[ewmhService EWMHWMWindowType]
                                                propertyType:XCB_ATOM_ATOM
                                                   forWindow:queryWindow
                                                      delete:NO
                                                      length:1];
            
            BOOL isDesktopWindow = NO;
            if (windowTypeReply) {
                xcb_atom_t *atom = (xcb_atom_t *) xcb_get_property_value(windowTypeReply);
                if (atom && *atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDesktop]]) {
                    isDesktopWindow = YES;
                }
                free(windowTypeReply);
            }
            
            // Check if window has fullscreen state
            BOOL isFullscreenState = NO;
            void *stateReply = [ewmhService getProperty:[ewmhService EWMHWMState]
                                           propertyType:XCB_ATOM_ATOM
                                              forWindow:queryWindow
                                                 delete:NO
                                                 length:UINT32_MAX];
            
            if (stateReply) {
                xcb_atom_t *atoms = (xcb_atom_t *) xcb_get_property_value(stateReply);
                uint32_t length = xcb_get_property_value_length(stateReply);
                xcb_atom_t fullscreenAtom = [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMStateFullscreen]];
                
                for (uint32_t i = 0; i < length; i++) {
                    if (atoms[i] == fullscreenAtom) {
                        isFullscreenState = YES;
                        break;
                    }
                }
                free(stateReply);
            }
            
            queryWindow = nil;
            // Only apply WM defaults (70% + golden ratio) if:
            // 1. Window is positioned at (0,0) - indicates no app positioning
            // 2. AND window is full screen - indicates no app size constraints
            // 3. AND window is not a desktop window
            // 4. AND window is not explicitly requesting fullscreen
            BOOL isAtOrigin = (geom_reply->x == 0 && geom_reply->y == 0);
            BOOL isFullScreenSize = (geom_reply->width >= screenWidth && geom_reply->height >= screenHeight);
            
            if (isAtOrigin && isFullScreenSize && !isDesktopWindow && !isFullscreenState) {
                NSLog(@"Window %u has no app-determined geometry (at 0,0 with full screen). Applying WM defaults: 70%% of workarea at golden ratio position",
                      clientWindowId);
                NSLog(@"[ICCCM] Workarea constraints: origin=(%.0f,%.0f) size=(%.0f x %.0f)",
                      workarea.origin.x, workarea.origin.y, workarea.size.width, workarea.size.height);
                
                // Resize and position the window using WM defaults (within workarea)
                uint32_t configValues[] = {goldenPosX, goldenPosY, newWidth, newHeight};
                xcb_configure_window([connection connection],
                                     clientWindowId,
                                     XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y | 
                                     XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                                     configValues);
                [connection flush];
            } else if (isDesktopWindow || isFullscreenState) {
                NSLog(@"Window %u is desktop or fullscreen window. Skipping WM defaults (isDesktop=%d, isFullscreen=%d)",
                      clientWindowId, isDesktopWindow, isFullscreenState);
            } else {
                NSLog(@"Window %u has app-determined geometry (%ux%u at %d,%d). Respecting app preferences",
                      clientWindowId, geom_reply->width, geom_reply->height, geom_reply->x, geom_reply->y);
            }
            free(geom_reply);
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in resizeWindowTo70Percent: %@", exception.reason);
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
                            
                            // Notify compositor about the new window content
                            if (self.compositingManager && [self.compositingManager compositingActive]) {
                                [self.compositingManager updateWindow:[frame window]];
                            }

                            // Auto-focus the client window - the frame and titlebar are now fully set up
                            // Focus after a small delay to ensure the window is properly rendered and ready
                            [self performSelector:@selector(focusWindowAfterThemeApplied:)
                                       withObject:clientWindow
                                       afterDelay:0.1];

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

        // If we couldn't find a frame, the window may be undecorated (dialogs, alerts, sheets).
        // Attempt a direct focus on the client window as a fallback.
        XCBWindow *directWindow = [self.connection windowForXCBId:windowId];
        if (directWindow) {
            NSLog(@"[Focus] No frame found for %u; attempting direct focus on window %u", windowId, [directWindow window]);
            if ([self isWindowFocusable:directWindow allowDesktop:NO]) {
                [self performSelector:@selector(focusWindowAfterThemeApplied:)
                           withObject:directWindow
                           afterDelay:0.1];
                return;
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
                    
                    // Notify compositor about the content change
                    if (self.compositingManager && [self.compositingManager compositingActive]) {
                        [self.compositingManager updateWindow:[frame window]];
                    }
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

#pragma mark - Resize Handling

- (void)clearTitlebarBackgroundBeforeResize:(xcb_motion_notify_event_t*)motionEvent {
    @try {
        // Find the frame
        XCBWindow *window = [connection windowForXCBId:motionEvent->event];
        if (!window || ![window isKindOfClass:[XCBFrame class]]) {
            return;
        }
        XCBFrame *frame = (XCBFrame*)window;

        // Get the titlebar
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }

        // Set background to NONE to prevent X11 from tiling the old pixmap
        // XCB_BACK_PIXMAP_NONE = 0
        uint32_t value = 0; // XCB_BACK_PIXMAP_NONE
        xcb_change_window_attributes([connection connection],
                                     [titlebarWindow window],
                                     XCB_CW_BACK_PIXMAP,
                                     &value);
    } @catch (NSException *exception) {
        // Silently ignore
    }
}

- (void)handleResizeDuringMotion:(xcb_motion_notify_event_t*)motionEvent {
    @try {
        // Find the window involved in the motion
        XCBWindow *window = [connection windowForXCBId:motionEvent->event];
        if (!window) {
            return;
        }

        // Check if it's a frame (resize happens on frames)
        XCBFrame *frame = nil;
        if ([window isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame*)window;
        }

        if (!frame) {
            return;
        }

        // Get the titlebar
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

        // After xcbkit processes motion, windowRect is updated with new size
        XCBRect titlebarRect = [titlebar windowRect];
        XCBSize pixmapSize = [titlebar pixmapSize];

        // Only update if the size has changed
        if (pixmapSize.width != titlebarRect.size.width) {
            // Recreate the titlebar pixmap at the new size
            [titlebar destroyPixmap];
            [titlebar createPixmap];

            // Redraw with GSTheme
            [URSThemeIntegration renderGSThemeToWindow:frame
                                                 frame:frame
                                                 title:[titlebar windowTitle]
                                                active:YES];

            // Update the window background pixmap to prevent X11 tiling
            // This is the key fix - xcbkit sets a background pixmap which X11 tiles
            // when the window is larger than the pixmap
            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];

            // Copy the pixmap to the window immediately
            [titlebar drawArea:titlebarRect];

            [connection flush];
            
            // Notify compositor about the window content change
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager updateWindow:[frame window]];
            }
        }
    } @catch (NSException *exception) {
        // Silently ignore exceptions during resize motion to avoid spam
    }
}

// Handle compositor updates during window drag or resize
- (void)handleCompositingDuringMotion:(xcb_motion_notify_event_t*)motionEvent {
    if (!self.compositingManager || ![self.compositingManager compositingActive]) {
        return;
    }
    
    @try {
        // Check if this is a drag operation (window being moved)
        if ([connection dragState]) {
            // Find the titlebar being dragged
            XCBWindow *window = [connection windowForXCBId:motionEvent->event];
            if (!window || ![window isKindOfClass:[XCBTitleBar class]]) {
                return;
            }
            
            XCBFrame *frame = (XCBFrame*)[window parentWindow];
            if (!frame || ![frame isKindOfClass:[XCBFrame class]]) {
                return;
            }
            
            // Get the frame's current position (after moveTo: was called)
            XCBRect frameRect = [frame windowRect];
            
            // Notify compositor of window move (efficient - doesn't recreate picture)
            [self.compositingManager moveWindow:[frame window] 
                                              x:frameRect.position.x 
                                              y:frameRect.position.y];
            
            // Perform immediate repair during drag for responsive visual feedback
            [self.compositingManager performRepairNow];
        } else if ([connection resizeState]) {
            // Resize case - already handled by handleResizeDuringMotion, but ensure compositor updates
            XCBWindow *window = [connection windowForXCBId:motionEvent->event];
            XCBFrame *frame = nil;
            
            if ([window isKindOfClass:[XCBFrame class]]) {
                frame = (XCBFrame*)window;
            }
            
            if (frame) {
                XCBRect frameRect = [frame windowRect];
                [self.compositingManager resizeWindow:[frame window]
                                                    x:frameRect.position.x
                                                    y:frameRect.position.y
                                                width:frameRect.size.width
                                               height:frameRect.size.height];
                
                // Perform immediate repair during resize for responsive visual feedback
                [self.compositingManager performRepairNow];
            }
        }
    } @catch (NSException *exception) {
        // Silently ignore exceptions during motion to avoid spam
    }
}

- (void)handleResizeComplete:(xcb_button_release_event_t*)releaseEvent {
    @try {
        // Find the window that was released
        XCBWindow *window = [connection windowForXCBId:releaseEvent->event];
        if (!window) {
            return;
        }

        // Check if it's a frame (resize happens on frames)
        XCBFrame *frame = nil;
        if ([window isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame*)window;
        } else if ([window parentWindow] && [[window parentWindow] isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame*)[window parentWindow];
        }

        if (!frame) {
            return;
        }

        // Get the titlebar
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

        // Check if the titlebar size has changed (compare pixmap size to window rect)
        XCBRect titlebarRect = [titlebar windowRect];
        XCBSize pixmapSize = [titlebar pixmapSize];

        if (pixmapSize.width != titlebarRect.size.width ||
            pixmapSize.height != titlebarRect.size.height) {
            NSLog(@"GSTheme: Titlebar size changed from %dx%d to %dx%d, recreating pixmap",
                  pixmapSize.width, pixmapSize.height,
                  titlebarRect.size.width, titlebarRect.size.height);

            // Recreate the titlebar pixmap at the new size
            [titlebar destroyPixmap];
            [titlebar createPixmap];

            // Redraw with GSTheme
            [URSThemeIntegration renderGSThemeToWindow:frame
                                                 frame:frame
                                                 title:[titlebar windowTitle]
                                                active:YES];

            // Update the window background pixmap to prevent X11 tiling
            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];

            // Copy the pixmap to the window
            XCBRect titleRect = [titlebar windowRect];
            [titlebar drawArea:titleRect];

            [connection flush];
            
            // Notify compositor about the window content change
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager updateWindow:[frame window]];
            }
            NSLog(@"GSTheme: Titlebar redrawn after resize");
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in handleResizeComplete: %@", exception.reason);
    }
}

#pragma mark - Titlebar Button Handling

// Button hit detection for GSTheme-styled titlebars
- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point forTitlebar:(XCBTitleBar*)titlebar {
    // Button layout based on actual visual positions from pixel sampling:
    // Close (red) at x=18, Mini (yellow) at x=37, Zoom (green) at x=56
    // Buttons are 13px wide with ~19px spacing between centers
    // Order is: Close, Miniaturize, Zoom (left to right)
    float buttonSize = 13.0;
    float buttonSpacing = 19.0;  // Actual spacing between button centers
    float topMargin = 4.0;       // Adjusted for better vertical hit detection
    float buttonHeight = 16.0;   // Slightly larger hit area vertically
    float leftMargin = 12.0;     // Close button starts around x=12

    // Define button rects (order: close, miniaturize, zoom - matching visual order)
    NSRect closeRect = NSMakeRect(leftMargin, topMargin, buttonSize, buttonHeight);
    NSRect miniaturizeRect = NSMakeRect(leftMargin + buttonSpacing, topMargin, buttonSize, buttonHeight);
    NSRect zoomRect = NSMakeRect(leftMargin + (2 * buttonSpacing), topMargin, buttonSize, buttonHeight);

    NSLog(@"GSTheme: Button hit test at point (%.0f, %.0f)", point.x, point.y);
    NSLog(@"GSTheme: Close rect: (%.0f, %.0f, %.0f, %.0f)", closeRect.origin.x, closeRect.origin.y, closeRect.size.width, closeRect.size.height);
    NSLog(@"GSTheme: Miniaturize rect: (%.0f, %.0f, %.0f, %.0f)", miniaturizeRect.origin.x, miniaturizeRect.origin.y, miniaturizeRect.size.width, miniaturizeRect.size.height);
    NSLog(@"GSTheme: Zoom rect: (%.0f, %.0f, %.0f, %.0f)", zoomRect.origin.x, zoomRect.origin.y, zoomRect.size.width, zoomRect.size.height);

    // Check which button was clicked (if any)
    if (NSPointInRect(point, closeRect)) {
        NSLog(@"GSTheme: Hit close button");
        return GSThemeTitleBarButtonClose;
    }
    if (NSPointInRect(point, miniaturizeRect)) {
        NSLog(@"GSTheme: Hit miniaturize button");
        return GSThemeTitleBarButtonMiniaturize;
    }
    if (NSPointInRect(point, zoomRect)) {
        NSLog(@"GSTheme: Hit zoom button");
        return GSThemeTitleBarButtonZoom;
    }

    NSLog(@"GSTheme: No button hit");
    return GSThemeTitleBarButtonNone;
}

- (BOOL)handleTitlebarButtonPress:(xcb_button_press_event_t*)pressEvent {
    @try {
        // Find the window that was clicked
        XCBWindow *window = [connection windowForXCBId:pressEvent->event];
        NSLog(@"GSTheme: handleTitlebarButtonPress for window ID %u, window object: %@",
              pressEvent->event, window ? NSStringFromClass([window class]) : @"nil");

        if (!window) {
            NSLog(@"GSTheme: No window found for ID %u", pressEvent->event);
            return NO;
        }

        // Check if it's an XCBTitleBar (GSTheme renders to XCBTitleBar, not a separate class)
        if (![window isKindOfClass:[XCBTitleBar class]]) {
            NSLog(@"GSTheme: Window is not XCBTitleBar, it's %@", NSStringFromClass([window class]));
            return NO;
        }

        XCBTitleBar *titlebar = (XCBTitleBar*)window;
        XCBRect titlebarRect = [titlebar windowRect];
        NSLog(@"GSTheme: Found titlebar, windowRect: %ux%u at (%d,%d), parentWindow: %@",
              (unsigned)titlebarRect.size.width, (unsigned)titlebarRect.size.height,
              (int)titlebarRect.position.x, (int)titlebarRect.position.y,
              [titlebar parentWindow] ? NSStringFromClass([[titlebar parentWindow] class]) : @"nil");

        // CRITICAL: Allow X11 to continue processing events
        // Use ASYNC_POINTER to resume event processing without replaying this event
        // (REPLAY_POINTER would cause double-processing of the click)
        xcb_allow_events([connection connection], XCB_ALLOW_ASYNC_POINTER, pressEvent->time);

        // Check which button was clicked using the button layout
        NSPoint clickPoint = NSMakePoint(pressEvent->event_x, pressEvent->event_y);
        NSLog(@"GSTheme: Click at (%.0f, %.0f)", clickPoint.x, clickPoint.y);
        GSThemeTitleBarButton button = [self buttonAtPoint:clickPoint forTitlebar:titlebar];

        if (button == GSThemeTitleBarButtonNone) {
            return NO; // Click wasn't on a button
        }

        // Find the frame that contains this titlebar
        XCBFrame *frame = (XCBFrame*)[titlebar parentWindow];
        if (!frame || ![frame isKindOfClass:[XCBFrame class]]) {
            NSLog(@"GSTheme: Could not find frame for titlebar button action");
            return NO;
        }

        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];

        // Handle the button action using xcbkit methods
        switch (button) {
            case GSThemeTitleBarButtonClose:
                NSLog(@"GSTheme: Close button clicked");
                if (clientWindow) {
                    [clientWindow close];
                    [frame setNeedDestroy:YES];
                }
                break;

            case GSThemeTitleBarButtonMiniaturize:
                NSLog(@"GSTheme: Minimize button clicked");
                [frame minimize];
                break;

            case GSThemeTitleBarButtonZoom:
                NSLog(@"GSTheme: Zoom button clicked, frame isMaximized: %d", [frame isMaximized]);
                if ([frame isMaximized]) {
                    // Restore from maximized
                    NSLog(@"GSTheme: Restoring window from maximized state");
                    XCBRect startRect = [frame windowRect];
                    XCBRect restoredRect = [frame oldRect];  // Get saved pre-maximize rect

                    // Use programmatic resize that follows the same code path as manual resize
                    [frame programmaticResizeToRect:restoredRect];
                    [frame setFullScreen:NO];
                    [titlebar setFullScreen:NO];
                    if (clientWindow) {
                        [clientWindow setFullScreen:NO];
                    }
                    [frame setIsMaximized:NO];

                    // Recreate the titlebar pixmap at the restored size
                    [titlebar destroyPixmap];
                    [titlebar createPixmap];
                    XCBRect restoredFrameRect = [frame windowRect];
                    uint16_t titleHgt = [titlebar windowRect].size.height;
                    NSLog(@"GSTheme: Titlebar pixmap recreated for restored size %dx%d",
                          restoredFrameRect.size.width, titleHgt);

                    // Redraw titlebar with GSTheme at restored size
                    [URSThemeIntegration renderGSThemeToWindow:frame
                                                         frame:frame
                                                         title:[titlebar windowTitle]
                                                        active:YES];

                    // Update background pixmap and copy to window
                    [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
                    [titlebar drawArea:[titlebar windowRect]];

                    // Update resize zone positions and shape mask for new dimensions
                    [frame updateAllResizeZonePositions];
                    [frame applyRoundedCornersShapeMask];

                    {
                        Class compositorClass = NSClassFromString(@"URSCompositingManager");
                        id compositor = nil;
                        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                            compositor = [compositorClass performSelector:@selector(sharedManager)];
                        }
                        if (compositor && [compositor respondsToSelector:@selector(compositingActive)] &&
                            [compositor compositingActive] &&
                            [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
                            XCBRect endRect = [frame windowRect];
                            [compositor animateWindowTransition:[frame window]
                                                 fromRect:startRect
                                                   toRect:endRect
                                                 duration:0.22
                                                     fade:NO];
                        }
                    }

                    NSLog(@"GSTheme: Restore complete, titlebar redrawn");
                } else {
                    // Maximize to workarea size (respects struts)
                    NSLog(@"GSTheme: Maximizing window");
                    XCBRect startRect = [frame windowRect];

                    /*** Save pre-maximize rect for restore ***/
                    [frame setOldRect:startRect];
                    [titlebar setOldRect:[titlebar windowRect]];
                    if (clientWindow) {
                        [clientWindow setOldRect:[clientWindow windowRect]];
                    }

                    NSRect workarea = [self currentWorkarea];
                    /*** Use programmatic resize that follows the same code path as manual resize ***/
                    XCBRect targetRect = XCBMakeRect(XCBMakePoint((int32_t)workarea.origin.x, (int32_t)workarea.origin.y),
                                                      XCBMakeSize((uint32_t)workarea.size.width, (uint32_t)workarea.size.height));
                    [frame programmaticResizeToRect:targetRect];
                    [frame setFullScreen:YES];
                    [frame setIsMaximized:YES];
                    [titlebar setFullScreen:YES];
                    if (clientWindow) {
                        [clientWindow setFullScreen:YES];
                    }

                    // Recreate the titlebar pixmap at the new size
                    [titlebar destroyPixmap];
                    [titlebar createPixmap];
                    uint16_t titleHgt = [titlebar windowRect].size.height;
                    NSLog(@"GSTheme: Titlebar pixmap recreated for maximized size %dx%d",
                          (uint32_t)workarea.size.width, titleHgt);

                    // Redraw titlebar with GSTheme at new size
                    [URSThemeIntegration renderGSThemeToWindow:frame
                                                         frame:frame
                                                         title:[titlebar windowTitle]
                                                        active:YES];

                    // Update background pixmap and copy to window
                    [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
                    [titlebar drawArea:[titlebar windowRect]];

                    // Update resize zone positions and shape mask for new dimensions
                    [frame updateAllResizeZonePositions];
                    [frame applyRoundedCornersShapeMask];

                    {
                        Class compositorClass = NSClassFromString(@"URSCompositingManager");
                        id compositor = nil;
                        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                            compositor = [compositorClass performSelector:@selector(sharedManager)];
                        }
                        if (compositor && [compositor respondsToSelector:@selector(compositingActive)] &&
                            [compositor compositingActive] &&
                            [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
                            XCBRect endRect = [frame windowRect];
                            [compositor animateWindowTransition:[frame window]
                                                 fromRect:startRect
                                                   toRect:endRect
                                                 duration:0.22
                                                     fade:NO];
                        }
                    }

                    NSLog(@"GSTheme: Maximize complete, titlebar redrawn at new size");
                }
                break;

            default:
                return NO;
        }

        [connection flush];
        return YES; // We handled the button press

    } @catch (NSException *exception) {
        NSLog(@"Exception handling titlebar button press: %@", exception.reason);
        return NO;
    }
}

#pragma mark - Focus Change Rendering

- (void)rerenderTitlebarForFrame:(XCBFrame*)frame active:(BOOL)isActive {
    if (!frame) {
        return;
    }

    @try {
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

        NSLog(@"Rerendering titlebar '%@' as %@", titlebar.windowTitle, isActive ? @"active" : @"inactive");

        // Render with GSTheme
        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:[titlebar windowTitle]
                                            active:isActive];

        // Update background pixmap and redraw
        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];
        [connection flush];

    } @catch (NSException *exception) {
        NSLog(@"Exception in rerenderTitlebarForFrame: %@", exception.reason);
    }
}

#pragma mark - Keyboard Event Handling (Alt-Tab)

- (void)cleanupKeyboardGrabbing {
    NSLog(@"[Alt-Tab] Cleaning up keyboard grabbing");
    
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        xcb_window_t root = [[screen rootWindow] window];
        xcb_connection_t *conn = [connection connection];
        
        // Ungrab all key combinations we previously grabbed
        // We need to ungrab both Alt+Tab and Shift+Alt+Tab
        
        // Get the keyboard mapping to find Tab key (same as in setup)
        xcb_get_keyboard_mapping_cookie_t cookie = xcb_get_keyboard_mapping(
            conn,
            8,   // min_keycode
            248  // count (255 - 8 + 1)
        );
        
        xcb_get_keyboard_mapping_reply_t *reply = xcb_get_keyboard_mapping_reply(conn, cookie, NULL);
        if (!reply) {
            NSLog(@"[Alt-Tab] Warning: Failed to get keyboard mapping during cleanup");
            // Fallback ungrab with common Tab keycode
            xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1);
            xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT);
            [connection flush];
            return;
        }
        
        xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
        int keysyms_len = xcb_get_keyboard_mapping_keysyms_length(reply);
        
        // Find Tab key and ungrab it
        BOOL tabFound = NO;
        for (int i = 0; i < keysyms_len; i++) {
            if (keysyms[i] == XK_Tab) {
                xcb_keycode_t keycode = 8 + (i / reply->keysyms_per_keycode);
                
                NSLog(@"[Alt-Tab] Ungrabbing Tab key at keycode %d", keycode);
                
                // Ungrab Alt+Tab
                xcb_ungrab_key(conn, keycode, root, XCB_MOD_MASK_1);
                
                // Ungrab Shift+Alt+Tab
                xcb_ungrab_key(conn, keycode, root, XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT);
                
                tabFound = YES;
                break;
            }
        }
        
        if (!tabFound) {
            NSLog(@"[Alt-Tab] Using fallback keycode 23 for ungrab");
            xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1);
            xcb_ungrab_key(conn, 23, root, XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT);
        }
        
        free(reply);
        [connection flush];
        NSLog(@"[Alt-Tab] Successfully ungrabbed keyboard");
        
    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in cleanupKeyboardGrabbing: %@", exception.reason);
    }
}

- (void)cleanupRootWindowEventMask {
    NSLog(@"[WindowManager] Cleaning up root window event mask");
    
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [[XCBWindow alloc] initWithXCBWindow:[[screen rootWindow] window] 
                                                        andConnection:connection];
        
        // Clear SUBSTRUCTURE_REDIRECT to allow normal window manager behavior
        // This allows window clicks and focus changes to work after WM exits
        uint32_t values[1];
        values[0] = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;  // Keep notify, but remove redirect
        
        BOOL success = [rootWindow changeAttributes:values 
                                           withMask:XCB_CW_EVENT_MASK 
                                            checked:NO];
        
        if (success) {
            NSLog(@"[WindowManager] Successfully restored root window event mask");
        } else {
            NSLog(@"[WindowManager] Warning: Failed to restore root window event mask");
        }
        
        [connection flush];
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception in cleanupRootWindowEventMask: %@", exception.reason);
    }
}

- (void)setupKeyboardGrabbing {
    NSLog(@"[Alt-Tab] Setting up keyboard grabbing");
    
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        xcb_window_t root = [[screen rootWindow] window];
        xcb_connection_t *conn = [connection connection];
        
        // Standard keycodes for Tab on most keyboards
        // Tab is usually keycode 23 on X11 systems
        // But we need to grab all variations
        
        // Get the keyboard mapping to find Tab key
        xcb_get_keyboard_mapping_cookie_t cookie = xcb_get_keyboard_mapping(
            conn,
            8,   // min_keycode
            248  // count (255 - 8 + 1)
        );
        
        xcb_get_keyboard_mapping_reply_t *reply = xcb_get_keyboard_mapping_reply(conn, cookie, NULL);
        if (!reply) {
            NSLog(@"[Alt-Tab] ERROR: Failed to get keyboard mapping");
            return;
        }
        
        xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
        int keysyms_len = xcb_get_keyboard_mapping_keysyms_length(reply);
        
        NSLog(@"[Alt-Tab] Found %d keysyms in keyboard mapping", keysyms_len);
        
        // Find Tab key and grab it
        BOOL tabFound = NO;
        for (int i = 0; i < keysyms_len; i++) {
            if (keysyms[i] == XK_Tab) {
                // Calculate keycode from index
                // keycode = min_keycode + (index / keysyms_per_keycode)
                xcb_keycode_t keycode = 8 + (i / reply->keysyms_per_keycode);
                
                NSLog(@"[Alt-Tab] Found Tab key at keycode %d", keycode);
                
                // Grab Alt+Tab
                xcb_grab_key(conn,
                           0,  // owner_events
                           root,
                           XCB_MOD_MASK_1,  // modifiers (Alt/Mod1)
                           keycode,
                           XCB_GRAB_MODE_ASYNC,
                           XCB_GRAB_MODE_ASYNC);
                
                // Grab Shift+Alt+Tab
                xcb_grab_key(conn,
                           0,  // owner_events
                           root,
                           XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT,  // Alt + Shift
                           keycode,
                           XCB_GRAB_MODE_ASYNC,
                           XCB_GRAB_MODE_ASYNC);
                
                tabFound = YES;
                break;
            }
        }
        
        if (!tabFound) {
            NSLog(@"[Alt-Tab] Warning: Tab key not found in keyboard mapping, using keycode 23 as fallback");
            // Fallback to common Tab keycode
            xcb_grab_key(conn, 0, root, XCB_MOD_MASK_1, 23, XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
            xcb_grab_key(conn, 0, root, XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT, 23, XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC);
        }
        
        free(reply);
        [connection flush];
        NSLog(@"[Alt-Tab] Successfully grabbed Alt+Tab and Shift+Alt+Tab");
        
    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in setupKeyboardGrabbing: %@", exception.reason);
    }
}

- (void)handleKeyPressEvent:(xcb_key_press_event_t*)event {
    @try {
        // Check for modifier states directly from the event
        BOOL altPressed = (event->state & XCB_MOD_MASK_1) != 0;
        BOOL shiftPressed = (event->state & XCB_MOD_MASK_SHIFT) != 0;
        
        // Standard keycodes for reference
        // Tab is typically keycode 23
        // Alt keys are typically 64 (Alt_L) and 108 (Alt_R)
        // Shift keys are typically 50 (Shift_L) and 62 (Shift_R)
        
        NSLog(@"[Alt-Tab] Key press: keycode=%d, state=0x%x, alt=%d, shift=%d", 
              event->detail, event->state, altPressed, shiftPressed);
        
        // Track Alt key state
        if (event->detail == 64 || event->detail == 108) {  // Alt keys
            self.altKeyPressed = YES;
            NSLog(@"[Alt-Tab] Alt key pressed");
        }
        
        // Track Shift key state
        if (event->detail == 50 || event->detail == 62) {  // Shift keys
            self.shiftKeyPressed = YES;
        }
        
        // Handle Tab key (keycode 23) with Alt modifier
        if (event->detail == 23 && altPressed) {  // Tab with Alt
            NSLog(@"[Alt-Tab] Tab pressed with Alt (shift=%d)", shiftPressed);
            
            // If not already switching, grab the keyboard to receive all future key events
            // including the Alt key release
            if (!self.windowSwitcher.isSwitching) {
                XCBScreen *screen = [[connection screens] objectAtIndex:0];
                xcb_window_t root = [[screen rootWindow] window];
                xcb_connection_t *conn = [connection connection];
                
                // Actively grab the keyboard to receive all key events
                xcb_grab_keyboard_cookie_t cookie = xcb_grab_keyboard(conn,
                                                                      0,  // owner_events
                                                                      root,
                                                                      XCB_CURRENT_TIME,
                                                                      XCB_GRAB_MODE_ASYNC,
                                                                      XCB_GRAB_MODE_ASYNC);
                xcb_grab_keyboard_reply_t *reply = xcb_grab_keyboard_reply(conn, cookie, NULL);
                
                if (reply) {
                    if (reply->status == XCB_GRAB_STATUS_SUCCESS) {
                        NSLog(@"[Alt-Tab] Successfully grabbed keyboard");
                    } else {
                        NSLog(@"[Alt-Tab] Warning: Keyboard grab failed with status %d", reply->status);
                    }
                    free(reply);
                }
                [connection flush];
            }
            
            if (shiftPressed) {
                // Shift+Alt+Tab: cycle backward
                NSLog(@"[Alt-Tab] Cycling backward");
                [self.windowSwitcher cycleBackward];
            } else {
                // Alt+Tab: cycle forward
                NSLog(@"[Alt-Tab] Cycling forward");
                [self.windowSwitcher cycleForward];
            }
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in handleKeyPressEvent: %@", exception.reason);
    }
}

- (void)handleKeyReleaseEvent:(xcb_key_release_event_t*)event {
    @try {
        NSLog(@"[Alt-Tab] Key release: keycode=%d", event->detail);
        
        // Check if Alt key was released
        if (event->detail == 64 || event->detail == 108) {  // Alt keys
            self.altKeyPressed = NO;
            NSLog(@"[Alt-Tab] Alt key released");
            
            // Complete the window switch when Alt is released
            if (self.windowSwitcher.isSwitching) {
                NSLog(@"[Alt-Tab] Completing window switch and ungrabbing keyboard");
                
                // First ungrab the keyboard
                xcb_connection_t *conn = [connection connection];
                xcb_ungrab_keyboard(conn, XCB_CURRENT_TIME);
                [connection flush];
                
                // Then complete the switching (which hides the overlay)
                [self.windowSwitcher completeSwitching];
            }
        }
        
        // Track Shift key release
        if (event->detail == 50 || event->detail == 62) {  // Shift keys
            self.shiftKeyPressed = NO;
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[Alt-Tab] Exception in handleKeyReleaseEvent: %@", exception.reason);
    }
}

#pragma mark - Cleanup

- (void)cleanupBeforeExit
{
    NSLog(@"[WindowManager] ========== Starting comprehensive cleanup ==========");
    
    @try {
        // Step 0: Clean up compositing if active
        if (self.compositingManager && [self.compositingManager compositingActive]) {
            NSLog(@"[WindowManager] Step 0: Deactivating compositing");
            [self.compositingManager deactivateCompositing];
            [self.compositingManager cleanup];
            self.compositingManager = nil;
        }
        
        // Step 1: Clean up keyboard grabs
        NSLog(@"[WindowManager] Step 1: Cleaning up keyboard grabs");
        [self cleanupKeyboardGrabbing];
        
        // Step 2: Undecorate and restore all client windows
        NSLog(@"[WindowManager] Step 2: Restoring all client windows");
        [self undecoratAllWindows];
        
        // Step 3: Clear EWMH properties
        NSLog(@"[WindowManager] Step 3: Clearing EWMH properties");
        [self clearEWMHProperties];
        
        // Step 4: Release window manager selection ownership
        NSLog(@"[WindowManager] Step 4: Releasing WM selection ownership");
        [self releaseWMSelection];
        
        // Step 5: Restore root window event mask
        NSLog(@"[WindowManager] Step 5: Restoring root window event mask");
        [self cleanupRootWindowEventMask];
        
        // Step 6: Flush all changes to X server
        NSLog(@"[WindowManager] Step 6: Flushing changes to X server");
        [connection flush];
        xcb_aux_sync([connection connection]);
        
        NSLog(@"[WindowManager] ========== Cleanup completed successfully ==========");
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception during cleanup: %@", exception.reason);
    }
}

- (void)undecoratAllWindows
{
    @try {
        if (!connection) {
            NSLog(@"[WindowManager] No connection available for window cleanup");
            return;
        }
        
        NSDictionary *windowsMap = [connection windowsMap];
        if (!windowsMap || [windowsMap count] == 0) {
            NSLog(@"[WindowManager] No windows to clean up");
            return;
        }
        
        NSLog(@"[WindowManager] Cleaning up %lu managed windows", (unsigned long)[windowsMap count]);
        
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [screen rootWindow];
        
        // Collect all frames first to avoid modifying dictionary while iterating
        NSMutableArray *framesToCleanup = [NSMutableArray array];
        
        for (NSString *windowId in windowsMap) {
            XCBWindow *window = [windowsMap objectForKey:windowId];
            if (window && [window isKindOfClass:[XCBFrame class]]) {
                [framesToCleanup addObject:window];
            }
        }
        
        NSLog(@"[WindowManager] Found %lu frames to clean up", (unsigned long)[framesToCleanup count]);
        
        // Clean up each frame
        for (XCBFrame *frame in framesToCleanup) {
            @try {
                XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
                
                if (clientWindow) {
                    NSLog(@"[WindowManager] Restoring client window %u", [clientWindow window]);
                    
                    // Get client window geometry
                    XCBRect clientRect = [clientWindow windowRect];
                    
                    // Reparent client back to root window
                    xcb_reparent_window([connection connection],
                                      [clientWindow window],
                                      [rootWindow window],
                                      clientRect.position.x,
                                      clientRect.position.y);
                    
                    // Unmap the frame (this hides the decorations)
                    xcb_unmap_window([connection connection], [frame window]);
                    
                    // Mark client as not decorated
                    [clientWindow setDecorated:NO];
                    
                    NSLog(@"[WindowManager] Client window %u restored to root", [clientWindow window]);
                }
                
                // Destroy the frame window (this will also clean up titlebar and buttons)
                xcb_destroy_window([connection connection], [frame window]);
                
            } @catch (NSException *exception) {
                NSLog(@"[WindowManager] Exception cleaning up frame %u: %@", [frame window], exception.reason);
            }
        }
        
        [connection flush];
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception in undecoratAllWindows: %@", exception.reason);
    }
}

- (void)clearEWMHProperties
{
    @try {
        if (!connection) {
            NSLog(@"[WindowManager] No connection available for EWMH cleanup");
            return;
        }
        
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [screen rootWindow];
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
        
        NSLog(@"[WindowManager] Clearing EWMH properties from root window");
        
        // Clear _NET_SUPPORTING_WM_CHECK
        xcb_delete_property([connection connection],
                          [rootWindow window],
                          [[ewmhService atomService] atomFromCachedAtomsWithKey:@"_NET_SUPPORTING_WM_CHECK"]);
        
        // Clear _NET_ACTIVE_WINDOW
        xcb_delete_property([connection connection],
                          [rootWindow window],
                          [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHActiveWindow]]);
        
        // Clear _NET_CLIENT_LIST
        xcb_delete_property([connection connection],
                          [rootWindow window],
                          [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHClientList]]);
        
        // Clear _NET_CLIENT_LIST_STACKING
        xcb_delete_property([connection connection],
                          [rootWindow window],
                          [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHClientListStacking]]);
        
        [connection flush];
        NSLog(@"[WindowManager] EWMH properties cleared");
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception clearing EWMH properties: %@", exception.reason);
    }
}

- (void)releaseWMSelection
{
    @try {
        if (!connection) {
            NSLog(@"[WindowManager] No connection available for selection release");
            return;
        }
        
        NSLog(@"[WindowManager] Releasing WM_S0 selection ownership");
        
        XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
        xcb_atom_t wmS0Atom = [atomService atomFromCachedAtomsWithKey:@"WM_S0"];
        
        if (wmS0Atom != XCB_ATOM_NONE) {
            // Set selection owner to None (releases ownership)
            xcb_set_selection_owner([connection connection],
                                   XCB_NONE,
                                   wmS0Atom,
                                   XCB_CURRENT_TIME);
            
            [connection flush];
            NSLog(@"[WindowManager] WM_S0 selection released");
        } else {
            NSLog(@"[WindowManager] Warning: Could not find WM_S0 atom");
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowManager] Exception releasing WM selection: %@", exception.reason);
    }
}

- (void)handleSelectionClear:(xcb_selection_clear_event_t *)event
{
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    xcb_atom_t wmS0Atom = [atomService atomFromCachedAtomsWithKey:@"WM_S0"];
    
    // Check if this is the WM_S0 selection being cleared (we're being replaced)
    if (event->selection == wmS0Atom) {
        NSLog(@"[WindowManager] WM_S0 selection cleared - another WM is taking over");
        NSLog(@"[WindowManager] Timestamp: %u, Owner: %u", event->time, event->owner);
        
        // Initiate clean shutdown
        [self cleanupBeforeExit];
        
        // Destroy our selection window if we have one
        if (selectionManagerWindow) {
            xcb_destroy_window([connection connection], [selectionManagerWindow window]);
            [connection flush];
            NSLog(@"[WindowManager] Selection manager window destroyed");
        }
        
        // Terminate the application gracefully
        NSLog(@"[WindowManager] Terminating to allow new WM to take over");
        [NSApp terminate:nil];
    } else {
        NSString *selectionName = [atomService atomNameFromAtom:event->selection];
        NSLog(@"[WindowManager] SelectionClear for non-WM selection: %@", selectionName);
    }
}

#pragma mark - ICCCM/EWMH Strut and Workarea Management

- (void)handleStrutPropertyChange:(xcb_property_notify_event_t*)event
{
    if (!event) return;
    
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    
    NSString *atomName = [atomService atomNameFromAtom:event->atom];
    
    // Check if this is a strut property change
    if ([atomName isEqualToString:[ewmhService EWMHWMStrut]] ||
        [atomName isEqualToString:[ewmhService EWMHWMStrutPartial]]) {
        
        NSLog(@"[ICCCM] Strut property changed for window %u: %@", event->window, atomName);
        
        if (event->state == XCB_PROPERTY_DELETE) {
            // Strut was removed
            [self removeStrutForWindow:event->window];
        } else {
            // Strut was added or modified
            [self readAndRegisterStrutForWindow:event->window];
        }
        
        // Recalculate workarea after strut change
        [self recalculateWorkarea];
    }
}

#pragma mark - Window Title Updates

- (NSString *)readUTF8Property:(NSString *)propertyName forWindow:(XCBWindow *)window
{
    if (!propertyName || !window) {
        return nil;
    }

    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];

    xcb_atom_t propertyAtom = [atomService atomFromCachedAtomsWithKey:propertyName];
    if (propertyAtom == XCB_ATOM_NONE) {
        propertyAtom = [atomService cacheAtom:propertyName];
    }

    xcb_atom_t utf8Atom = [atomService atomFromCachedAtomsWithKey:[ewmhService UTF8_STRING]];
    if (utf8Atom == XCB_ATOM_NONE) {
        utf8Atom = [atomService cacheAtom:[ewmhService UTF8_STRING]];
    }

    xcb_get_property_cookie_t cookie = xcb_get_property([connection connection],
                                                         0,
                                                         [window window],
                                                         propertyAtom,
                                                         utf8Atom,
                                                         0,
                                                         1024);
    xcb_get_property_reply_t *reply = xcb_get_property_reply([connection connection], cookie, NULL);
    if (!reply) {
        return nil;
    }

    int length = xcb_get_property_value_length(reply);
    if (length <= 0) {
        free(reply);
        return nil;
    }

    const char *bytes = (const char *)xcb_get_property_value(reply);
    NSString *value = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    free(reply);
    return value;
}

- (NSString *)titleForClientWindow:(XCBWindow *)clientWindow
{
    if (!clientWindow) {
        return @"";
    }

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];

    NSString *title = [self readUTF8Property:[ewmhService EWMHWMVisibleName] forWindow:clientWindow];
    if (!title || [title length] == 0) {
        title = [self readUTF8Property:[ewmhService EWMHWMName] forWindow:clientWindow];
    }

    if (!title || [title length] == 0) {
        ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:connection];
        title = [icccmService getWmNameForWindow:clientWindow];
    }

    if (!title) {
        title = @"";
    }

    return title;
}

- (void)handleWindowTitlePropertyChange:(xcb_property_notify_event_t*)event
{
    if (!event) {
        return;
    }

    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:connection];

    NSString *atomName = [atomService atomNameFromAtom:event->atom];
    if (!atomName) {
        return;
    }

    BOOL isWmName = [atomName isEqualToString:[icccmService WMName]];
    BOOL isNetWmName = [atomName isEqualToString:[ewmhService EWMHWMName]];
    BOOL isNetWmVisibleName = [atomName isEqualToString:[ewmhService EWMHWMVisibleName]];

    if (!isWmName && !isNetWmName && !isNetWmVisibleName) {
        return;
    }

    XCBWindow *eventWindow = [connection windowForXCBId:event->window];
    if (!eventWindow) {
        return;
    }

    XCBFrame *frame = nil;
    XCBTitleBar *titlebar = nil;
    XCBWindow *clientWindow = nil;

    if ([eventWindow isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)eventWindow;
        clientWindow = [frame childWindowForKey:ClientWindow];
    } else if ([eventWindow isKindOfClass:[XCBTitleBar class]]) {
        titlebar = (XCBTitleBar *)eventWindow;
        frame = (XCBFrame *)[titlebar parentWindow];
        if (frame) {
            clientWindow = [frame childWindowForKey:ClientWindow];
        }
    } else if ([eventWindow parentWindow] && [[eventWindow parentWindow] isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)[eventWindow parentWindow];
        clientWindow = [frame childWindowForKey:ClientWindow];
    } else {
        NSDictionary *windowsMap = [connection windowsMap];
        for (NSString *mapWindowId in windowsMap) {
            XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
            if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
                XCBFrame *testFrame = (XCBFrame *)mapWindow;
                XCBWindow *testClient = [testFrame childWindowForKey:ClientWindow];
                if (testClient && [testClient window] == event->window) {
                    frame = testFrame;
                    clientWindow = testClient;
                    break;
                }
            }
        }
    }

    if (frame && !titlebar) {
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            titlebar = (XCBTitleBar *)titlebarWindow;
        }
    }

    if (!titlebar) {
        return;
    }

    NSString *newTitle = [self titleForClientWindow:(clientWindow ? clientWindow : eventWindow)];

    [titlebar setInternalTitle:newTitle];

    if ([titlebar isGSThemeActive] && [[URSThemeIntegration sharedInstance] enabled]) {
        BOOL isActive = frame ? frame.isFocused : NO;
        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:newTitle
                                            active:isActive];
        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];
        [connection flush];
    } else {
        [titlebar setWindowTitle:newTitle];
        [titlebar drawArea:[titlebar windowRect]];
        [connection flush];
    }
}

#pragma mark - Focus Management

- (XCBWindow *)clientWindowForWindow:(XCBWindow *)window fallbackFrame:(XCBFrame *)frame
{
    if (!window) {
        if (frame && [frame isKindOfClass:[XCBFrame class]]) {
            return [frame childWindowForKey:ClientWindow];
        }
        return nil;
    }

    if ([window isKindOfClass:[XCBFrame class]]) {
        return [(XCBFrame *)window childWindowForKey:ClientWindow];
    }

    if ([window isKindOfClass:[XCBTitleBar class]]) {
        XCBFrame *parentFrame = (XCBFrame *)[window parentWindow];
        if (parentFrame) {
            return [parentFrame childWindowForKey:ClientWindow];
        }
    }

    if ([window parentWindow] && [[window parentWindow] isKindOfClass:[XCBFrame class]]) {
        return window; // client window inside a frame
    }

    if ([window parentWindow] && [[window parentWindow] isKindOfClass:[XCBTitleBar class]]) {
        XCBFrame *parentFrame = (XCBFrame *)[[window parentWindow] parentWindow];
        if (parentFrame) {
            return [parentFrame childWindowForKey:ClientWindow];
        }
    }

    if (frame && [frame isKindOfClass:[XCBFrame class]]) {
        return [frame childWindowForKey:ClientWindow];
    }

    return window;
}

- (xcb_window_t)clientWindowIdForWindowId:(xcb_window_t)windowId
{
    if (windowId == XCB_NONE) {
        return XCB_NONE;
    }

    XCBWindow *window = [connection windowForXCBId:windowId];
    XCBWindow *clientWindow = [self clientWindowForWindow:window fallbackFrame:nil];
    if (clientWindow) {
        return [clientWindow window];
    }

    // If the window is already gone, try to match against frames
    NSDictionary *windowsMap = [connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
            XCBFrame *frame = (XCBFrame *)mapWindow;
            XCBWindow *client = [frame childWindowForKey:ClientWindow];
            if (client && [client window] == windowId) {
                return windowId;
            }
        }
    }

    return windowId;
}

- (XCBWindow *)windowForClientWindowId:(xcb_window_t)clientId
{
    if (clientId == XCB_NONE) {
        return nil;
    }

    XCBWindow *window = [connection windowForXCBId:clientId];
    if (window) {
        return window;
    }

    NSDictionary *windowsMap = [connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
            XCBFrame *frame = (XCBFrame *)mapWindow;
            XCBWindow *client = [frame childWindowForKey:ClientWindow];
            if (client && [client window] == clientId) {
                return client;
            }
        }
    }

    return nil;
}

- (BOOL)isWindowFocusable:(XCBWindow *)window allowDesktop:(BOOL)allowDesktop
{
    if (!window) {
        return NO;
    }

    if (self.selectionManagerWindow && [window window] == [self.selectionManagerWindow window]) {
        return NO;
    }

    if ([window needDestroy]) {
        return NO;
    }

    if ([window isMinimized]) {
        return NO;
    }

    [window updateAttributes];
    XCBAttributesReply *attrs = [window attributes];
    if (attrs && attrs.mapState != XCB_MAP_STATE_VIEWABLE) {
        return NO;
    }

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    NSString *windowType = [window windowType];
    BOOL isMenuWindow = [windowType isEqualToString:[ewmhService EWMHWMWindowTypeMenu]] ||
                        [windowType isEqualToString:[ewmhService EWMHWMWindowTypePopupMenu]] ||
                        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDropdownMenu]];

    if (isMenuWindow) {
        return NO;
    }

    BOOL isOtherNonFocusType = [windowType isEqualToString:[ewmhService EWMHWMWindowTypeTooltip]] ||
                               [windowType isEqualToString:[ewmhService EWMHWMWindowTypeNotification]] ||
                               [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDock]] ||
                               [windowType isEqualToString:[ewmhService EWMHWMWindowTypeToolbar]] ||
                               [windowType isEqualToString:[ewmhService EWMHWMWindowTypeSplash]];

    if (isOtherNonFocusType) {
        return NO;
    }

    BOOL isDesktopWindow = [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];
    if (isDesktopWindow && !allowDesktop) {
        return NO;
    }

    return YES;
}

- (xcb_window_t)desktopWindowCandidateExcluding:(xcb_window_t)excludedId
{
    NSDictionary *windowsMap = [connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (!mapWindow) {
            continue;
        }

        XCBWindow *clientWindow = [self clientWindowForWindow:mapWindow fallbackFrame:nil];
        if (!clientWindow) {
            continue;
        }

        xcb_window_t clientId = [clientWindow window];
        if (clientId == excludedId) {
            continue;
        }

        if ([self isWindowFocusable:clientWindow allowDesktop:YES]) {
            NSString *windowType = [clientWindow windowType];
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
            if ([windowType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]]) {
                return clientId;
            }
        }
    }

    return XCB_NONE;
}

- (xcb_window_t)anyFocusableWindowExcluding:(xcb_window_t)excludedId
{
    NSDictionary *windowsMap = [connection windowsMap];
    for (NSString *mapWindowId in windowsMap) {
        XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
        if (!mapWindow) {
            continue;
        }

        XCBWindow *clientWindow = [self clientWindowForWindow:mapWindow fallbackFrame:nil];
        if (!clientWindow) {
            continue;
        }

        xcb_window_t clientId = [clientWindow window];
        if (clientId == excludedId) {
            continue;
        }

        if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
            return clientId;
        }
    }

    return XCB_NONE;
}

- (void)ensureFocusAfterWindowRemovalOfClientWindow:(xcb_window_t)removedClientId
{
    if (removedClientId == XCB_NONE) {
        return;
    }

    if (removedClientId != self.lastFocusedWindowId) {
        return;
    }

    xcb_window_t targetId = XCB_NONE;

    if (self.previousFocusedWindowId != XCB_NONE && self.previousFocusedWindowId != removedClientId) {
        XCBWindow *previousWindow = [self windowForClientWindowId:self.previousFocusedWindowId];
        if (previousWindow && [self isWindowFocusable:previousWindow allowDesktop:NO]) {
            targetId = self.previousFocusedWindowId;
        }
    }

    if (targetId == XCB_NONE) {
        targetId = [self desktopWindowCandidateExcluding:removedClientId];
    }

    if (targetId == XCB_NONE) {
        targetId = [self anyFocusableWindowExcluding:removedClientId];
    }

    if (targetId == XCB_NONE) {
        return;
    }

    XCBWindow *targetWindow = [self windowForClientWindowId:targetId];
    if (!targetWindow) {
        return;
    }

    NSLog(@"[Focus] Reassigning focus to window %u after removal of %u", targetId, removedClientId);
    [targetWindow focus];

    self.previousFocusedWindowId = self.lastFocusedWindowId;
    self.lastFocusedWindowId = targetId;
}

- (void)readAndRegisterStrutForWindow:(xcb_window_t)windowId
{
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    
    // Create a temporary window object to read properties
    XCBWindow *window = [[XCBWindow alloc] initWithXCBWindow:windowId andConnection:connection];
    if (!window) {
        NSLog(@"[ICCCM] Cannot create window object for %u", windowId);
        return;
    }
    
    // Try to read _NET_WM_STRUT_PARTIAL first (more precise)
    uint32_t strutPartial[12] = {0};
    if ([ewmhService readStrutPartialForWindow:window strut:strutPartial]) {
        // Store strut partial data
        NSMutableDictionary *strutData = [NSMutableDictionary dictionary];
        [strutData setObject:@(strutPartial[0]) forKey:@"left"];
        [strutData setObject:@(strutPartial[1]) forKey:@"right"];
        [strutData setObject:@(strutPartial[2]) forKey:@"top"];
        [strutData setObject:@(strutPartial[3]) forKey:@"bottom"];
        [strutData setObject:@(strutPartial[4]) forKey:@"left_start_y"];
        [strutData setObject:@(strutPartial[5]) forKey:@"left_end_y"];
        [strutData setObject:@(strutPartial[6]) forKey:@"right_start_y"];
        [strutData setObject:@(strutPartial[7]) forKey:@"right_end_y"];
        [strutData setObject:@(strutPartial[8]) forKey:@"top_start_x"];
        [strutData setObject:@(strutPartial[9]) forKey:@"top_end_x"];
        [strutData setObject:@(strutPartial[10]) forKey:@"bottom_start_x"];
        [strutData setObject:@(strutPartial[11]) forKey:@"bottom_end_x"];
        [strutData setObject:@(YES) forKey:@"isPartial"];
        
        [self.windowStruts setObject:strutData forKey:@(windowId)];
        
        NSLog(@"[ICCCM] Registered strut partial for window %u: left=%u, right=%u, top=%u, bottom=%u",
              windowId, strutPartial[0], strutPartial[1], strutPartial[2], strutPartial[3]);
        return;
    }
    
    // Fall back to _NET_WM_STRUT
    uint32_t strut[4] = {0};
    if ([ewmhService readStrutForWindow:window strut:strut]) {
        NSMutableDictionary *strutData = [NSMutableDictionary dictionary];
        [strutData setObject:@(strut[0]) forKey:@"left"];
        [strutData setObject:@(strut[1]) forKey:@"right"];
        [strutData setObject:@(strut[2]) forKey:@"top"];
        [strutData setObject:@(strut[3]) forKey:@"bottom"];
        [strutData setObject:@(NO) forKey:@"isPartial"];
        
        [self.windowStruts setObject:strutData forKey:@(windowId)];
        
        NSLog(@"[ICCCM] Registered strut for window %u: left=%u, right=%u, top=%u, bottom=%u",
              windowId, strut[0], strut[1], strut[2], strut[3]);
    }
}

- (void)removeStrutForWindow:(xcb_window_t)windowId
{
    NSNumber *key = @(windowId);
    if ([self.windowStruts objectForKey:key]) {
        [self.windowStruts removeObjectForKey:key];
        NSLog(@"[ICCCM] Removed strut for window %u", windowId);
    }
}

- (void)recalculateWorkarea
{
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [screen rootWindow];
        
        // Get screen dimensions
        uint32_t screenWidth = [screen screen]->width_in_pixels;
        uint32_t screenHeight = [screen screen]->height_in_pixels;
        
        // Start with full screen
        int32_t workareaX = 0;
        int32_t workareaY = 0;
        uint32_t workareaWidth = screenWidth;
        uint32_t workareaHeight = screenHeight;
        
        // Calculate maximum struts from all windows
        uint32_t maxLeft = 0, maxRight = 0, maxTop = 0, maxBottom = 0;
        
        for (NSNumber *windowKey in self.windowStruts) {
            NSDictionary *strutData = [self.windowStruts objectForKey:windowKey];
            
            uint32_t left = [[strutData objectForKey:@"left"] unsignedIntValue];
            uint32_t right = [[strutData objectForKey:@"right"] unsignedIntValue];
            uint32_t top = [[strutData objectForKey:@"top"] unsignedIntValue];
            uint32_t bottom = [[strutData objectForKey:@"bottom"] unsignedIntValue];
            
            if (left > maxLeft) maxLeft = left;
            if (right > maxRight) maxRight = right;
            if (top > maxTop) maxTop = top;
            if (bottom > maxBottom) maxBottom = bottom;
        }
        
        // Apply struts to workarea
        workareaX = (int32_t)maxLeft;
        workareaY = (int32_t)maxTop;
        workareaWidth = screenWidth - maxLeft - maxRight;
        workareaHeight = screenHeight - maxTop - maxBottom;
        
        NSLog(@"[ICCCM] Recalculated workarea: x=%d, y=%d, width=%u, height=%u (struts: left=%u, right=%u, top=%u, bottom=%u)",
              workareaX, workareaY, workareaWidth, workareaHeight, maxLeft, maxRight, maxTop, maxBottom);
        
        // Update _NET_WORKAREA on root window
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
        [ewmhService updateWorkareaForRootWindow:rootWindow 
                                               x:workareaX 
                                               y:workareaY 
                                           width:workareaWidth 
                                          height:workareaHeight];
        
        [connection flush];
        
    } @catch (NSException *exception) {
        NSLog(@"[ICCCM] Exception recalculating workarea: %@", exception.reason);
    }
}

- (NSRect)currentWorkarea
{
    XCBScreen *screen = [[connection screens] objectAtIndex:0];
    uint32_t screenWidth = [screen screen]->width_in_pixels;
    uint32_t screenHeight = [screen screen]->height_in_pixels;
    
    // Calculate maximum struts
    uint32_t maxLeft = 0, maxRight = 0, maxTop = 0, maxBottom = 0;
    
    for (NSNumber *windowKey in self.windowStruts) {
        NSDictionary *strutData = [self.windowStruts objectForKey:windowKey];
        
        uint32_t left = [[strutData objectForKey:@"left"] unsignedIntValue];
        uint32_t right = [[strutData objectForKey:@"right"] unsignedIntValue];
        uint32_t top = [[strutData objectForKey:@"top"] unsignedIntValue];
        uint32_t bottom = [[strutData objectForKey:@"bottom"] unsignedIntValue];
        
        if (left > maxLeft) maxLeft = left;
        if (right > maxRight) maxRight = right;
        if (top > maxTop) maxTop = top;
        if (bottom > maxBottom) maxBottom = bottom;
    }
    
    return NSMakeRect((CGFloat)maxLeft, 
                      (CGFloat)maxTop, 
                      (CGFloat)(screenWidth - maxLeft - maxRight),
                      (CGFloat)(screenHeight - maxTop - maxBottom));
}

#pragma mark - Cleanup

- (void)dealloc
{
    // Clean up keyboard grabs first
    [self cleanupKeyboardGrabbing];

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

- (void)focusWindowAfterThemeApplied:(XCBWindow *)clientWindow
{
    if (!clientWindow) {
        return;
    }
    
    xcb_window_t windowId = [clientWindow window];
    NSNumber *windowIdNum = [NSNumber numberWithUnsignedInt:windowId];
    
    // Check if we already focused this window recently (prevent double-focus)
    if ([self.recentlyAutoFocusedWindowIds containsObject:windowIdNum]) {
        NSLog(@"[Focus] Window %u already auto-focused recently, skipping", windowId);
        return;
    }
    
    NSLog(@"[Focus] Focusing window %u after theme applied", windowId);
    if ([self isWindowFocusable:clientWindow allowDesktop:NO]) {
        [clientWindow focus];
        [self.recentlyAutoFocusedWindowIds addObject:windowIdNum];
        NSLog(@"[Focus] Successfully focused window %u", windowId);
        
        // Remove from set after 1 second to allow the window to be focused again if needed
        [self performSelector:@selector(removeWindowFromRecentlyFocused:)
                   withObject:windowIdNum
                   afterDelay:1.0];
    } else {
        NSLog(@"[Focus] Window %u is not focusable", windowId);
    }
}

- (void)removeWindowFromRecentlyFocused:(NSNumber *)windowIdNum
{
    [self.recentlyAutoFocusedWindowIds removeObject:windowIdNum];
}

@end