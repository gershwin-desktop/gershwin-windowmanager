//
//  URSWindowSwitcher.m
//  uroswm - Alt-Tab Window Switching
//
//  Manages window cycling and focus switching for keyboard navigation
//  Includes support for minimized windows and visual overlay
//

#import "URSWindowSwitcher.h"
#import <XCBKit/XCBTitleBar.h>
#import <XCBKit/XCBScreen.h>
#import <XCBKit/services/ICCCMService.h>
#import <XCBKit/services/EWMHService.h>
#import <xcb/xcb.h>
#import <xcb/xcb_icccm.h>

#pragma mark - URSWindowEntry Implementation

@implementation URSWindowEntry

- (instancetype)initWithFrame:(XCBFrame *)frame wasMinimized:(BOOL)minimized title:(NSString *)title {
    self = [super init];
    if (self) {
        self.frame = frame;
        self.wasMinimized = minimized;
        self.temporarilyShown = NO;
        self.title = title ? title : @"Unknown";
        self.icon = nil;
    }
    return self;
}

@end

#pragma mark - URSWindowSwitcher Implementation

@implementation URSWindowSwitcher

@synthesize connection;
@synthesize windowEntries;
@synthesize currentIndex;
@synthesize isSwitching;
@synthesize overlay;

#pragma mark - Singleton

+ (instancetype)sharedSwitcherWithConnection:(XCBConnection *)conn {
    static URSWindowSwitcher *sharedSwitcher = nil;
    @synchronized(self) {
        if (!sharedSwitcher) {
            sharedSwitcher = [[URSWindowSwitcher alloc] initWithConnection:conn];
        }
    }
    return sharedSwitcher;
}

- (instancetype)initWithConnection:(XCBConnection *)conn {
    self = [super init];
    if (self) {
        self.connection = conn;
        self.windowEntries = [NSMutableArray array];
        self.currentIndex = -1;
        self.isSwitching = NO;
        self.overlay = [URSWindowSwitcherOverlay sharedOverlay];
    }
    return self;
}

#pragma mark - Window Stack Management

- (void)updateWindowStack {
    @try {
        [self.windowEntries removeAllObjects];
        NSDictionary *windowsMap = [self.connection windowsMap];
        
        // First pass: collect all valid managed windows
        NSMutableArray *validEntries = [NSMutableArray array];
        for (NSString *windowId in windowsMap) {
            XCBWindow *window = [windowsMap objectForKey:windowId];
            
            if (window && [window isKindOfClass:[XCBFrame class]]) {
                XCBFrame *frame = (XCBFrame *)window;
                
                // Check if the frame has a titlebar (managed window)
                XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
                if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
                    if (!frame.needDestroy) {
                        BOOL isMinimized = [self isWindowMinimized:frame];
                        NSString *title = [self getTitleForFrame:frame];
                        
                        URSWindowEntry *entry = [[URSWindowEntry alloc] initWithFrame:frame
                                                                         wasMinimized:isMinimized
                                                                                title:title];
                        [validEntries addObject:entry];
                    }
                }
            }
        }
        
        // Second pass: sort by stacking order from clientList (bottom to top)
        // The clientList is in stacking order where last entry is topmost (most recently used)
        xcb_window_t *clientList = [self.connection clientList];
        NSInteger clientListCount = [self.connection clientListIndex];
        
        NSMutableArray *sortedEntries = [NSMutableArray array];
        
        // Add windows in reverse order of clientList (topmost first)
        for (NSInteger i = clientListCount - 1; i >= 0; i--) {
            xcb_window_t windowId = clientList[i];
            
            // Find the matching entry
            for (URSWindowEntry *entry in validEntries) {
                if ([entry.frame window] == windowId) {
                    [sortedEntries addObject:entry];
                    break;
                }
            }
        }
        
        // Add any entries that weren't in the clientList (shouldn't happen, but be safe)
        for (URSWindowEntry *entry in validEntries) {
            BOOL found = NO;
            for (URSWindowEntry *sortedEntry in sortedEntries) {
                if (sortedEntry.frame == entry.frame) {
                    found = YES;
                    break;
                }
            }
            if (!found) {
                [sortedEntries addObject:entry];
            }
        }
        
        // Third pass: Ensure the currently focused window is at index 0
        // This is critical for proper Alt-Tab behavior: focused window at 0,
        // so Alt-Tab once goes to window at index 1
        [self moveActiveWindowToFrontInArray:sortedEntries];
        
        self.windowEntries = sortedEntries;
        
        NSLog(@"[WindowSwitcher] Updated window stack with %lu windows (ordered by focus + stacking)", 
              (unsigned long)[self.windowEntries count]);
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception updating window stack: %@", exception.reason);
    }
}

