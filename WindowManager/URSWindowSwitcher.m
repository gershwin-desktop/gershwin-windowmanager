//
//  URSWindowSwitcher.m
//  uroswm - Alt-Tab Window Switching
//
//  Manages window cycling and focus switching for keyboard navigation
//  Includes support for minimized windows and visual overlay
//

#import "URSWindowSwitcher.h"
#import "XCBTypes.h"

@protocol URSCompositingManaging <NSObject>
+ (instancetype)sharedManager;
- (BOOL)compositingActive;
- (void)animateWindowRestore:(xcb_window_t)windowId
                                        fromRect:(XCBRect)startRect
                                            toRect:(XCBRect)endRect;
@end
#import "XCBTitleBar.h"
#import "XCBScreen.h"
#import "ICCCMService.h"
#import "EWMHService.h"
#import <xcb/xcb.h>
#import <xcb/xcb_icccm.h>
#import "URSThemeIntegration.h"

#pragma mark - Class Extension

@interface URSWindowSwitcher ()
@property (strong, nonatomic) NSTimer *showOverlayTimer;  // 250ms delay before showing switcher overlay
@property (assign, nonatomic) BOOL overlayVisible;        // Whether the overlay is currently shown
@end

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
        self.overlayVisible = NO;
        self.showOverlayTimer = nil;
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
                        // Fetch the app icon
                        entry.icon = [self getIconForFrame:frame];
                        [validEntries addObject:entry];
                    }
                }
            }
        }
        
        // Second pass: sort by actual stacking order from X server
        //
        // On most systems, the Alt-Tab switcher orders windows by
        // Most Recently Used (MRU): the currently focused window first, then
        // the previously focused window, then the one before that, etc.
        //
        // Since focusing a window raises it to the top of the Z-order, the X
        // server's actual stacking order (from xcb_query_tree) naturally gives
        // us the MRU order: top of stack = most recently used.
        //
        // The original code used clientList which is in *registration* order
        // (the order windows were added to the WM), which has no relation to
        // recency of use. This caused the switcher to show a seemingly random
        // order instead of the expected MRU sequence.
        
        xcb_connection_t *conn = [self.connection connection];
        XCBWindow *rootWindow = [self.connection rootWindowForScreenNumber:0];
        
        NSMutableArray *sortedEntries = [NSMutableArray array];
        
        if (rootWindow) {
            // Query the X server for root window children (bottom-to-top stacking order)
            xcb_query_tree_cookie_t treeCookie = xcb_query_tree(conn, [rootWindow window]);
            xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(conn, treeCookie, NULL);
            
            if (treeReply) {
                xcb_window_t *children = xcb_query_tree_children(treeReply);
                int numChildren = xcb_query_tree_children_length(treeReply);
                
                // Build a set of valid frame window IDs for fast lookup
                NSMutableSet *validFrameIdSet = [NSMutableSet setWithCapacity:[validEntries count]];
                for (URSWindowEntry *entry in validEntries) {
                    [validFrameIdSet addObject:@([entry.frame window])];
                }
                
                // Query tree returns children bottom-to-top (bottom = oldest stacking,
                // top = most recent). We iterate in reverse to get top-to-bottom,
                // which is Most Recently Used (MRU) order.
                for (int i = numChildren - 1; i >= 0; i--) {
                    NSNumber *childId = @(children[i]);
                    if ([validFrameIdSet containsObject:childId]) {
                        for (URSWindowEntry *entry in validEntries) {
                            if ([entry.frame window] == (xcb_window_t)[childId unsignedLongValue]) {
                                [sortedEntries addObject:entry];
                                break;
                            }
                        }
                    }
                }
                
                free(treeReply);
            }
        }
        
        // Fallback: if query tree failed, use clientList (registration order)
        if ([sortedEntries count] == 0) {
            xcb_window_t *clientList = [self.connection clientList];
            NSInteger clientListCount = [self.connection clientListIndex];
            
            for (NSInteger i = clientListCount - 1; i >= 0; i--) {
                xcb_window_t windowId = clientList[i];
                for (URSWindowEntry *entry in validEntries) {
                    if ([entry.frame window] == windowId) {
                        [sortedEntries addObject:entry];
                        break;
                    }
                }
            }
        }
        
        // Add any entries that weren't in the query tree or clientList (safety net)
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
        
        //NSLog(@"[WindowSwitcher] Updated window stack with %lu windows (MRU order from X stacking)", 
              //(unsigned long)[self.windowEntries count]);
        
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
                
                //NSLog(@"[WindowSwitcher] Active window from _NET_ACTIVE_WINDOW: %u", activeWindowId);
                
                //// Log all windows for debugging
                //for (NSInteger i = 0; i < [entries count]; i++) {
                //    URSWindowEntry *entry = [entries objectAtIndex:i];
                //    //NSLog(@"[WindowSwitcher]   Entry %ld: window %u (%@)", (long)i, [entry.frame window], entry.title);
                //}
                
                // Find the entry matching this active window
                NSInteger activeIndex = -1;
                for (NSInteger i = 0; i < [entries count]; i++) {
                    URSWindowEntry *entry = [entries objectAtIndex:i];
                    if ([entry.frame window] == activeWindowId) {
                        activeIndex = i;
                        //NSLog(@"[WindowSwitcher] Found active window at index %ld", (long)activeIndex);
                        break;
                    }
                }
                
                // Move active window to front if found and not already there
                if (activeIndex > 0) {
                    URSWindowEntry *activeEntry = [entries objectAtIndex:activeIndex];
                    [entries removeObjectAtIndex:activeIndex];
                    [entries insertObject:activeEntry atIndex:0];
                    //NSLog(@"[WindowSwitcher] ✓ Moved active window to front (was at index %ld)", (long)activeIndex);
                } else if (activeIndex == 0) {
                    //NSLog(@"[WindowSwitcher] Active window already at front (index 0)");
                } else {
                    //NSLog(@"[WindowSwitcher] ⚠ Active window not found in entries!");
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
        //NSLog(@"[WindowSwitcher] Minimized window %u", [frame window]);
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception minimizing window: %@", exception.reason);
    }
}

