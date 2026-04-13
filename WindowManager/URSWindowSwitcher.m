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
                        // Fetch the app icon
                        entry.icon = [self getIconForFrame:frame];
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
        
        // Get WM_CLASS to identify the application
        // First ensure wmClass is fetched (it may already be cached)
        ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self.connection];
        [icccmService wmClassForWindow:clientWindow];
        
        NSMutableArray *windowClass = [clientWindow windowClass];
        NSString *className = nil;
        NSString *instanceName = nil;
        
        if (windowClass && [windowClass count] >= 2) {
            className = [windowClass objectAtIndex:0];
            instanceName = [windowClass objectAtIndex:1];
        }
        
        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        NSString *appPath = nil;
        
        // Try to find the application path if we have WM_CLASS
        if (className && [className length] > 0) {
            // First try the class name
            appPath = [workspace fullPathForApplication:className];
            
            // If that fails, try the instance name
            if (!appPath || [appPath length] == 0) {
                if (instanceName && [instanceName length] > 0) {
                    appPath = [workspace fullPathForApplication:instanceName];
                }
            }
            
            // For non-GNUstep apps, try common paths
            if (!appPath || [appPath length] == 0) {
                NSArray *searchPaths = @[
                    @"/usr/share/applications",
                    @"/usr/local/share/applications",
                    @"/System/Applications"
                ];
                
                for (NSString *searchPath in searchPaths) {
                    // Try .desktop file approach for non-GNUstep apps
                    NSString *desktopPath = [NSString stringWithFormat:@"%@/%@.desktop", searchPath, [className lowercaseString]];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:desktopPath]) {
                        // Read Icon= line from .desktop file
                        NSString *desktopContent = [NSString stringWithContentsOfFile:desktopPath encoding:NSUTF8StringEncoding error:nil];
                        if (desktopContent) {
                            NSArray *lines = [desktopContent componentsSeparatedByString:@"\n"];
                            for (NSString *line in lines) {
                                if ([line hasPrefix:@"Icon="]) {
                                    NSString *iconName = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                    // Try as absolute path first
                                    if ([iconName hasPrefix:@"/"]) {
                                        if ([[NSFileManager defaultManager] fileExistsAtPath:iconName]) {
                                            appPath = iconName;
                                            break;
                                        }
                                    } else {
                                        // Search in icon theme paths
                                        NSArray *iconPaths = @[
                                            [NSString stringWithFormat:@"/usr/share/pixmaps/%@.png", iconName],
                                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/48x48/apps/%@.png", iconName],
                                            [NSString stringWithFormat:@"/usr/share/icons/hicolor/scalable/apps/%@.svg", iconName]
                                        ];
                                        for (NSString *iconPath in iconPaths) {
                                            if ([[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
                                                appPath = iconPath;
                                                break;
                                            }
                                        }
                                        if (appPath) break;
                                    }
                                }
                            }
                        }
                        if (appPath) break;
                    }
                }
            }
            
            if (appPath && [appPath length] > 0) {
                // Get the application icon - use iconForFile which works for both .app bundles and icon files
                NSImage *icon = [workspace iconForFile:appPath];
                if (icon) {
                    // Resize icon to 48x48 like the Dock uses
                    [icon setSize:NSMakeSize(48.0, 48.0)];
                    return icon;
                }
            }
        }
        
        // FALLBACK 1: Try to get icon from X11 _NET_WM_ICON property
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
        xcb_get_property_reply_t *reply = [ewmhService netWmIconFromWindow:clientWindow];

        if (reply) {
            // _NET_WM_ICON format: [width, height, ARGB32_pixels...] repeated per size
            if (reply->type == XCB_ATOM_CARDINAL && reply->format == 32 && reply->length >= 2) {
                uint32_t *data = (uint32_t *)xcb_get_property_value(reply);
                uint32_t *end  = data + reply->length;

                // Find the icon size closest to 48x48
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
                    NSImage *icon = [self convertNetWmIconData:bestData width:bestWidth height:bestHeight];
                    if (icon) {
                        [icon setSize:NSMakeSize(48.0, 48.0)];
                        free(reply);
                        return icon;
                    }
                }
            }
            free(reply);
        }
        
        // FALLBACK 2: Use generic application icon
        // Try to get the generic application icon from the workspace
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

#pragma mark - Switching Operations