- (void)moveActiveWindowToFrontInArray:(NSMutableArray *)entries {
    if (!entries || [entries count] < 2) {
        return;
    }
    
    @try {
        // Ensure X server has processed all pending requests before querying
        [self.connection flush];
        
        // Get the root window
        XCBWindow *rootWindow = [self.connection rootWindowForScreenNumber:0];
        if (!rootWindow) {
            NSLog(@"[WindowSwitcher] Could not get root window for active window check");
            return;
        }
        
        // Query fresh _NET_ACTIVE_WINDOW from X server using direct XCB calls
        xcb_connection_t *conn = [self.connection connection];
        
        // Get atom for _NET_ACTIVE_WINDOW
        xcb_intern_atom_cookie_t atomCookie = xcb_intern_atom(conn, 0, strlen("_NET_ACTIVE_WINDOW"), "_NET_ACTIVE_WINDOW");
        xcb_intern_atom_reply_t *atomReply = xcb_intern_atom_reply(conn, atomCookie, NULL);
        
        if (!atomReply) {
            NSLog(@"[WindowSwitcher] Could not get _NET_ACTIVE_WINDOW atom");
            return;
        }
        
        xcb_atom_t netActiveWindowAtom = atomReply->atom;
        free(atomReply);
        
        // Query the property
        xcb_get_property_cookie_t propCookie = xcb_get_property(conn, 0, 
                                                                 [rootWindow window],
                                                                 netActiveWindowAtom,
                                                                 XCB_ATOM_WINDOW,
                                                                 0, 1);
        xcb_get_property_reply_t *propReply = xcb_get_property_reply(conn, propCookie, NULL);
        
        if (propReply && propReply->length > 0) {
            xcb_window_t *valuePtr = (xcb_window_t *)xcb_get_property_value(propReply);
            if (valuePtr) {
                xcb_window_t activeWindowId = *valuePtr;
                
                NSLog(@"[WindowSwitcher] Active window from _NET_ACTIVE_WINDOW: %u", activeWindowId);
                
                // Log all windows for debugging
                for (NSInteger i = 0; i < [entries count]; i++) {
                    URSWindowEntry *entry = [entries objectAtIndex:i];
                    NSLog(@"[WindowSwitcher]   Entry %ld: window %u (%@)", (long)i, [entry.frame window], entry.title);
                }
                
                // Find the entry matching this active window
                NSInteger activeIndex = -1;
                for (NSInteger i = 0; i < [entries count]; i++) {
                    URSWindowEntry *entry = [entries objectAtIndex:i];
                    if ([entry.frame window] == activeWindowId) {
                        activeIndex = i;
                        NSLog(@"[WindowSwitcher] Found active window at index %ld", (long)activeIndex);
                        break;
                    }
                }
                
                // Move active window to front if found and not already there
                if (activeIndex > 0) {
                    URSWindowEntry *activeEntry = [entries objectAtIndex:activeIndex];
                    [entries removeObjectAtIndex:activeIndex];
                    [entries insertObject:activeEntry atIndex:0];
                    NSLog(@"[WindowSwitcher] ✓ Moved active window to front (was at index %ld)", (long)activeIndex);
                } else if (activeIndex == 0) {
                    NSLog(@"[WindowSwitcher] Active window already at front (index 0)");
                } else {
                    NSLog(@"[WindowSwitcher] ⚠ Active window not found in entries!");
                }
            }
            free(propReply);
        } else {
            NSLog(@"[WindowSwitcher] Could not query _NET_ACTIVE_WINDOW property");
            if (propReply) free(propReply);
        }
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception in moveActiveWindowToFrontInArray: %@", exception.reason);
    }
}

- (void)addWindowToStack:(XCBFrame *)frame {
    if (!frame) return;
    
    // Check if already in stack
    for (URSWindowEntry *entry in self.windowEntries) {
        if (entry.frame == frame) return;
    }
    
    NSString *title = [self getTitleForFrame:frame];
    URSWindowEntry *entry = [[URSWindowEntry alloc] initWithFrame:frame
                                                     wasMinimized:NO
                                                            title:title];
    [self.windowEntries insertObject:entry atIndex:0];
}