- (void)unminimizeWindow:(XCBFrame *)frame {
    if (!frame) return;
    
    @try {
        xcb_connection_t *conn = [self.connection connection];
        
        // Clear minimized state: sets isMinimized=NO and WM_STATE=Normal
        [frame setNormalState];
        
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
                //NSLog(@"[WindowSwitcher] Warning: Titlebar parent mismatch, re-parenting");
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
                //NSLog(@"[WindowSwitcher] Warning: Client parent mismatch, re-parenting");
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
            [clientWindow setNormalState];
            
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

        // Trigger compositing restore animation (Alt-Tab path)
        {
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }
            if (compositor && [compositor compositingActive]) {
                XCBRect iconRect = XCBInvalidRect;
                EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
                if (clientWindow) {
                    xcb_get_property_reply_t *reply = [ewmhService getProperty:[ewmhService EWMHWMIconGeometry]
                                                              propertyType:XCB_ATOM_CARDINAL
                                                                 forWindow:clientWindow
                                                                    delete:NO
                                                                    length:4];
                    if (reply) {
                        int len = xcb_get_property_value_length(reply);
                        if (len >= (int)(sizeof(uint32_t) * 4)) {
                            uint32_t *values = (uint32_t *)xcb_get_property_value(reply);
                            XCBPoint pos = XCBMakePoint(values[0], values[1]);
                            XCBSize size = XCBMakeSize((uint16_t)values[2], (uint16_t)values[3]);
                            if (size.width > 0 && size.height > 0) {
                                iconRect = XCBMakeRect(pos, size);
                            }
                        }
                        free(reply);
                    }
                }
                if (!FnCheckXCBRectIsValid(iconRect)) {
                    XCBScreen *screen = [frame onScreen];
                    if (screen) {
                        uint16_t iconSize = 48;
                        double x = ((double)[screen width] - iconSize) * 0.5;
                        double y = (double)[screen height] - iconSize;
                        iconRect = XCBMakeRect(XCBMakePoint(x, y), XCBMakeSize(iconSize, iconSize));
                    }
                }

                if (FnCheckXCBRectIsValid(iconRect)) {
                    XCBRect endRect = [frame windowRect];
                    [compositor animateWindowRestore:[frame window]
                                          fromRect:iconRect
                                            toRect:endRect];
                }
            }
        }
        
        // Final stacking: raise to top
        uint32_t finalStackValues[] = { XCB_STACK_MODE_ABOVE };
        xcb_configure_window(conn, [frame window], XCB_CONFIG_WINDOW_STACK_MODE, finalStackValues);
        [self.connection flush];
        
        //NSLog(@"[WindowSwitcher] Unminimized window %u", [frame window]);
        
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

- (NSImage *)convertNetWmIconData:(uint32_t *)iconData width:(int)width height:(int)height {
    if (!iconData || width <= 0 || height <= 0) return nil;

    // _NET_WM_ICON pixels are ARGB packed as 32-bit cardinals: A<<24|R<<16|G<<8|B
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
        pixelsWide:width
        pixelsHigh:height
        bitsPerSample:8
        samplesPerPixel:4
        hasAlpha:YES
        isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:width * 4
        bitsPerPixel:32];

    if (!bitmap) return nil;

    unsigned char *dst = [bitmap bitmapData];
    for (int i = 0; i < width * height; i++) {
        uint32_t pixel = iconData[i];
        uint32_t a = (pixel >> 24) & 0xFF;
        uint32_t r = (pixel >> 16) & 0xFF;
        uint32_t g = (pixel >>  8) & 0xFF;
        uint32_t b = (pixel >>  0) & 0xFF;
        // NSBitmapImageRep RGBA layout (bytes: r, g, b, a)
        uint32_t *dstPixel = (uint32_t *)(dst + i * 4);
        *dstPixel = (a << 24) | (b << 16) | (g << 8) | r;
    }

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image addRepresentation:bitmap];
    return image;
}

