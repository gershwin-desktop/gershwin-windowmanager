//
//  URSHybridEventHandler.m
//  uroswm - Event Coordinator
//
//  Created by Alessandro Sangiuliano on 22/06/20.
//  Copyright (c) 2020 Alessandro Sangiuliano. All rights reserved.
//
//  Coordinator: owns the XCB event loop and dispatches to single-responsibility
//  managers (focus, keyboard, workarea, titlebar, snapping menu).
//

#import "URSHybridEventHandler.h"
#import "URSProfiler.h"
#import "XCBScreen.h"
#import "XCBQueryTreeReply.h"
#import "XCBAttributesReply.h"
#import <xcb/xcb.h>
#import <xcb/xcb_icccm.h>
#import <xcb/xcb_aux.h>
#import <xcb/damage.h>
#import <xcb/xproto.h>
#import <X11/keysym.h>
#import "EWMHService.h"
#import "XCBAtomService.h"
#import "ICCCMService.h"
#import "XCBFrame.h"
#import "URSThemeIntegration.h"
#import "GSThemeTitleBar.h"
#import "URSWindowSwitcher.h"

@implementation URSHybridEventHandler

@synthesize connection;
@synthesize selectionManagerWindow;
@synthesize xcbEventsIntegrated;
@synthesize nsRunLoopActive;
@synthesize eventCount;
@synthesize windowSwitcher;
@synthesize compositingManager;
@synthesize compositingRequested;
@synthesize focusManager;
@synthesize keyboardManager;
@synthesize workareaManager;
@synthesize titlebarController;
@synthesize snappingMenuController;

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

    // Initialize XCB connection
    connection = [XCBConnection sharedConnectionAsWindowManager:YES];

    // Initialize window switcher
    self.windowSwitcher = [URSWindowSwitcher sharedSwitcherWithConnection:connection];

    // --- Create single-responsibility managers ---
    self.focusManager = [[URSFocusManager alloc] initWithConnection:connection
                                                    selectionWindow:nil]; // set after registerAsWindowManager
    self.keyboardManager = [[URSKeyboardManager alloc] initWithConnection:connection
                                                          windowSwitcher:self.windowSwitcher];
    self.workareaManager = [[URSWorkareaManager alloc] initWithConnection:connection];
    self.titlebarController = [[URSTitlebarController alloc] initWithConnection:connection];
    self.titlebarController.workareaManager = self.workareaManager;
    self.snappingMenuController = [[URSSnappingMenuController alloc] initWithConnection:connection];

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

    // Register as window manager
    BOOL registered = [self registerAsWindowManager];
    if (!registered) {
        NSLog(@"[WindowManager] Failed to register as WM; terminating");
        [NSApp terminate:nil];
        return;
    }

    // Wire selectionManagerWindow into the focus manager now that it exists
    self.focusManager.selectionManagerWindow = self.selectionManagerWindow;
    
    // Initialize compositing if requested
    if (self.compositingRequested) {
        [self initializeCompositing];
        self.titlebarController.compositingManager = self.compositingManager;
    }

    // Decorate any existing windows already on screen
    [self decorateExistingWindowsOnStartup];

    // Setup XCB event integration with NSRunLoop
    [self setupXCBEventIntegration];

    // Setup simple timer-based theme integration
    [self setupPeriodicThemeIntegration];
    NSLog(@"GSTheme integration initialized with periodic checking enabled");
    
    // Setup keyboard grabbing for Alt-Tab
    [self.keyboardManager setupKeyboardGrabbing];
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

        connection.adoptingExistingWindows = YES;
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
                [self.workareaManager readAndRegisterStrutForWindow:winId];
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

            // Mirror the XCB_MAP_REQUEST handler's post-processing for startup-adopted windows.
            // Without this, pre-existing windows miss compositor registration and fixed-size
            // border adjustment that the normal map-request flow provides.
            XCBWindow *mappedClient = [connection windowForXCBId:winId];
            if (mappedClient && [[mappedClient parentWindow] isKindOfClass:[XCBFrame class]]) {
                if (self.compositingManager && [self.compositingManager compositingActive]) {
                    [self.compositingManager registerWindow:winId];
                    [self registerChildWindowsForCompositor:winId depth:3];
                    XCBFrame *frame = (XCBFrame *)[mappedClient parentWindow];
                    [self.compositingManager registerWindow:[frame window]];
                    [self registerChildWindowsForCompositor:[frame window] depth:3];
                }
                [self adjustBorderForFixedSizeWindow:winId];
            }

            // Apply GSTheme rendering to the titlebar immediately after decoration.
            // The normal XCB_MAP_REQUEST path calls this; we must replicate it for
            // startup-adopted windows or they keep the unstyled placeholder titlebar.
            [self applyGSThemeToRecentlyMappedWindow:[NSNumber numberWithUnsignedInt:winId]];
        }
        connection.adoptingExistingWindows = NO;

        [connection flush];
        
        // Recalculate workarea after scanning all existing windows for struts
        [self.workareaManager recalculateWorkarea];
        
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

    // Menu tracking loops run in NSEventTrackingRunLoopMode — process XCB events
    // there too so the WM can handle MapRequest for popup menu windows
    [currentRunLoop addEvent:(void*)(uintptr_t)xcbFD
                        type:ET_RDESC
                     watcher:self
                     forMode:NSEventTrackingRunLoopMode];

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
    URS_PROFILE_BEGIN(eventLoop);
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

        // Motion event compression: accumulate the latest motion event
        // but don't process it until we see a non-motion event or the queue empties.
        if ((e->response_type & ~0x80) == XCB_MOTION_NOTIFY) {
            if (lastMotionEvent) {
                free(lastMotionEvent);
            }
            lastMotionEvent = malloc(sizeof(xcb_motion_notify_event_t));
            memcpy(lastMotionEvent, e, sizeof(xcb_motion_notify_event_t));
            free(e);
            continue;
        }

        // Flush pending compressed motion only before events that depend
        // on an up-to-date window position (button press/release).
        // Flushing before every non-motion event (e.g. DAMAGE) would
        // defeat compression and make resize unbearably slow.
        if (lastMotionEvent) {
            uint8_t nextType = e->response_type & ~0x80;
            if (nextType == XCB_BUTTON_RELEASE || nextType == XCB_BUTTON_PRESS) {
                [connection handleMotionNotify:lastMotionEvent];
                [self.titlebarController handleResizeDuringMotion:lastMotionEvent];
                [self handleCompositingDuringMotion:lastMotionEvent];
                [self.titlebarController handleHoverDuringMotion:lastMotionEvent];
                needFlush = YES;
                free(lastMotionEvent);
                lastMotionEvent = NULL;
            }
        }

        [self processXCBEvent:e];

        // Check if we need to flush after this event
        if ([self eventNeedsFlush:e]) {
            needFlush = YES;
        }

        free(e);
    }

    // Process any remaining compressed motion event (e.g. motion was last in queue)
    if (lastMotionEvent) {
        [connection handleMotionNotify:lastMotionEvent];
        [self.titlebarController handleResizeDuringMotion:lastMotionEvent];
        [self handleCompositingDuringMotion:lastMotionEvent];
        [self.titlebarController handleHoverDuringMotion:lastMotionEvent];
        needFlush = YES;
        free(lastMotionEvent);
        lastMotionEvent = NULL;
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

    URS_PROFILE_END(eventLoop);
}