- (void)removeWindowFromStack:(XCBFrame *)frame {
    if (!frame) return;
    
    URSWindowEntry *toRemove = nil;
    for (URSWindowEntry *entry in self.windowEntries) {
        if (entry.frame == frame) {
            toRemove = entry;
            break;
        }
    }
    if (toRemove) {
        [self.windowEntries removeObject:toRemove];
    }
}

#pragma mark - Window State Checking

- (BOOL)isWindowMinimized:(XCBFrame *)frame {
    if (!frame) return NO;
    
    @try {
        // Use ICCCMService to check WM_STATE
        ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
        WindowState state = [icccmService wmStateFromWindow:frame];
        
        if (state == ICCCM_WM_STATE_ICONIC) {
            return YES;
        }
        
        // Also check map state as fallback
        xcb_connection_t *conn = [self.connection connection];
        xcb_get_window_attributes_cookie_t cookie = xcb_get_window_attributes(conn, [frame window]);
        xcb_get_window_attributes_reply_t *reply = xcb_get_window_attributes_reply(conn, cookie, NULL);
        
        if (reply) {
            BOOL unmapped = (reply->map_state != XCB_MAP_STATE_VIEWABLE);
            free(reply);
            return unmapped;
        }
        
        return NO;
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception checking minimized state: %@", exception.reason);
        return NO;
    }
}

- (void)minimizeWindow:(XCBFrame *)frame {
    if (!frame) return;
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Set WM_STATE to Iconic
        ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
        [icccmService setWMStateForWindow:frame state:ICCCM_WM_STATE_ICONIC];
        
        // Unmap the frame window (hides both frame and client)
        xcb_unmap_window(conn, [frame window]);
        
        [self.connection flush];
        NSLog(@"[WindowSwitcher] Minimized window %u", [frame window]);
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception minimizing window: %@", exception.reason);
    }
}

- (void)unminimizeWindow:(XCBFrame *)frame {
    if (!frame) return;
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Set WM_STATE to Normal first
        ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
        [icccmService setWMStateForWindow:frame state:ICCCM_WM_STATE_NORMAL];
        
        // Ensure proper stacking before mapping
        // Get the root window and raise frame above it
        XCBWindow *rootWindow = [self.connection rootWindowForScreenNumber:0];
        if (!rootWindow) {
            NSLog(@"[WindowSwitcher] Warning: Could not get root window");
        }
        
        // Raise the frame to top of stack before mapping
        uint32_t stackValues[] = { XCB_STACK_MODE_ABOVE };
        xcb_configure_window(conn, [frame window], XCB_CONFIG_WINDOW_STACK_MODE, stackValues);
        [self.connection flush];
        
        // Ensure titlebar is properly attached and map it
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (titlebarWindow) {
            // Ensure titlebar is reparented to frame if needed
            xcb_window_t titlebarParent = 0;
            xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(conn,
                xcb_query_tree(conn, [titlebarWindow window]), NULL);
            if (treeReply) {
                titlebarParent = treeReply->parent;
                free(treeReply);
            }
            
            if (titlebarParent != [frame window]) {
                NSLog(@"[WindowSwitcher] Warning: Titlebar parent mismatch, re-parenting");
                xcb_reparent_window(conn, [titlebarWindow window], [frame window], 0, 0);
            }
            
            xcb_map_window(conn, [titlebarWindow window]);
            
            // Force titlebar to redraw
            if ([titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
                XCBTitleBar *titlebar = (XCBTitleBar *)titlebarWindow;
                [titlebar drawTitleBarComponentsPixmaps];
            }
        }
        
        // Map the client window
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        if (clientWindow) {
            // Ensure client is reparented to frame if needed
            xcb_window_t clientParent = 0;
            xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(conn,
                xcb_query_tree(conn, [clientWindow window]), NULL);
            if (treeReply) {
                clientParent = treeReply->parent;
                free(treeReply);
            }
            
            if (clientParent != [frame window]) {
                NSLog(@"[WindowSwitcher] Warning: Client parent mismatch, re-parenting");
                // Get the client's current geometry to maintain position
                xcb_get_geometry_reply_t *geomReply = xcb_get_geometry_reply(conn,
                    xcb_get_geometry(conn, [clientWindow window]), NULL);
                if (geomReply) {
                    xcb_reparent_window(conn, [clientWindow window], [frame window],
                                       geomReply->x, geomReply->y);
                    free(geomReply);
                }
            }
            
            xcb_map_window(conn, [clientWindow window]);
            
            // Send expose event to client so it repaints
            xcb_expose_event_t exposeEvent;
            memset(&exposeEvent, 0, sizeof(exposeEvent));
            exposeEvent.response_type = XCB_EXPOSE;
            exposeEvent.window = [clientWindow window];
            exposeEvent.x = 0;
            exposeEvent.y = 0;
            exposeEvent.width = 65535;  // Full width
            exposeEvent.height = 65535; // Full height
            exposeEvent.count = 0;
            
            xcb_send_event(conn, 0, [clientWindow window],
                          XCB_EVENT_MASK_EXPOSURE,
                          (const char *)&exposeEvent);
        }
        
        // Map the frame window itself
        xcb_map_window(conn, [frame window]);
        [self.connection flush];
        
        // Final stacking: raise to top
        uint32_t finalStackValues[] = { XCB_STACK_MODE_ABOVE };
        xcb_configure_window(conn, [frame window], XCB_CONFIG_WINDOW_STACK_MODE, finalStackValues);
        [self.connection flush];
        
        NSLog(@"[WindowSwitcher] Unminimized window %u", [frame window]);
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception unminimizing window: %@", exception.reason);
    }
}