- (NSImage *)getIconForFrame:(XCBFrame *)frame {
    if (!frame) return nil;
    
    @try {
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        if (!clientWindow) return nil;
        
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        
        // --- APPROACH 1: Try _NET_WM_ICON from the client window (most accurate) ---
        {
            NSImage *icon = [self iconFromNetWmIconOfWindow:clientWindow
                                                ewmhService:ewmhService];
            if (icon) return icon;
        }
        
        // --- APPROACH 2: Walk client window's children to find _NET_WM_ICON ---
        // Some X11 apps (e.g. GTK apps with client-side decorations) set
        // _NET_WM_ICON on a child window rather than the top-level client window.
        {
            xcb_connection_t *conn = [self.connection connection];
            xcb_query_tree_cookie_t treeCookie = xcb_query_tree(conn, [clientWindow window]);
            xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(conn, treeCookie, NULL);
            if (treeReply) {
                xcb_window_t *children = xcb_query_tree_children(treeReply);
                int numChildren = xcb_query_tree_children_length(treeReply);
                for (int i = 0; i < numChildren; i++) {
                    XCBWindow *child = [[XCBWindow alloc] initWithXCBWindow:children[i]
                                                              andConnection:self.connection];
                    if (child) {
                        NSImage *icon = [self iconFromNetWmIconOfWindow:child
                                                            ewmhService:ewmhService];
                        if (icon) {
                            free(treeReply);
                            return icon;
                        }
                    }
                }
                free(treeReply);
            }
        }
        
        // --- APPROACH 3: Use _NET_WM_PID to find the application via NSWorkspace ---
        // For non-GNUstep X11 apps, _NET_WM_PID identifies the owning process.
        // We can look it up in NSWorkspace's launchedApplications to get the
        // application bundle path and its icon.
        {
            uint32_t pid = [ewmhService netWMPidForWindow:clientWindow];
            if (pid != (uint32_t)-1 && pid > 0) {
                NSArray *launchedApps = [workspace launchedApplications];
                for (NSDictionary *appInfo in launchedApps) {
                    NSNumber *appPID = [appInfo objectForKey:@"NSApplicationProcessIdentifier"];
                    if (appPID && [appPID intValue] == (int)pid) {
                        NSString *appPath = [appInfo objectForKey:@"NSApplicationPath"];
                        if (appPath && [appPath length] > 0) {
                            NSImage *icon = [workspace iconForFile:appPath];
                            if (icon) {
                                [icon setSize:NSMakeSize(48.0, 48.0)];
                                return icon;
                            }
                        }
                    }
                }
                
                // Also try to find a .desktop file or app by scanning /proc/PID/cmdline
                // This catches non-GNUstep apps not registered with NSWorkspace
                {
                    char cmdline[4096];
                    char procPath[64];
                    snprintf(procPath, sizeof(procPath), "/proc/%u/cmdline", pid);
                    FILE *fp = fopen(procPath, "r");
                    if (fp) {
                        size_t nread = fread(cmdline, 1, sizeof(cmdline) - 1, fp);
                        fclose(fp);
                        if (nread > 0) {
                            cmdline[nread] = '\0';
                            // cmdline is NUL-separated; first entry is the executable path
                            NSString *execPath = [NSString stringWithUTF8String:cmdline];
                            if (execPath && [execPath length] > 0) {
                                NSString *appPath = execPath;
                                // Try iconForFile on the executable itself
                                NSImage *icon = [workspace iconForFile:appPath];
                                if (icon) {
                                    [icon setSize:NSMakeSize(48.0, 48.0)];
                                    return icon;
                                }
                                // Try to find an associated .desktop file from the binary name
                                NSString *binaryName = [[appPath lastPathComponent] stringByDeletingPathExtension];
                                if ([binaryName length] > 0) {
                                    appPath = [self iconFromDesktopFileForName:binaryName
                                                                     workspace:workspace];
                                    if (appPath) {
                                        NSImage *icon = [workspace iconForFile:appPath];
                                        if (icon) {
                                            [icon setSize:NSMakeSize(48.0, 48.0)];
                                            return icon;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // --- APPROACH 4: Try _NET_WM_ICON from the frame window itself ---
        // Some window managers copy _NET_WM_ICON to the frame; try it here
        // as a last resort before going to WM_CLASS resolution.
        {
            NSImage *icon = [self iconFromNetWmIconOfWindow:(XCBWindow *)frame
                                                ewmhService:ewmhService];
            if (icon) return icon;
        }
        
        // --- APPROACH 5: WM_CLASS / .desktop file resolution ---
        {
            ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
            [icccmService wmClassForWindow:clientWindow];
            
            NSMutableArray *windowClass = [clientWindow windowClass];
            NSString *className = nil;
            NSString *instanceName = nil;
            
            if (windowClass && [windowClass count] >= 2) {
                className = [windowClass objectAtIndex:0];
                instanceName = [windowClass objectAtIndex:1];
            }
            
            // Try to find the application path from WM_CLASS
            if (className && [className length] > 0) {
                NSString *appPath = [workspace fullPathForApplication:className];
                
                if (!appPath || [appPath length] == 0) {
                    if (instanceName && [instanceName length] > 0) {
                        appPath = [workspace fullPathForApplication:instanceName];
                    }
                }
                
                if (!appPath || [appPath length] == 0) {
                    // Try .desktop file lookup with both class and instance names
                    appPath = [self iconFromDesktopFileForName:className workspace:workspace];
                    if (!appPath && instanceName && [instanceName length] > 0) {
                        appPath = [self iconFromDesktopFileForName:instanceName workspace:workspace];
                    }
                }
                
                if (appPath && [appPath length] > 0) {
                    NSImage *icon = [workspace iconForFile:appPath];
                    if (icon) {
                        [icon setSize:NSMakeSize(48.0, 48.0)];
                        return icon;
                    }
                }
            }
        }
        
        // --- FALLBACK: Generic application icon ---
        NSString *genericAppPath = [workspace fullPathForApplication:@"GNUstep"];
        if (genericAppPath) {
            NSImage *genericAppIcon = [workspace iconForFile:genericAppPath];
            if (genericAppIcon) {
                [genericAppIcon setSize:NSMakeSize(48.0, 48.0)];
                return genericAppIcon;
            }
        }
        
        return nil;
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception getting icon for frame: %@", exception.reason);
        return nil;
    }
}

/// Extract the best _NET_WM_ICON (closest to 48x48) from a window as an NSImage.
- (NSImage *)iconFromNetWmIconOfWindow:(XCBWindow *)window
                           ewmhService:(EWMHService *)ewmhService
{
    if (!window || !ewmhService) return nil;
    
    xcb_get_property_reply_t *reply = [ewmhService netWmIconFromWindow:window];
    if (!reply) return nil;
    
    NSImage *result = nil;
    
    if (reply->type == XCB_ATOM_CARDINAL && reply->format == 32 && reply->length >= 2) {
        uint32_t *data = (uint32_t *)xcb_get_property_value(reply);
        uint32_t *end  = data + reply->length;
        
        uint32_t *bestData = NULL;
        int bestWidth = 0, bestHeight = 0, bestDiff = INT_MAX;
        uint32_t *p = data;
        while (end - p >= 2) {
            uint32_t w = p[0], h = p[1];
            uint64_t npix = (uint64_t)w * h;
            if (w < 1 || h < 1 || npix > (uint64_t)(end - p) - 2) break;
            int diff = abs((int)w - 48) + abs((int)h - 48);
            if (diff < bestDiff) {
                bestDiff = diff;
                bestWidth = (int)w;
                bestHeight = (int)h;
                bestData = p + 2;
            }
            p += 2 + npix;
        }
        
        if (bestData) {
            result = [self convertNetWmIconData:bestData width:bestWidth height:bestHeight];
            if (result) {
                [result setSize:NSMakeSize(48.0, 48.0)];
            }
        }
    }
    
    free(reply);
    return result;
}

/// Look up the icon path for an app name via .desktop files and icon theme.
/// Returns the path to the icon file, or nil if not found.
- (NSString *)iconFromDesktopFileForName:(NSString *)name
                               workspace:(NSWorkspace *)workspace
{
    if (!name || [name length] == 0) return nil;
    
    NSString *lowerName = [name lowercaseString];
    NSArray *searchPaths = @[
        @"/usr/share/applications",
        @"/usr/local/share/applications",
        @"/System/Applications"
    ];
    
    for (NSString *searchPath in searchPaths) {
        // Try both lowercased and original name for the .desktop file
        NSArray *desktopCandidates = @[
            [NSString stringWithFormat:@"%@/%@.desktop", searchPath, lowerName],
            [NSString stringWithFormat:@"%@/%@.desktop", searchPath, name]
        ];
        
        for (NSString *desktopPath in desktopCandidates) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:desktopPath]) {
                NSString *desktopContent = [NSString stringWithContentsOfFile:desktopPath
                                                                     encoding:NSUTF8StringEncoding
                                                                        error:nil];
                if (!desktopContent) continue;
                
                NSArray *lines = [desktopContent componentsSeparatedByString:@"\n"];
                for (NSString *line in lines) {
                    if ([line hasPrefix:@"Icon="]) {
                        NSString *iconName = [[line substringFromIndex:5]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if ([iconName length] == 0) continue;
                        
                        // Absolute path
                        if ([iconName hasPrefix:@"/"]) {
                            if ([[NSFileManager defaultManager] fileExistsAtPath:iconName]) {
                                return iconName;
                            }
                            continue;
                        }
                        
                        // Search icon theme paths more thoroughly
                        NSArray *iconPaths = @[
                            [NSString stringWithFormat:@"/usr/share/pixmaps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/pixmaps/%@.xpm", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/48x48/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/32x32/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/64x64/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/128x128/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/256x256/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/scalable/apps/%@.svg", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/gnome/48x48/apps/%@.png", iconName],
                            [NSString stringWithFormat:@"/usr/share/icons/gnome/scalable/apps/%@.svg", iconName]
                        ];
                        for (NSString *iconPath in iconPaths) {
                            if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
                                return iconPath;
                            }
                        }
                    }
                }
            }
        }
    }
    
    return nil;
}

#pragma mark - Switching Operations

- (void)startSwitching {
    if (self.isSwitching) return;
    
    //NSLog(@"[WindowSwitcher] Starting window switching");
    
    // Build fresh window list with minimized state tracking
    // ALWAYS recalculate to get current focus state
    [self updateWindowStack];
    
    // Check if we have at least one window OR if we have only minimized windows
    if ([self.windowEntries count] < 1) {
        //NSLog(@"[WindowSwitcher] No windows to switch (count: %lu)", 
              //(unsigned long)[self.windowEntries count]);
        return;
    }
    
    // Special case: if there's only 1 window and it's minimized, allow switching to unminimize it
    if ([self.windowEntries count] == 1) {
        URSWindowEntry *entry = [self.windowEntries objectAtIndex:0];
        if (entry.wasMinimized) {
            //NSLog(@"[WindowSwitcher] Single minimized window - Alt-Tab will unminimize it");
            // Allow switching to continue so the user can unminimize this window
        } else {
            //NSLog(@"[WindowSwitcher] Only 1 non-minimized window, nothing to switch to");
            return;
        }
    }
    
    // Reset all temporarily shown flags
    for (URSWindowEntry *entry in self.windowEntries) {
        entry.temporarilyShown = NO;
    }
    
    // Internal index starts at 0 (currently focused window or first minimized window)
    self.currentIndex = 0;
    self.isSwitching = YES;
    self.overlayVisible = NO;
    
    // Build title and icon arrays for the overlay (saved for when the timer fires)
    // The overlay shows: [Current, Next, Third, ...]
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *icons = [NSMutableArray array];
    for (URSWindowEntry *entry in self.windowEntries) {
        [titles addObject:entry.title];
        if (entry.icon) {
            [icons addObject:entry.icon];
        } else {
            [icons addObject:[NSNull null]];
        }
    }
    
    // Defer overlay appearance: only show the switcher window if Alt is held
    // for at least 100ms. Quick Alt-Tab taps complete silently without an overlay.
    self.showOverlayTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                             target:self
                                                           selector:@selector(showOverlayTimerFired:)
                                                           userInfo:@{
                                                               @"titles": titles,
                                                               @"icons": icons
                                                           }
                                                            repeats:NO];
    
    // If there's more than one window, immediately cycle to next window
    // (the overlay will catch up when the timer fires)
    if ([self.windowEntries count] > 1) {
        [self cycleForward];
    }
}

- (void)cycleForward {
    if (!self.isSwitching) {
        [self startSwitching];
        return;
    }
    
    if ([self.windowEntries count] < 1) return;
    
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
    
    if ([self.windowEntries count] < 1) return;
    
    // Move to previous window (cycling through all available windows)
    self.currentIndex = (self.currentIndex - 1 + [self.windowEntries count]) % [self.windowEntries count];
    
    // Show the new current window
    [self showWindowAtCurrentIndex];
}

#pragma mark - Overlay Show Timer

/// Called after the 250ms delay: shows the switcher overlay with current state.
- (void)showOverlayTimerFired:(NSTimer *)timer {
    self.showOverlayTimer = nil;
    if (!self.isSwitching) return;
    
    NSDictionary *userInfo = [timer userInfo];
    NSArray *titles = [userInfo objectForKey:@"titles"];
    NSArray *icons = [userInfo objectForKey:@"icons"];
    
    if (!titles || [titles count] == 0) return;
    
    // Show the overlay centered on screen
    [self.overlay showCenteredOnScreen];
    [self.overlay updateWithTitles:titles icons:icons currentIndex:self.currentIndex];
    self.overlayVisible = YES;
    
    //NSLog(@"[WindowSwitcher] Overlay shown after 250ms delay, selected index: %ld",
          //(long)self.currentIndex);
}

- (void)showWindowAtCurrentIndex {
    if (self.currentIndex < 0 || self.currentIndex >= [self.windowEntries count]) {
        return;
    }
    
    //URSWindowEntry *entry = [self.windowEntries objectAtIndex:self.currentIndex];
    //NSLog(@"[WindowSwitcher] Previewing window at index %ld: %@", (long)self.currentIndex, entry.title);
    
    // NOTE: We do NOT raise, focus, or unminimize ANY windows while Alt is held
    // The actual window switching will happen in completeSwitching when Alt is released
    // This ensures the user can cycle through options before committing to a switch
    
    // Update overlay display with new selection (only if overlay is already visible)
    if (self.overlayVisible) {
        NSMutableArray *titles = [NSMutableArray array];
        NSMutableArray *icons = [NSMutableArray array];
        for (URSWindowEntry *e in self.windowEntries) {
            [titles addObject:e.title];
            if (e.icon) {
                [icons addObject:e.icon];
            } else {
                [icons addObject:[NSNull null]];
            }
        }
        
        [self.overlay updateWithTitles:titles icons:icons currentIndex:self.currentIndex];
    }
}

- (void)completeSwitching {
    if (!self.isSwitching) return;
    
    //NSLog(@"[WindowSwitcher] ========== COMPLETING WINDOW SWITCH ==========");
    //NSLog(@"[WindowSwitcher] Current index: %ld", (long)self.currentIndex);
    
    // CRITICAL: Wrap in @try/@catch to guarantee state is always reset.
    // If any of the called methods (unminimizeWindow, focus, stackAbove,
    // drawTitleBarComponents, drawAllTitleBarsExcept) throws an exception,
    // self.isSwitching stays YES forever and the switcher is stuck.
    @try {
        // NOW perform the actual window switching when Alt is released
        if (self.currentIndex >= 0 && self.currentIndex < [self.windowEntries count]) {
            URSWindowEntry *entry = [self.windowEntries objectAtIndex:self.currentIndex];
            //NSLog(@"[WindowSwitcher] Switching to: %@", entry.title);
            
            // If this window was minimized, unminimize it now
            if (entry.wasMinimized) {
                //NSLog(@"[WindowSwitcher] Window was minimized, unminimizing...");
                [self unminimizeWindow:entry.frame];
            }
            
            // CRITICAL: Use the EXACT same code path as handleButtonPress
            // This ensures window activation works identically to clicking the titlebar
            XCBWindow *clientWindow = [entry.frame childWindowForKey:ClientWindow];
            XCBTitleBar *titleBar = (XCBTitleBar *)[entry.frame childWindowForKey:TitleBar];
            
            if (clientWindow && entry.frame) {
                //NSLog(@"[WindowSwitcher] Focusing client window %u and raising frame %u", 
                      //[clientWindow window], [entry.frame window]);
                
                // Step 1: Focus the client window (same as handleButtonPress)
                [clientWindow focus];
                
                // Step 2: Raise the frame (same as handleButtonPress)
                [entry.frame stackAbove];

                // Ensure dock windows remain stacked above regular windows
                [self.connection restackDockWindowsAbove];

                // Step 3: Update titlebar state and redraw all titlebars (same as handleButtonPress)
                if (titleBar) {
                    [titleBar setIsAbove:YES];
                    [titleBar setButtonsAbove:YES];
                    if (![titleBar isGSThemeActive]) {
                        [titleBar drawTitleBarComponents];
                        [self.connection drawAllTitleBarsExcept:titleBar];
                    }
                }
                
                //NSLog(@"[WindowSwitcher] Window activation complete using XCBKit standard path");
            } else {
                NSLog(@"[WindowSwitcher] WARNING: Could not get client window or frame!");
            }
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
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] EXCEPTION in completeSwitching: %@", exception.reason);
        //NSLog(@"[WindowSwitcher] Stack trace: %@", exception.callStackSymbols);
    }
    
    // Hide overlay (only if it was shown) — do this OUTSIDE the @try
    // so the screen gets redrawn even if the activation logic failed.
    if (self.overlayVisible) {
        [self.overlay hide];
    }
    
    // Force screen redraw after overlay is hidden so the area that was
    // covered by the switcher overlay gets repaired.
    [self forceScreenRedraw];
    
    // Cancel the show timer if it hasn't fired yet
    if (self.showOverlayTimer) {
        [self.showOverlayTimer invalidate];
        self.showOverlayTimer = nil;
    }
    
    // Reset state — ALWAYS reached even if @try block threw.
    self.isSwitching = NO;
    self.overlayVisible = NO;
    self.currentIndex = -1;
    
    //NSLog(@"[WindowSwitcher] ========== WINDOW SWITCH COMPLETED ==========");
}

- (void)cancelSwitching {
    if (!self.isSwitching) return;
    
    //NSLog(@"[WindowSwitcher] Cancelling window switch");
    
    @try {
        // Restore all temporarily shown windows to minimized state
        for (URSWindowEntry *entry in self.windowEntries) {
            if (entry.temporarilyShown && entry.frame) {
                [self minimizeWindow:entry.frame];
                entry.temporarilyShown = NO;
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] EXCEPTION in cancelSwitching: %@", exception.reason);
    }
    
    // Cancel the show timer if it hasn't fired yet
    if (self.showOverlayTimer) {
        [self.showOverlayTimer invalidate];
        self.showOverlayTimer = nil;
    }
    
    // Hide overlay (only if it was shown)
    if (self.overlayVisible) {
        [self.overlay hide];
    }
    
    // Force screen redraw after overlay is hidden.
    [self forceScreenRedraw];
    
    // Reset state
    self.isSwitching = NO;
    self.overlayVisible = NO;
    self.currentIndex = -1;
}

#pragma mark - Screen Redraw After Switcher Closes

/// Force the compositor or X server to redraw the area that was covered
/// by the switcher overlay.  The overlay is a separate NSWindow — when it
/// is hidden via orderOut: neither the compositor nor the X server knows
/// that region needs repainting, leaving a "ghost" of the overlay on screen.
- (void)forceScreenRedraw {
    @try {
        // If compositing is active, damage the overlay area and repair.
        // The overlay is a native NSWindow; we damage the full screen to be safe.
        Class compositorClass = NSClassFromString(@"URSCompositingManager");
        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
            id compositor = [compositorClass performSelector:@selector(sharedManager)];
            if (compositor && [compositor respondsToSelector:@selector(compositingActive)]) {
                BOOL active = (BOOL)(uintptr_t)[compositor performSelector:@selector(compositingActive)];
                if (active) {
                    if ([compositor respondsToSelector:@selector(damageScreen)]) {
                        [compositor performSelector:@selector(damageScreen)];
                    }
                    if ([compositor respondsToSelector:@selector(performRepairNow)]) {
                        [compositor performSelector:@selector(performRepairNow)];
                    }
                    //NSLog(@"[WindowSwitcher] Forced compositor screen redraw after overlay hide");
                    return;
                }
            }
        }
        
        // Non-compositing fallback: send a synthetic expose event to the root
        // window so the area behind the overlay is redrawn.
        xcb_connection_t *conn = [self.connection connection];
        XCBWindow *rootWindow = [self.connection rootWindowForScreenNumber:0];
        if (conn && rootWindow) {
            xcb_expose_event_t expose;
            memset(&expose, 0, sizeof(expose));
            expose.response_type = XCB_EXPOSE;
            expose.window = [rootWindow window];
            expose.x = 0;
            expose.y = 0;
            // Full screen — conservative but reliable.
            XCBScreen *screen = [[self.connection screens] firstObject];
            if (screen) {
                expose.width = [screen screen]->width_in_pixels;
                expose.height = [screen screen]->height_in_pixels;
            } else {
                expose.width = 65535;
                expose.height = 65535;
            }
            expose.count = 0;
            xcb_send_event(conn, 0, [rootWindow window],
                          XCB_EVENT_MASK_EXPOSURE,
                          (const char *)&expose);
            [self.connection flush];
            //NSLog(@"[WindowSwitcher] Sent synthetic expose to root window after overlay hide");
        }
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcher] Exception in forceScreenRedraw: %@", exception.reason);
    }
}

@end