- (BOOL)handleSnappingMenuTriggerForButtonPress:(xcb_button_press_event_t *)pressEvent
{
    if (!pressEvent || pressEvent->detail != XCB_BUTTON_INDEX_3) {
        return NO;
    }

    XCBWindow *window = [connection windowForXCBId:pressEvent->event];
    if (!window || ![window isKindOfClass:[XCBTitleBar class]]) {
        return NO;
    }

    XCBFrame *frame = (XCBFrame *)[window parentWindow];
    if (!frame || ![frame isKindOfClass:[XCBFrame class]]) {
        return NO;
    }

    // The pointer is grabbed in sync mode by default; unfreeze it before menu tracking.
    xcb_allow_events([connection connection], XCB_ALLOW_ASYNC_POINTER, pressEvent->time);

    NSValue *pressValue =
        [NSValue valueWithBytes:pressEvent objCType:@encode(xcb_button_press_event_t)];
    [self performSelector:@selector(showDeferredSnappingMenuForButtonPress:)
               withObject:pressValue
               afterDelay:0];

    return YES;
}

- (void)showDeferredSnappingMenuForButtonPress:(NSValue *)pressValue
{
    if (!pressValue) {
        return;
    }

    xcb_button_press_event_t pressEvent;
    [pressValue getValue:&pressEvent];

    XCBWindow *window = [connection windowForXCBId:pressEvent.event];
    if (!window || ![window isKindOfClass:[XCBTitleBar class]]) {
        return;
    }

    XCBFrame *frame = (XCBFrame *)[window parentWindow];
    if (!frame || ![frame isKindOfClass:[XCBFrame class]]) {
        return;
    }

    [self.snappingMenuController showSnappingContextMenuForFrame:frame
                                                     atX11Point:NSMakePoint(pressEvent.root_x,
                                                                            pressEvent.root_y)];
}