- (void)startSwitching {
    if (self.isSwitching) return;
    
    NSLog(@"[WindowSwitcher] Starting window switching");
    
    // Build fresh window list with minimized state tracking
    // ALWAYS recalculate to get current focus state
    [self updateWindowStack];
    
    // Check if we have at least one window OR if we have only minimized windows
    if ([self.windowEntries count] < 1) {
        NSLog(@"[WindowSwitcher] No windows to switch (count: %lu)", 
              (unsigned long)[self.windowEntries count]);
        return;
    }
    
    // Special case: if there's only 1 window and it's minimized, allow switching to unminimize it
    if ([self.windowEntries count] == 1) {
        URSWindowEntry *entry = [self.windowEntries objectAtIndex:0];
        if (entry.wasMinimized) {
            NSLog(@"[WindowSwitcher] Single minimized window - Alt-Tab will unminimize it");
            // Allow switching to continue so the user can unminimize this window
        } else {
            NSLog(@"[WindowSwitcher] Only 1 non-minimized window, nothing to switch to");
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
    
    // Build title and icon arrays for overlay showing ALL windows (current first, then others)
    // The overlay shows: [Current, Next, Third, ...]
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *icons = [NSMutableArray array];
    for (URSWindowEntry *entry in self.windowEntries) {
        [titles addObject:entry.title];
        // Add icon or NSNull placeholder if no icon available
        if (entry.icon) {
            [icons addObject:entry.icon];
        } else {
            [icons addObject:[NSNull null]];
        }
    }
    
    // Show overlay centered on screen
    [self.overlay showCenteredOnScreen];
    
    // For single window case, highlight index 0
    // For multiple windows, start with index 1 highlighted (the next window to switch to)
    NSInteger initialHighlight = ([self.windowEntries count] == 1) ? 0 : 1;
    [self.overlay updateWithTitles:titles icons:icons currentIndex:initialHighlight];
    
    // If there's more than one window, immediately cycle to next window
    // If there's only one window, just stay at index 0 (it will be unminimized on completeSwitching)
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
    // Build full titles and icons arrays showing all windows
    NSMutableArray *titles = [NSMutableArray array];
    NSMutableArray *icons = [NSMutableArray array];
    for (URSWindowEntry *e in self.windowEntries) {
        [titles addObject:e.title];
        // Add icon or NSNull placeholder if no icon available
        if (e.icon) {
            [icons addObject:e.icon];
        } else {
            [icons addObject:[NSNull null]];
        }
    }
    
    // Overlay index matches internal index (current window at 0, next at 1, etc.)
    [self.overlay updateWithTitles:titles icons:icons currentIndex:self.currentIndex];
}

- (void)completeSwitching {
    if (!self.isSwitching) return;
    
    NSLog(@"[WindowSwitcher] ========== COMPLETING WINDOW SWITCH ==========");
    NSLog(@"[WindowSwitcher] Current index: %ld", (long)self.currentIndex);
    
    // NOW perform the actual window switching when Alt is released
    if (self.currentIndex >= 0 && self.currentIndex < [self.windowEntries count]) {
        URSWindowEntry *entry = [self.windowEntries objectAtIndex:self.currentIndex];
        NSLog(@"[WindowSwitcher] Switching to: %@", entry.title);
        
        // If this window was minimized, unminimize it now
        if (entry.wasMinimized) {
            NSLog(@"[WindowSwitcher] Window was minimized, unminimizing...");
            [self unminimizeWindow:entry.frame];
        }
        
        // CRITICAL: Use the EXACT same code path as handleButtonPress
        // This ensures window activation works identically to clicking the titlebar
        XCBWindow *clientWindow = [entry.frame childWindowForKey:ClientWindow];
        XCBTitleBar *titleBar = (XCBTitleBar *)[entry.frame childWindowForKey:TitleBar];
        
        if (clientWindow && entry.frame) {
            NSLog(@"[WindowSwitcher] Focusing client window %u and raising frame %u", 
                  [clientWindow window], [entry.frame window]);
            
            // Step 1: Focus the client window (same as handleButtonPress)
            [clientWindow focus];
            
            // Step 2: Raise the frame (same as handleButtonPress)
            [entry.frame stackAbove];
            
            // Step 3: Update titlebar state and redraw all titlebars (same as handleButtonPress)
            if (titleBar) {
                [titleBar setIsAbove:YES];
                [titleBar setButtonsAbove:YES];
                [titleBar drawTitleBarComponents];
                
                // CRITICAL: This is what makes all OTHER windows appear inactive
                [self.connection drawAllTitleBarsExcept:titleBar];
            }
            
            NSLog(@"[WindowSwitcher] Window activation complete using XCBKit standard path");
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
    
    // Hide overlay
    [self.overlay hide];
    
    // Reset state
    self.isSwitching = NO;
    self.currentIndex = -1;
    
    NSLog(@"[WindowSwitcher] ========== WINDOW SWITCH COMPLETED ==========");
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

@end