- (NSString *)getTitleForFrame:(XCBFrame *)frame {
    if (!frame) return @"Unknown";
    
    @try {
        // Get titlebar and its window title
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (titlebarWindow && [titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            XCBTitleBar *titlebar = (XCBTitleBar *)titlebarWindow;
            NSString *title = [titlebar windowTitle];
            if (title && [title length] > 0) {
                return title;
            }
        }
        
        // Fallback: get from client window via ICCCM
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        if (clientWindow) {
            ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
            NSString *title = [icccmService getWmNameForWindow:clientWindow];
            if (title && [title length] > 0) {
                return title;
            }
        }
        
        return [NSString stringWithFormat:@"Window %u", [frame window]];
        
    } @catch (NSException *exception) {
        return @"Unknown";
    }
}

#pragma mark - Switching Operations

- (void)startSwitching {
    if (self.isSwitching) return;
    
    NSLog(@"[WindowSwitcher] Starting window switching");
    
    // Build fresh window list with minimized state tracking
    // ALWAYS recalculate to get current focus state
    [self updateWindowStack];
    
    if ([self.windowEntries count] < 2) {
        NSLog(@"[WindowSwitcher] Not enough windows to switch (count: %lu)", 
              (unsigned long)[self.windowEntries count]);
        return;
    }
    
    // Reset all temporarily shown flags
    for (URSWindowEntry *entry in self.windowEntries) {
        entry.temporarilyShown = NO;
    }
    
    // Internal index starts at 0 (currently focused window)
    self.currentIndex = 0;
    self.isSwitching = YES;
    
    // Build title array for overlay showing ALL windows (current first, then others)
    // The overlay shows: [Current, Next, Third, ...]
    NSMutableArray *titles = [NSMutableArray array];
    for (URSWindowEntry *entry in self.windowEntries) {
        [titles addObject:entry.title];
    }
    
    // Show overlay centered on screen
    [self.overlay showCenteredOnScreen];
    // Start with index 1 highlighted (the next window to switch to)
    [self.overlay updateWithTitles:titles currentIndex:1];
    
    // Immediately cycle to next window (will move to index 1, which is already shown)
    [self cycleForward];
}

- (void)cycleForward {
    if (!self.isSwitching) {
        [self startSwitching];
        return;
    }
    
    if ([self.windowEntries count] < 2) return;
    
    // Move to next window (cycling through all available windows)
    // Start at 0, cycle through 1,2,3,...,count-1, then back to 0
    self.currentIndex = (self.currentIndex + 1) % [self.windowEntries count];
    
    // Show the new current window
    [self showWindowAtCurrentIndex];
}

- (void)cycleBackward {
    if (!self.isSwitching) {
        [self startSwitching];
        return;
    }
    
    if ([self.windowEntries count] < 2) return;
    
    // Move to previous window (cycling through all available windows)
    self.currentIndex = (self.currentIndex - 1 + [self.windowEntries count]) % [self.windowEntries count];
    
    // Show the new current window
    [self showWindowAtCurrentIndex];
}

- (void)showWindowAtCurrentIndex {
    if (self.currentIndex < 0 || self.currentIndex >= [self.windowEntries count]) {
        return;
    }
    
    URSWindowEntry *entry = [self.windowEntries objectAtIndex:self.currentIndex];
    NSLog(@"[WindowSwitcher] Previewing window at index %ld: %@", (long)self.currentIndex, entry.title);
    
    // NOTE: We do NOT raise, focus, or unminimize ANY windows while Alt is held
    // The actual window switching will happen in completeSwitching when Alt is released
    // This ensures the user can cycle through options before committing to a switch
    
    // Update overlay display with new selection
    // Build full titles array showing all windows
    NSMutableArray *titles = [NSMutableArray array];
    for (URSWindowEntry *e in self.windowEntries) {
        [titles addObject:e.title];
    }
    
    // Overlay index matches internal index (current window at 0, next at 1, etc.)
    [self.overlay updateWithTitles:titles currentIndex:self.currentIndex];
}

- (void)completeSwitching {
    if (!self.isSwitching) return;
    
    NSLog(@"[WindowSwitcher] Completing window switch at index %ld", (long)self.currentIndex);
    
    // NOW perform the actual window switching when Alt is released
    if (self.currentIndex >= 0 && self.currentIndex < [self.windowEntries count]) {
        URSWindowEntry *entry = [self.windowEntries objectAtIndex:self.currentIndex];
        NSLog(@"[WindowSwitcher] Switching focus to: %@", entry.title);
        
        // If this window was minimized, unminimize it now
        if (entry.wasMinimized) {
            [self unminimizeWindow:entry.frame];
        }
        
        // Raise and focus the selected window
        [self raiseWindow:entry.frame];
        [self focusWindow:entry.frame];
    }
    
    // Re-minimize any other windows that were temporarily shown (none in current implementation)
    for (NSInteger i = 0; i < [self.windowEntries count]; i++) {
        if (i == self.currentIndex) continue;
        
        URSWindowEntry *entry = [self.windowEntries objectAtIndex:i];
        if (entry.temporarilyShown && entry.frame) {
            [self minimizeWindow:entry.frame];
            entry.temporarilyShown = NO;
        }
    }
    
    // Hide overlay
    [self.overlay hide];
    
    // Reset state
    self.isSwitching = NO;
    self.currentIndex = -1;
}

- (void)cancelSwitching {
    if (!self.isSwitching) return;
    
    NSLog(@"[WindowSwitcher] Cancelling window switch");
    
    // Restore all temporarily shown windows to minimized state
    for (URSWindowEntry *entry in self.windowEntries) {
        if (entry.temporarilyShown && entry.frame) {
            [self minimizeWindow:entry.frame];
            entry.temporarilyShown = NO;
        }
    }
    
    // Hide overlay
    [self.overlay hide];
    
    // Reset state
    self.isSwitching = NO;
    self.currentIndex = -1;
}

#pragma mark - Helper Methods

- (void)raiseWindow:(XCBFrame *)frame {
    if (!frame) return;
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        uint32_t values[] = { XCB_STACK_MODE_ABOVE };
        xcb_configure_window(conn, [frame window], XCB_CONFIG_WINDOW_STACK_MODE, values);
        [self.connection flush];
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception raising window: %@", exception.reason);
    }
}

- (void)focusWindow:(XCBFrame *)frame {
    if (!frame) return;
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Focus the client window
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        if (clientWindow) {
            xcb_set_input_focus(conn, XCB_INPUT_FOCUS_POINTER_ROOT,
                               [clientWindow window], XCB_CURRENT_TIME);
            
            // Update _NET_ACTIVE_WINDOW so Menu and other apps can track active window changes
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
            [ewmhService updateNetActiveWindow:clientWindow];
            ewmhService = nil;
        } else {
            xcb_set_input_focus(conn, XCB_INPUT_FOCUS_POINTER_ROOT,
                               [frame window], XCB_CURRENT_TIME);
        }
        
        [self.connection flush];
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception focusing window: %@", exception.reason);
    }
}

@end