- (void)processXCBEvent:(xcb_generic_event_t*)event
{
    URS_PROFILE_BEGIN(eventDispatch);
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
            // Clear hover state if leaving the hovered titlebar
            [self.titlebarController handleTitlebarLeave:leaveEvent];
            break;
        }
        case XCB_FOCUS_IN: {
            xcb_focus_in_event_t *focusInEvent = (xcb_focus_in_event_t *)event;
            [connection handleFocusIn:focusInEvent];
            [self handleFocusChange:focusInEvent->event isActive:YES];
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager markStackingOrderDirty];
            }
            break;
        }
        case XCB_FOCUS_OUT: {
            xcb_focus_out_event_t *focusOutEvent = (xcb_focus_out_event_t *)event;
            [connection handleFocusOut:focusOutEvent];
            // Skip inferior focus changes - focus moved to a child window
            // within the same managed window (e.g., frame -> client)
            if (focusOutEvent->detail != XCB_NOTIFY_DETAIL_INFERIOR) {
                [self handleFocusChange:focusOutEvent->event isActive:NO];
            }
            break;
        }
        case XCB_BUTTON_PRESS: {
            xcb_button_press_event_t *pressEvent = (xcb_button_press_event_t *)event;

            // Dismiss snapping context menu on any click outside it
            if (self.snappingMenuController.activeMenu) {
                NSEvent *syntheticUp = [NSEvent mouseEventWithType:NSLeftMouseUp
                                                          location:NSMakePoint(-1, -1)
                                                     modifierFlags:0
                                                         timestamp:0
                                                      windowNumber:0
                                                           context:nil
                                                       eventNumber:0
                                                        clickCount:1
                                                          pressure:0];
                [NSApp postEvent:syntheticUp atStart:YES];
                break;
            }

            // Titlebar right-click opens the snapping menu instead of entering drag/focus path.
            if ([self handleSnappingMenuTriggerForButtonPress:pressEvent]) {
                break;
            }

            // Check if this is a button click on a GSThemeTitleBar
            if (![self.titlebarController handleTitlebarButtonPress:pressEvent]) {
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

            // Dismiss snapping context menu on button release outside it
            // (e.g., user held right-click on titlebar and released off the window)
            if (self.snappingMenuController.activeMenu) {
                NSEvent *syntheticUp = [NSEvent mouseEventWithType:NSLeftMouseUp
                                                          location:NSMakePoint(-1, -1)
                                                     modifierFlags:0
                                                         timestamp:0
                                                      windowNumber:0
                                                           context:nil
                                                       eventNumber:0
                                                        clickCount:1
                                                          pressure:0];
                [NSApp postEvent:syntheticUp atStart:YES];
                break;
            }

            // Let xcbkit handle the release first
            [connection handleButtonRelease:releaseEvent];
            // After resize completes, update the titlebar with GSTheme
            [self.titlebarController handleResizeComplete:releaseEvent];

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
                [self.workareaManager readAndRegisterStrutForWindow:mapRequestEvent->window];
                [self.workareaManager recalculateWorkarea];
            }
            tempWindow = nil;
            ewmhService = nil;

            // Resize window to 70% of screen size before mapping
            [self resizeWindowTo70Percent:mapRequestEvent->window];

            // Let XCBConnection handle the map request (creates frame for managed windows)
            [connection handleMapRequest:mapRequestEvent];

            // Check if handleMapRequest created a frame for this window.
            // Unframed windows (menus, popups, tooltips, transients) only need
            // compositor registration — skip theme, focus, and border processing.
            XCBWindow *mappedClient = [connection windowForXCBId:mapRequestEvent->window];
            if (!mappedClient || ![[mappedClient parentWindow] isKindOfClass:[XCBFrame class]]) {
                NSLog(@"[WindowManager] Unframed window %u - skipping post-processing", mapRequestEvent->window);
                if (self.compositingManager && [self.compositingManager compositingActive]) {
                    [self.compositingManager registerWindow:mapRequestEvent->window];
                }
                break;
            }

            // --- Framed windows only below this point ---

            // Register window with compositor if active
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                NSLog(@"[HybridEventHandler] Registering window %u with compositor (compositingActive=%d)", mapRequestEvent->window, (int)[self.compositingManager compositingActive]);
                [self.compositingManager registerWindow:mapRequestEvent->window];
                NSLog(@"[HybridEventHandler] Registered client window %u", mapRequestEvent->window);
                // Register any existing child windows so their damage events are tracked
                [self registerChildWindowsForCompositor:mapRequestEvent->window depth:3];
                // Register children of the frame too
                XCBFrame *frame = (XCBFrame *)[mappedClient parentWindow];
                NSLog(@"[HybridEventHandler] Registering frame window %u for client %u", [frame window], mapRequestEvent->window);
                [self.compositingManager registerWindow:[frame window]];
                [self registerChildWindowsForCompositor:[frame window] depth:3];
            }

            // Hide borders for windows with fixed sizes (like info panels and logout)
            [self adjustBorderForFixedSizeWindow:mapRequestEvent->window];

            // Apply GSTheme immediately with no delay
            [self applyGSThemeToRecentlyMappedWindow:[NSNumber numberWithUnsignedInt:mapRequestEvent->window]];

            // Try to focus the client window if it's focusable
            // This ensures dialogs, alerts, sheets and other special windows get focused too
            if ([self.focusManager isWindowFocusable:mappedClient allowDesktop:NO]) {
                // Schedule focus after a brief delay to ensure the window is fully set up
                [self performSelector:@selector(focusWindowAfterThemeApplied:)
                           withObject:mappedClient
                           afterDelay:0.1];
            }
            break;
        }
        case XCB_UNMAP_NOTIFY: {
            xcb_unmap_notify_event_t *unmapNotifyEvent = (xcb_unmap_notify_event_t *)event;
            xcb_window_t removedClientId = [self.focusManager clientWindowIdForWindowId:unmapNotifyEvent->window];
            [connection handleUnMapNotify:unmapNotifyEvent];

            // Notify compositor of unmap event
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager unmapWindow:unmapNotifyEvent->window];
            }

            [self.focusManager ensureFocusAfterWindowRemoval:removedClientId];
            break;
        }
        case XCB_DESTROY_NOTIFY: {
            xcb_destroy_notify_event_t *destroyNotify = (xcb_destroy_notify_event_t *)event;
            xcb_window_t removedClientId = [self.focusManager clientWindowIdForWindowId:destroyNotify->window];
            
            // Unregister window from compositor before connection handles destroy
            if (self.compositingManager && [self.compositingManager compositingActive]) {
                [self.compositingManager unregisterWindow:destroyNotify->window];
            }
            
            // Remove any struts for this window
            if ([self.workareaManager removeStrutForWindow:destroyNotify->window]) {
                [self.workareaManager recalculateWorkarea];
            }
            
            [connection handleDestroyNotify:destroyNotify];
            [self.focusManager ensureFocusAfterWindowRemoval:removedClientId];
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
            [self.workareaManager handleStrutPropertyChange:propEvent];
            [self handleWindowTitlePropertyChange:propEvent];
            [connection handlePropertyNotify:propEvent];
            break;
        }
        case XCB_KEY_PRESS: {
            xcb_key_press_event_t *keyPressEvent = (xcb_key_press_event_t *)event;
            [self.keyboardManager handleKeyPress:keyPressEvent];
            break;
        }
        case XCB_KEY_RELEASE: {
            xcb_key_release_event_t *keyReleaseEvent = (xcb_key_release_event_t *)event;
            [self.keyboardManager handleKeyRelease:keyReleaseEvent];
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
    URS_PROFILE_END(eventDispatch);
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
        case XCB_ENTER_NOTIFY:
        case XCB_LEAVE_NOTIFY:
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
        // Find the window that received focus change
        XCBWindow *window = [connection windowForXCBId:windowId];
        if (!window) {
            // The focus event might be for a client window - search all frames
            NSDictionary *windowsMap = [connection windowsMap];
            for (NSString *mapWindowId in windowsMap) {
                XCBWindow *mapWindow = [windowsMap objectForKey:mapWindowId];
                if (mapWindow && [mapWindow isKindOfClass:[XCBFrame class]]) {
                    XCBFrame *testFrame = (XCBFrame*)mapWindow;
                    XCBWindow *clientWindow = [testFrame childWindowForKey:ClientWindow];
                    if (clientWindow && [clientWindow window] == windowId) {
                        window = testFrame;
                        break;
                    }
                }
            }
            if (!window) {
                return;
            }
        }

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
            XCBWindow *clientWindow = [self.focusManager clientWindowForWindow:window fallbackFrame:frame];
            if (clientWindow) {
                xcb_window_t clientId = [clientWindow window];
                [self.focusManager trackFocusGain:clientId];
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
                    BOOL exposeSuccess = [URSThemeIntegration renderGSThemeToWindow:frame
                                                                             frame:frame
                                                                             title:titlebar.windowTitle
                                                                            active:YES];

                    // Draw the updated pixmap into the window backing store so the
                    // compositor captures themed content (not blank) on its next paint.
                    if (exposeSuccess) {
                        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
                        [titlebar drawArea:[titlebar windowRect]];
                    }
                    // Compositor update is handled by the XCB_EXPOSE handler (updateWindow call)
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

                // Also mark client window as non-resizable so WM won't offer resize or attempt programmatic resizes
                XCBWindow *clientW = [connection windowForXCBId:clientWindowId];
                if (clientW) {
                    [clientW setCanResize:NO];
                    NSLog(@"Marked client window %u as non-resizable (canResize=NO)", clientWindowId);
                }

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
        // If the window is already managed by us (already decorated or currently minimized),
        // we must respect its existing geometry and state. Restoration from minimized state
        // is handled precisely by XCBConnection's handleMapRequest during the map sequence.
        XCBWindow *existingWindow = [connection windowForXCBId:clientWindowId];
        if (existingWindow && ([existingWindow decorated] || [existingWindow isMinimized])) {
            NSLog(@"[WindowManager] Skipping automatic resize for already-managed window %u (decorated=%d, minimized=%d)", 
                  clientWindowId, [existingWindow decorated], [existingWindow isMinimized]);
            return;
        }

        // Get the screen dimensions
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        uint16_t screenWidth = [screen width];
        uint16_t screenHeight = [screen height];
        
        // Get the current workarea (respects struts from dock windows like menu bar)
        NSRect workarea = [self.workareaManager currentWorkarea];
        
        // Golden ratio positioning (0.618) within the workarea
        // Position window at (1 - φ) ≈ 0.382 to lean left and top
        uint16_t goldenPosX = (uint16_t)(workarea.origin.x + workarea.size.width * 0.382);
        uint16_t goldenPosY = (uint16_t)(workarea.origin.y + workarea.size.height * 0.382);
        
        // Get current geometry to check if resizing is needed
        xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry([connection connection], clientWindowId);
        xcb_get_geometry_reply_t *geom_reply = xcb_get_geometry_reply([connection connection], geom_cookie, NULL);
        
        if (geom_reply) {
            // Respect ICCCM WM_NORMAL_HINTS: if the client is fixed-size, do not apply WM defaults
            xcb_size_hints_t sizeHints;
            if (xcb_icccm_get_wm_normal_hints_reply([connection connection],
                                                    xcb_icccm_get_wm_normal_hints([connection connection], clientWindowId),
                                                    &sizeHints,
                                                    NULL)) {
                if ((sizeHints.flags & XCB_ICCCM_SIZE_HINT_P_MIN_SIZE) &&
                    (sizeHints.flags & XCB_ICCCM_SIZE_HINT_P_MAX_SIZE) &&
                    sizeHints.min_width == sizeHints.max_width &&
                    sizeHints.min_height == sizeHints.max_height) {
                    NSLog(@"resizeWindowTo70Percent: client %u is fixed-size; skipping WM defaults", clientWindowId);
                    free(geom_reply);
                    return;
                }
            }

            
            // Check window type
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
            XCBWindow *queryWindow = [[XCBWindow alloc] initWithXCBWindow:clientWindowId andConnection:connection];

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
            // Clamp overly large windows before mapping.
            // Rule: if either dimension exceeds 90% of screen, resize both dimensions to 80%
            BOOL exceedsNinetyPercent =
                ((uint32_t)geom_reply->width * 100 > (uint32_t)screenWidth * 90) ||
                ((uint32_t)geom_reply->height * 100 > (uint32_t)screenHeight * 90);

            if (!isDesktopWindow && !isFullscreenState && exceedsNinetyPercent) {
                uint16_t clampedWidth = (uint16_t)(screenWidth * 0.8);
                uint16_t clampedHeight = (uint16_t)(screenHeight * 0.8);

                // Per HIG: place resized windows toward top-left so desktop status affordances
                // (such as volume icons) remain visible and unobstructed.
                uint32_t sizeValues[] = {goldenPosX, goldenPosY, clampedWidth, clampedHeight};
                xcb_configure_window([connection connection],
                                     clientWindowId,
                             XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                             XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                                     sizeValues);
                [connection flush];
                NSLog(@"Window %u exceeds 90%% of screen (%ux%u). Clamped to 80%% (%ux%u) and placed at golden ratio (%u,%u) before map.",
                      clientWindowId,
                      geom_reply->width,
                      geom_reply->height,
                      clampedWidth,
                    clampedHeight,
                    goldenPosX,
                    goldenPosY);
            }

            // Only apply WM golden-ratio placement if:
            // 1. Window is positioned at (0,0) - indicates no app positioning
            // 2. AND window is not a desktop window
            // 3. AND window is not explicitly requesting fullscreen
            BOOL isAtOrigin = (geom_reply->x == 0 && geom_reply->y == 0);
            BOOL isFullScreenSize = (geom_reply->width >= screenWidth && geom_reply->height >= screenHeight);
            
            if (isAtOrigin && (geom_reply->width < screenWidth) && !isDesktopWindow && !isFullscreenState) {
                // Window starts at (0,0) but is NOT full-width. This is usually a fallback position
                // for apps that don't specify geometry. Move it to the golden ratio position
                // which matches where a newly created window of the same type would get mapped.
                NSLog(@"Window %u starts at origin (0,0) but is not full-width (%u). Applying golden ratio placement to avoid x=0 default.",
                      clientWindowId, geom_reply->width);
                
                uint32_t configValues[] = {goldenPosX, goldenPosY};
                xcb_configure_window([connection connection],
                                     clientWindowId,
                                     XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y,
                                     configValues);
                [connection flush];
            } else if (isDesktopWindow || isFullscreenState) {
                NSLog(@"Window %u is desktop or fullscreen window. Skipping WM defaults (isDesktop=%d, isFullscreen=%d)",
                      clientWindowId, isDesktopWindow, isFullscreenState);
            } else if (isAtOrigin && isFullScreenSize) {
                NSLog(@"Window %u is exactly full screen size at origin; skipping >90%% clamp per 100%% exception.",
                      clientWindowId);
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

                            // Paint the GSTheme content into the titlebar's backing store NOW,
                            // before the compositor takes its first NameWindowPixmap snapshot.
                            // Without this, the compositor may capture the blank initial state
                            // (no drawArea has been called yet) and show a flash of undecorated
                            // content before the first Expose-driven redraw arrives.
                            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
                            [titlebar drawArea:[titlebar windowRect]];
                            [self.connection flush];

                            // Notify compositor about the new window content
                            if (self.compositingManager && [self.compositingManager compositingActive]) {
                                [self.compositingManager updateWindow:[frame window]];
                            }

                            // Auto-focus the client window - the frame and titlebar are now fully set up
                            // Focus after a small delay to ensure the window is properly rendered and ready
                            [self performSelector:@selector(focusWindowAfterThemeApplied:)
                                       withObject:clientWindow
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
            if ([self.focusManager isWindowFocusable:directWindow allowDesktop:NO]) {
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
                // Compositor repaints at its own cadence; no need to force full repair
                // on every motion pixel (that would stall the resize pipeline).
            }
        }
    } @catch (NSException *exception) {
        // Silently ignore exceptions during motion to avoid spam
    }
}

#pragma mark - Cleanup

- (void)cleanupRootWindowEventMask {
    NSLog(@"[WindowManager] Cleaning up root window event mask");
    
    @try {
        XCBScreen *screen = [[connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [[XCBWindow alloc] initWithXCBWindow:[[screen rootWindow] window] 
                                                        andConnection:connection];
        
        uint32_t values[1];
        values[0] = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
        
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
        [self.keyboardManager cleanupKeyboardGrabbing];
        
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

                    // Translate client coordinates to root-space before reparenting.
                    // clientWindow.windowRect is relative to the frame and causes
                    // incorrect placement if used directly for root reparent.
                    int16_t rootX = 0;
                    int16_t rootY = 0;
                    xcb_translate_coordinates_reply_t *translated =
                        xcb_translate_coordinates_reply([connection connection],
                                                       xcb_translate_coordinates([connection connection],
                                                                                 [clientWindow window],
                                                                                 [rootWindow window],
                                                                                 0,
                                                                                 0),
                                                       NULL);

                    if (translated) {
                        rootX = translated->dst_x;
                        rootY = translated->dst_y;
                        free(translated);
                    } else {
                        XCBRect frameRect = [frame windowRect];
                        XCBRect clientRect = [clientWindow windowRect];
                        rootX = frameRect.position.x + clientRect.position.x;
                        rootY = frameRect.position.y + clientRect.position.y;
                    }

                    // Reparent client back to root window
                    xcb_reparent_window([connection connection],
                                      [clientWindow window],
                                      [rootWindow window],
                                      rootX,
                                      rootY);
                    
                    // Unmap the frame (this hides the decorations)
                    xcb_unmap_window([connection connection], [frame window]);
                    
                    // Mark client as not decorated
                    [clientWindow setDecorated:NO];
                    
                    NSLog(@"[WindowManager] Client window %u restored to root at %d,%d", [clientWindow window], rootX, rootY);
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
    xcb_generic_error_t *propError = NULL;
    xcb_get_property_reply_t *reply = xcb_get_property_reply([connection connection], cookie, &propError);
    if (propError)
    {
        free(propError);
        return nil;
    }
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


#pragma mark - Cleanup

- (void)dealloc
{
    // Clean up keyboard grabs first
    [self.keyboardManager cleanupKeyboardGrabbing];

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
    [self.focusManager focusWindowAfterThemeApplied:clientWindow];
}

- (void)removeWindowFromRecentlyFocused:(NSNumber *)windowIdNum
{
    [self.focusManager removeWindowFromRecentlyFocused:windowIdNum];
}

@end