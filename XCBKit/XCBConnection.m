//
//  XCBConnection.m
//  XCBKit
//
//  Created by alex on 27/04/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBConnection.h"
#import "services/EWMHService.h"
#import "XCBFrame.h"
#import "XCBSelection.h"
#import "XCBTitleBar.h"
#import "functions/Transformers.h"
#import "utils/CairoDrawer.h"
#import "services/ICCCMService.h"
#import "XCBRegion.h"
#import "utils/CairoSurfacesSet.h"
#import <xcb/xcb_aux.h>
#import <enums/EIcccm.h>
#import "services/TitleBarSettingsService.h"
#import "utils/XCBShape.h"
#import <dispatch/dispatch.h>

#import <objc/message.h> // for dynamic messaging to compositor helper

@protocol URSCompositingManaging <NSObject>
+ (instancetype)sharedManager;
- (BOOL)compositingActive;
- (void)animateWindowMinimize:(xcb_window_t)windowId
                                         fromRect:(XCBRect)startRect
                                             toRect:(XCBRect)endRect;
- (void)animateWindowRestore:(xcb_window_t)windowId
                                        fromRect:(XCBRect)startRect
                                            toRect:(XCBRect)endRect;
- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade;
+ (void)animateZoomRectsFromRect:(XCBRect)startRect
                          toRect:(XCBRect)endRect
                      connection:(XCBConnection *)connection
                          screen:(xcb_screen_t *)screen
                        duration:(NSTimeInterval)duration;
@end

@implementation XCBConnection

@synthesize dragState;
@synthesize damagedRegions;
@synthesize xfixesInitialized;
@synthesize resizeState;
@synthesize clientListIndex;
@synthesize isAWindowManager;
@synthesize isWindowsMapUpdated;

ICCCMService *icccmService;
static XCBConnection *sharedInstance;


- (id)initAsWindowManager:(BOOL)isWindowManager
{
    return [self initWithDisplay:NULL asWindowManager:isWindowManager];
}

- (id)initWithDisplay:(NSString*)aDisplay asWindowManager:(BOOL)isWindowManager
{
    return [self initWithXcbConnection:NULL andDisplay:aDisplay asWindowManager:isWindowManager];
}

- (id)initWithXcbConnection:(xcb_connection_t*)aConnection andDisplay:(NSString *)aDisplay asWindowManager:(BOOL)isWindowManager
{
    self = [super init];
    
    if (self == nil)
    {
        NSLog(@"Unable to init!");
        return nil;
    }
    
    const char *localDisplayName = NULL;
    needFlush = NO;
    dragState = NO;
    isAWindowManager = isWindowManager;

    if (aDisplay == NULL)
    {
        NSLog(@"[XCBConnection] Connecting to the default display in env DISPLAY");
    } else
    {
        NSLog(@"XCBConnection: Creating connection with display: %@", aDisplay);
        localDisplayName = [aDisplay UTF8String];
    }

    windowsMap = [[NSMutableDictionary alloc] initWithCapacity:1000];
    isWindowsMapUpdated = NO;

    screens = [NSMutableArray new];

    if (aConnection)
        connection = aConnection;
    else
        connection = xcb_connect(localDisplayName, NULL);

    if (connection == NULL)
    {
        NSLog(@"Connection FAILED");
        self = nil;
        return nil;
    }

    if (xcb_connection_has_error(connection))
    {
        NSLog(@"Connection has ERROR");
        self = nil;
        return nil;
    }

    int fd = xcb_get_file_descriptor(connection);

    NSLog(@"XCBConnection: Connection: %d", fd);

    /** save all screens **/

    [self checkScreens];

    [EWMHService sharedInstanceWithConnection:self];
    currentTime = XCB_CURRENT_TIME;
    icccmService = [ICCCMService sharedInstanceWithConnection:self];

    clientListIndex = 0;

    resizeState = NO;

    // Initialize expected focus tracking
    _expectedFocusWindow = 0;
    _expectedFocusTimestamp = 0;

    [self flush];
    return self;
}

+ (XCBConnection *)sharedConnectionAsWindowManager:(BOOL)asWindowManager
{
    if (sharedInstance == nil)
    {
        if (asWindowManager)
        {
            NSLog(@"[XCBConnection]: Creating shared connection as window manager...");
            sharedInstance = [[self alloc] initAsWindowManager:asWindowManager];
        }
        else
        {
            NSLog(@"[XCBConnection]: Creating shared connection...");
            sharedInstance = [[self alloc] initAsWindowManager:asWindowManager];
        }
    }

    return sharedInstance;
}

- (xcb_connection_t *)connection
{
    return connection;
}

- (NSMutableDictionary *)windowsMap
{
    return windowsMap;
}

- (void) setWindowsMap:(NSMutableDictionary *)aWindowsMap
{
    windowsMap = aWindowsMap;
}

- (void)registerWindow:(XCBWindow *)aWindow
{
    if (!isAWindowManager)
        return;

    if (aWindow == nil)
    {
        NSLog(@"[XCBConnection] WARNING: Attempted to register nil window!");
        return;
    }

    xcb_window_t win = [aWindow window];

    NSLog(@"[XCBConnection] Adding the window %u in the windowsMap", win);
    NSNumber *key = [[NSNumber alloc] initWithInt:win];
    XCBWindow *window = [windowsMap objectForKey:key];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];

    if (window != nil)
    {
        // Window already registered - skip duplicate registration
        window = nil;
        key = nil;
        return;
    }
    
    if ([aWindow isKindOfClass:[XCBFrame class]] ||
        [aWindow isKindOfClass:[XCBTitleBar class]] ||
        [aWindow isCloseButton] || [aWindow isMaximizeButton] || [aWindow isMinimizeButton])
        win = 0;

    if (win != 0)
        clientList[clientListIndex++] = win;

    [ewmhService updateNetClientList];
    [windowsMap setObject:aWindow forKey:key];
    isWindowsMapUpdated = YES;

    window = nil;
    key = nil;
    ewmhService = nil;
}

- (void)unregisterWindow:(XCBWindow *)aWindow
{
    if (!isAWindowManager)
        return;

    xcb_window_t win = [aWindow window];
    NSLog(@"[XCBConnection] Removing the window %u from the windowsMap", win);
    NSNumber *key = [[NSNumber alloc] initWithInt:win];
    [windowsMap removeObjectForKey:key];
    
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    
    BOOL removed = FnRemoveWindowFromWindowsArray(clientList, clientListIndex, win);
    
    if (removed)
        clientListIndex--;

    [ewmhService updateNetClientList];

    ewmhService = nil;
    key = nil;
}

- (void)closeConnection
{
    xcb_disconnect(connection);
}

- (XCBWindow *)windowForXCBId:(xcb_window_t)anId
{
    NSNumber *key = [NSNumber numberWithInt:anId];
    XCBWindow *window = [windowsMap objectForKey:key];
    key = nil;
    return window;
}

- (int)flush
{
    int flushResult = xcb_flush(connection);
    needFlush = NO;
    return flushResult;
}

- (void)setNeedFlush:(BOOL)aNeedFlushChoice
{
    needFlush = aNeedFlushChoice;
}

- (void)checkScreens
{
    xcb_screen_iterator_t iterator = xcb_setup_roots_iterator(xcb_get_setup(connection));
    NSUInteger number = 0;
    

    while (iterator.rem)
    {
        isWindowsMapUpdated = NO;
        xcb_screen_t *scr = iterator.data;
        XCBWindow *rootWindow = [[XCBWindow alloc] initWithXCBWindow:scr->root withParentWindow:XCB_NONE andConnection:self];
        XCBScreen *screen = [XCBScreen screenWithXCBScreen:scr andRootWindow:rootWindow];
        [screen setScreenNumber:number++];
        [screens addObject:screen];

        NSLog(@"[XCBConnection] Screen with root window: %d;\n\
			  With width in pixels: %d;\n\
			  With height in pixels: %d\n",
              scr->root,
              scr->width_in_pixels,
              scr->height_in_pixels);

        [self registerWindow:rootWindow];

        [rootWindow setScreen:screen];
        [rootWindow initCursor];
        [rootWindow showLeftPointerCursor];
        [[rootWindow cursor] destroyCursor];

        xcb_screen_next(&iterator);
        rootWindow = nil;
        screen = nil;

    }

    NSLog(@"Number of screens: %lu", (unsigned long) [screens count]);
}

- (NSMutableArray *)screens
{
    return screens;
}

- (XCBWindowTypeResponse *)createWindowForRequest:(XCBCreateWindowTypeRequest *)aRequest registerWindow:(BOOL)reg
{
    XCBWindow *window;
    XCBFrame *frame;
    XCBTitleBar *titleBar;
    XCBWindowTypeResponse *response;

    window = [self createWindowWithDepth:[aRequest depth]
                        withParentWindow:[aRequest parentWindow]
                           withXPosition:[aRequest xPosition]
                           withYPosition:[aRequest yPosition]
                               withWidth:[aRequest width]
                              withHeight:[aRequest height]
                        withBorrderWidth:[aRequest borderWidth]
                            withXCBClass:[aRequest xcbClass]
                            withVisualId:[aRequest visual]
                           withValueMask:[aRequest valueMask]
                           withValueList:[aRequest valueList]
                          registerWindow:NO];

    if ([aRequest windowType] == XCBWindowRequest)
    {
        response = [[XCBWindowTypeResponse alloc] initWithXCBWindow:window];
        isWindowsMapUpdated = NO;

        if (reg)
            [self registerWindow:window];
    }

    if ([aRequest windowType] == XCBFrameRequest)
    {
        frame = FnFromXCBWindowToXCBFrame(window, self, [aRequest clientWindow]);
        response = [[XCBWindowTypeResponse alloc] initWithXCBFrame:frame];
        isWindowsMapUpdated = NO;

        if (reg)
            [self registerWindow:frame];
    }

    if ([aRequest windowType] == XCBTitleBarRequest)
    {
        titleBar = FnFromXCBWindowToXCBTitleBar(window, self);
        response = [[XCBWindowTypeResponse alloc] initWithXCBTitleBar:titleBar];
        isWindowsMapUpdated = NO;

        if (reg)
            [self registerWindow:titleBar];
    }

    frame = nil;
    titleBar = nil;
    window = nil;

    return response;
}

- (XCBWindow *)createWindowWithDepth:(uint8_t)depth
               withParentWindow:(XCBWindow *)aParentWindow
               withXPosition:(int16_t)xPosition
               withYPosition:(int16_t)yPosition
               withWidth:(int16_t)width
               withHeight:(int16_t)height
               withBorrderWidth:(uint16_t)borderWidth
               withXCBClass:(uint16_t)xcbClass
               withVisualId:(XCBVisual *)aVisual
               withValueMask:(uint32_t)valueMask
               withValueList:(const uint32_t *)valueList
               registerWindow:(BOOL)reg
{
    xcb_window_t winId = xcb_generate_id(connection);
    XCBWindow *winToCreate = [[XCBWindow alloc] initWithXCBWindow:winId withParentWindow:aParentWindow andConnection:self];

    XCBPoint coordinates = XCBMakePoint(xPosition, yPosition);
    XCBSize windowSize = XCBMakeSize(width, height);
    XCBRect windowRect = XCBMakeRect(coordinates, windowSize);

    [winToCreate setWindowRect:windowRect];
    [winToCreate setOriginalRect:windowRect];
    
    isWindowsMapUpdated = NO;
    

    xcb_create_window(connection,
                      depth,
                      winId,
                      [aParentWindow window],
                      [winToCreate windowRect].position.x,
                      [winToCreate windowRect].position.y,
                      [winToCreate windowRect].size.width,
                      [winToCreate windowRect].size.height,
                      borderWidth,
                      xcbClass,
                      [aVisual visualId],
                      valueMask,
                      valueList);


    needFlush = YES;

    if (reg)
        [self registerWindow:winToCreate];

    return winToCreate;

}

- (void)mapWindow:(XCBWindow *)aWindow
{
    xcb_map_window(connection, [aWindow window]);
    [aWindow setIsMapped:YES];
}

- (void)unmapWindow:(XCBWindow *)aWindow
{
    xcb_unmap_window(connection, [aWindow window]);
    [aWindow setIsMapped:NO];
}

- (void)reparentWindow:(XCBWindow *)aWindow toWindow:(XCBWindow *)parentWindow position:(XCBPoint)position
{
    xcb_reparent_window(connection, [aWindow window], [parentWindow window], position.x, position.y);
    XCBRect newRect = XCBMakeRect(XCBMakePoint(position.x, position.y),
                                  XCBMakeSize([aWindow windowRect].size.width, [aWindow windowRect].size.height));

    [aWindow setWindowRect:newRect];
    [aWindow setOriginalRect:newRect];
    [aWindow setParentWindow:parentWindow];
}

- (void)handleMapNotify:(xcb_map_notify_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    NSLog(@"[%@] The window %u is mapped!", NSStringFromClass([self class]), [window window]);
    [window setIsMapped:YES];

    /*** FIXME: This code is just for testing ***/
    /*if ([window isKindOfClass:[XCBTitleBar class]])
    {
        XCBTitleBar *titleBar = (XCBTitleBar*)window;
        CairoDrawer *cairoDrawer = [[CairoDrawer alloc] initWithConnection:self window:titleBar];
        [cairoDrawer drawContent];
    }*/

    /*** use this for slower machines?**/

    /*if ([window pixmap] == 0 && [window isKindOfClass:[XCBWindow class]] &&
        [[window parentWindow] isKindOfClass:[XCBFrame class]] &&
        [window parentWindow] != [self rootWindowForScreenNumber:0])
        [NSThread detachNewThreadSelector:@selector(createPixmapDelayed) toTarget:window withObject:nil];*/

    window = nil;
}

- (void)handleUnMapNotify:(xcb_unmap_notify_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    [window setIsMapped:NO];
    NSLog(@"[%@] The window %u is unmapped!", NSStringFromClass([self class]), [window window]);

    XCBFrame *frameWindow = (XCBFrame *) [window parentWindow];

    XCBScreen *scr = [window onScreen];

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    XCBWindow *rootWindow = [scr rootWindow];

    xcb_get_property_reply_t *reply = [ewmhService getProperty:[ewmhService EWMHActiveWindow]
                                                  propertyType:XCB_ATOM_WINDOW
                                                     forWindow:rootWindow
                                                        delete:NO
                                                        length:1];

    if (reply && reply->length > 0)
    {
        xcb_window_t *activeWin = xcb_get_property_value(reply);
        if (*activeWin == [window window])
        {
            xcb_window_t none = XCB_NONE;
            [ewmhService changePropertiesForWindow:rootWindow
                                          withMode:XCB_PROP_MODE_REPLACE
                                      withProperty:[ewmhService EWMHActiveWindow]
                                          withType:XCB_ATOM_WINDOW
                                        withFormat:32
                                    withDataLength:1
                                          withData:&none];
            NSLog(@"[%u] Cleared _NET_ACTIVE_WINDOW", [window window]);
        }
        free(reply);
    }

    if (frameWindow &&
        ![frameWindow isMinimized] &&
        [frameWindow window] != [[scr rootWindow] window])
    {
        NSLog(@"Destroying window %u", [frameWindow window]);
        XCBRect rect = [window windowRect];
        [self reparentWindow:window toWindow:[[window queryTree] rootWindow] position:rect.position];
        [window setDecorated:NO];
        [frameWindow destroy];
    }

    window = nil;
    frameWindow = nil;
    scr = nil;
    ewmhService = nil;
    rootWindow = nil;
}

- (void)handleMapRequest:(xcb_map_request_event_t *)anEvent
{
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    // Ensure ICCCM service is initialized
    if (icccmService == nil) {
        icccmService = [ICCCMService sharedInstanceWithConnection:self];
    }

    BOOL isManaged = NO;
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    
    isWindowsMapUpdated = NO;

    NSLog(@"[%@] Map request for window %u", NSStringFromClass([self class]), anEvent->window);

    /** if already managed map it **/

    if (window != nil)
    {
        NSLog(@"Window %u already managed by the window manager.", [window window]);
        isManaged = YES;

        // Check if this window has a frame parent (meaning it was decorated)
        if ([[window parentWindow] isKindOfClass:[XCBFrame class]])
        {
            XCBFrame *frame = (XCBFrame *)[window parentWindow];
            XCBTitleBar *titleBar = (XCBTitleBar *)[frame childWindowForKey:TitleBar];

            NSLog(@"[MapRequest] Window has frame parent %u", [frame window]);

            // If the frame is minimized, this is a restoration request
            if ([frame isMinimized] || [window isMinimized])
            {
                NSLog(@"[MapRequest] Restoring minimized window from GNUstep");

                // Check if this window belongs to a group (has a leader)
                XCBWindow *leader = [window leaderWindow];

                if (leader && [leader window] != XCB_NONE)
                {
                    NSLog(@"[MapRequest] Window %u has leader %u, restoring all grouped windows",
                          [window window], [leader window]);

                    // Find and restore all windows with the same leader
                    NSArray *allWindows = [windowsMap allValues];
                    for (XCBWindow *groupedWindow in allWindows)
                    {
                        // Skip windows that aren't minimized or don't share the same leader
                        if (![groupedWindow isMinimized])
                            continue;

                        XCBWindow *groupedLeader = [groupedWindow leaderWindow];
                        if (!groupedLeader || [groupedLeader window] != [leader window])
                            continue;

                        // This window is part of the group and minimized - restore it
                        NSLog(@"[MapRequest] Restoring grouped window %u", [groupedWindow window]);

                        XCBFrame *groupedFrame = nil;
                        XCBTitleBar *groupedTitleBar = nil;

                        if ([[groupedWindow parentWindow] isKindOfClass:[XCBFrame class]])
                        {
                            groupedFrame = (XCBFrame *)[groupedWindow parentWindow];
                            groupedTitleBar = (XCBTitleBar *)[groupedFrame childWindowForKey:TitleBar];

                            [self mapWindow:groupedFrame];

                            if (groupedTitleBar)
                            {
                                [self mapWindow:groupedTitleBar];
                            }
                        }

                        [self mapWindow:groupedWindow];

                        // Clear minimized state
                        if (groupedFrame)
                        {
                            [groupedFrame setIsMinimized:NO];
                            [groupedFrame setNormalState];
                            // Stack ALL grouped windows above other apps
                            [groupedFrame stackAbove];
                        }
                        [groupedWindow setIsMinimized:NO];
                        [groupedWindow setNormalState];

                        if (groupedFrame) {
                            Class compositorClass = NSClassFromString(@"URSCompositingManager");
                            id<URSCompositingManaging> compositor = nil;
                            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                                compositor = [compositorClass performSelector:@selector(sharedManager)];
                            }
                            if (compositor && [compositor compositingActive]) {
                                XCBWindow *iconWindow = groupedWindow;
                                XCBRect iconRect = XCBInvalidRect;
                                [self resolveIconGeometryForWindow:iconWindow outRect:&iconRect];
                                XCBRect endRect = [groupedFrame windowRect];
                                [compositor animateWindowRestore:[groupedFrame window]
                                                       fromRect:iconRect
                                                         toRect:endRect];
                            }
                        }

                        // Focus only the originally requested window
                        if ([groupedWindow window] == [window window])
                        {
                            if (groupedTitleBar)
                            {
                                [groupedTitleBar setIsAbove:YES];
                                [groupedTitleBar drawTitleBarComponents];
                                [self drawAllTitleBarsExcept:groupedTitleBar];
                            }

                            [groupedWindow focus];
                        }
                    }
                }
                else
                {
                    // No leader/group - restore just this window
                    NSLog(@"[MapRequest] No window group, restoring single window");

                    [self mapWindow:frame];

                    if (titleBar)
                    {
                        [self mapWindow:titleBar];
                    }

                    [self mapWindow:window];

                    // Clear minimized state
                    [frame setIsMinimized:NO];
                    [window setIsMinimized:NO];
                    [frame setNormalState];
                    [window setNormalState];

                    {
                        Class compositorClass = NSClassFromString(@"URSCompositingManager");
                        id<URSCompositingManaging> compositor = nil;
                        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                            compositor = [compositorClass performSelector:@selector(sharedManager)];
                        }
                        if (compositor && [compositor compositingActive]) {
                            XCBWindow *iconWindow = window;
                            XCBRect iconRect = XCBInvalidRect;
                            [self resolveIconGeometryForWindow:iconWindow outRect:&iconRect];
                            XCBRect endRect = [frame windowRect];
                            [compositor animateWindowRestore:[frame window]
                                                   fromRect:iconRect
                                                     toRect:endRect];
                        }
                    }

                    // Bring to front and focus
                    [frame stackAbove];
                    [frame raiseResizeHandle];

                    if (titleBar)
                    {
                        [titleBar setIsAbove:YES];
                        [titleBar drawTitleBarComponents];
                        [self drawAllTitleBarsExcept:titleBar];
                    }

                    [window focus];
                }

                NSLog(@"[MapRequest] Restoration complete");
            }
            else
            {
                // Normal map for non-minimized window
                
                // Check for window open animation property
                XCBRect animStartRect = XCBInvalidRect;
                BOOL hasAnimationRect = NO;
                
                xcb_connection_t *conn = [self connection];
                xcb_window_t win = [window window];
                XCBAtomService *atomSvc = [XCBAtomService sharedInstanceWithConnection:self];
                
                // Try to get _GERSHWIN_WINDOW_OPEN_ANIMATION_RECT property
                xcb_atom_t animAtom = [atomSvc cacheAtom:@"_GERSHWIN_WINDOW_OPEN_ANIMATION_RECT"];
                if (animAtom != XCB_NONE) {
                    xcb_get_property_cookie_t cookie = xcb_get_property(conn, 0, win, animAtom, XCB_ATOM_CARDINAL, 0, 4);
                    xcb_get_property_reply_t *reply = xcb_get_property_reply(conn, cookie, NULL);
                    
                    if (reply) {
                        int len = xcb_get_property_value_length(reply);
                        if (len == 16) {
                            int32_t *data = (int32_t *)xcb_get_property_value(reply);
                            animStartRect.position.x = data[0];
                            animStartRect.position.y = data[1];
                            animStartRect.size.width = data[2];
                            animStartRect.size.height = data[3];
                            hasAnimationRect = YES;
                            
                            // Delete the property so it doesn't interfere with future operations
                            xcb_delete_property(conn, win, animAtom);
                            
                            NSLog(@"[MapRequest] Found animation rect: {%d, %d, %hu, %hu}", 
                                  (int)animStartRect.position.x, (int)animStartRect.position.y,
                                  animStartRect.size.width, animStartRect.size.height);
                        } else {
                            NSLog(@"[MapRequest] Animation property present but length=%d (expected 16)", len);
                        }
                        free(reply);
                    } else {
                        NSLog(@"[MapRequest] No reply reading animation property");
                    }
                } else {
                    // atom not present/couldn't be interned
                    NSLog(@"[MapRequest] Animation atom not found/couldn't be interned");
                }
                
                // Map the window
                [self mapWindow:frame];

                if (titleBar)
                {
                    [self mapWindow:titleBar];
                }

                [self mapWindow:window];
                
                // Trigger animation if we have a start rect
                if (hasAnimationRect) {
                    Class compositorClass = NSClassFromString(@"URSCompositingManager");
                    
                    if (compositorClass) {
                        id<URSCompositingManaging> compositor = nil;
                        if ([compositorClass respondsToSelector:@selector(sharedManager)]) {
                            compositor = [compositorClass performSelector:@selector(sharedManager)];
                        }
                        
                        if (compositor) {
                            BOOL compActive = [compositor compositingActive];
                            XCBRect endRect = [frame windowRect];
                            NSLog(@"[MapRequest] compositor present. compositingActive=%d, startRect={%d,%d,%hu,%hu}, endRect={%d,%d,%hu,%hu}",
                                  compActive,
                                  (int)animStartRect.position.x, (int)animStartRect.position.y, animStartRect.size.width, animStartRect.size.height,
                                  (int)endRect.position.x, (int)endRect.position.y, endRect.size.width, endRect.size.height);

                            if (compActive) {
                                // Compositing mode: use smooth animated transition
                                [compositor animateWindowTransition:[frame window]
                                                          fromRect:animStartRect
                                                            toRect:endRect
                                                          duration:0.25
                                                              fade:YES];
                                NSLog(@"[MapRequest] Called compositor animateWindowTransition for window %u", [frame window]);
                            } else {
                                // Non-compositing mode: use fast zoom rect animation
                                XCBScreen *screenObj = [[self screens] objectAtIndex:0];
                                xcb_screen_t *screen = [screenObj screen];
                                
                                [compositorClass animateZoomRectsFromRect:animStartRect
                                                                  toRect:endRect
                                                              connection:self
                                                                  screen:screen
                                                                duration:0.2];
                                NSLog(@"[MapRequest] Completed zoom rect window open animation");
                            }
                        } else {
                            NSLog(@"[MapRequest] No compositor available; falling back to non-compositing behavior");
                            XCBRect endRect = [frame windowRect];
                            XCBScreen *screenObj = [[self screens] objectAtIndex:0];
                            xcb_screen_t *screen = [screenObj screen];

                            Class compClassDynamic = NSClassFromString(@"URSCompositingManager");
                            if (compClassDynamic && [compClassDynamic respondsToSelector:@selector(animateZoomRectsFromRect:toRect:connection:screen:duration:)]) {
                                // Use objc_msgSend to call class method with multiple args
                                void (*msg)(id, SEL, XCBRect, XCBRect, id, xcb_screen_t*, NSTimeInterval) = (void *)objc_msgSend;
                                msg(compClassDynamic, @selector(animateZoomRectsFromRect:toRect:connection:screen:duration:), animStartRect, endRect, self, screen, 0.2);
                                NSLog(@"[MapRequest] Called dynamic animator animateZoomRectsFromRect");
                            } else {
                                NSLog(@"[MapRequest] No animator class/method available for zoom rects");
                            }
                        }
                    }
                }
            }
        }
        else
        {
            NSLog(@"[MapRequest] Window has no frame parent, mapping directly");
            // No frame, just map the window
            [self mapWindow:window];
        }

        window = nil;
        ewmhService = nil;
        return;
    }

    /*** if already decorated and managed, map it. ***/

    if ([window decorated] && isManaged)
    {
        NSLog(@"Window with id %u already decorated", [window window]);

        [self mapWindow:window];
        window = nil;

        ewmhService = nil;
        return;
    }

    if ([window decorated] == NO && !isManaged)
    {
        window = [[XCBWindow alloc] initWithXCBWindow:anEvent->window andConnection:self];
        [window updateAttributes];

        uint32_t clientMask[] = {CLIENT_SELECT_INPUT_EVENT_MASK};
        xcb_change_window_attributes([self connection],
                                      [window window],
                                      XCB_CW_EVENT_MASK,
                                      clientMask);

        [window refreshCachedWMHints];

        xcb_window_t leader = [[[window cachedWMHints] valueForKey:FnFromNSIntegerToNSString(ICCCMWindowGroupHint)] unsignedIntValue];
        XCBWindow *leaderWindow = [[XCBWindow alloc] initWithXCBWindow:leader andConnection:self];
        [window setLeaderWindow:leaderWindow];
        leaderWindow = nil;

        XCBAttributesReply *reply = [window attributes];

        if ([reply isError])
        {
            [reply description];
            reply = nil;
            return;
        }

        /** check the ovveride redirect flag, if yes the WM must not handle the window **/

        if (![reply isError])
        {
            if ([reply overrideRedirect] == YES)
            {
                window = nil;
                reply = nil;
                ewmhService = nil;
                return;
            }
            reply = nil;
        }

        /** check allowed actions **/
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [window checkNetWMAllowedActions];
        });


        NSLog(@"Window Type %@ and window: %u", [ewmhService EWMHWMWindowType], [window window]);
        void *windowTypeReply = [ewmhService getProperty:[ewmhService EWMHWMWindowType]
                                            propertyType:XCB_ATOM_ATOM
                                               forWindow:window
                                                  delete:NO
                                                  length:UINT32_MAX];

        NSString *name;
        if (windowTypeReply)
        {
            xcb_atom_t *atom = (xcb_atom_t *) xcb_get_property_value(windowTypeReply);

            XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:self];

            name = [atomService atomNameFromAtom:*atom];
            NSLog(@"Name: %@", name);

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDock]])
            {
                NSLog(@"Dock window %u to be registered", [window window]);
                
                // Select PropertyChange events on dock windows to track strut changes
                uint32_t dockMask[] = {XCB_EVENT_MASK_STRUCTURE_NOTIFY | XCB_EVENT_MASK_PROPERTY_CHANGE};
                xcb_change_window_attributes([self connection],
                                              [window window],
                                              XCB_CW_EVENT_MASK,
                                              dockMask);
                
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDock]];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeMenu]])
            {
                NSLog(@"Menu window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeMenu]];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypePopupMenu]])
            {
                NSLog(@"PopupMenu window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypePopupMenu]];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDropdownMenu]])
            {
                NSLog(@"DropdownMenu window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDropdownMenu]];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDesktop]])
            {
                NSLog(@"Desktop window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window stackBelow];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDesktop]];
                
                // Grab button on desktop window so we can track focus changes
                // This ensures _NET_ACTIVE_WINDOW is updated when clicking on desktop
                [window grabButton];
                NSLog(@"[MapRequest] Grabbed button on desktop window %u for focus tracking", [window window]);

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            /*if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDialog]])
            {
                NSLog(@"Dialog window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDialog]];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }*/

            atom = NULL; // atom points into windowTypeReply memory, cleared to avoid dangling pointer
            free(windowTypeReply);
            windowTypeReply = NULL;
        }

        /** check motif hints  **/

        void *motifHints = [ewmhService getProperty:[ewmhService MotifWMHints]
                                       propertyType:XCB_GET_PROPERTY_TYPE_ANY
                                          forWindow:window
                                             delete:NO
                                             length:5 * sizeof(uint64_t)];

        /*** this is much more for the GNUstep icon window ***/

        if (motifHints)
        {
            xcb_atom_t *atom = (xcb_atom_t *) xcb_get_property_value(motifHints);
            
            if (atom[0] == 3 && atom[1] == 0 && atom[2] == 0 && atom[3] == 0 && atom[4] == 0)
            {
                NSLog(@"Motif undecorated window: %d", [window window]);
                free(motifHints);
                [window generateWindowIcons];
                XCBGeometryReply *geometry = [window geometries];
                [window setWindowRect:[geometry rect]];  
                [window setDecorated:NO];
                [window onScreen];
                [window updateAttributes];
                [self mapWindow:window];
                [self registerWindow:window];
                [icccmService wmClassForWindow:window];
                
                // Grab button on undecorated window so we can track focus changes
                // This is needed for _NET_ACTIVE_WINDOW to be updated when clicking
                [window grabButton];
                NSLog(@"[MapRequest] Grabbed button on undecorated window %u for focus tracking", [window window]);

                window = nil;
                ewmhService = nil;
                geometry = nil;
                name = nil;
                return;
            }

        }
        else
        {
            /*** while here we are for the other apps class ***/
            
            [window generateWindowIcons];
            [window onScreen];
            [window updateAttributes];
            //[window drawIcons];
        }

        [window updateRectsFromGeometries];
        [window setFirstRun:YES];
        [window setWindowType:name];
        // windowTypeReply already freed above if it was non-NULL
        name = nil;
    }

    [window onScreen]; // TODO: Just called in the else before this? really necessary?
    XCBScreen *screen = [window screen];
    if (screen == nil && [screens count] > 0) {
        screen = [screens objectAtIndex:0];
    }
    
    XCBVisual *visual = nil;
    if (screen) {
        visual = [[XCBVisual alloc] initWithVisualId:[screen screen]->root_visual];
        [visual setVisualTypeForScreen:screen];
    }

    uint32_t values[] = { (screen ? [screen screen]->white_pixel : 0), /*XCB_BACKING_STORE_WHEN_MAPPED,*/ FRAMEMASK};
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHeight = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // Determine if we should use golden ratio placement.
    // We use it if the application hasn't explicitly specified a position (i.e. x=0, y=0).
    // If it's at (0,0), we check ICCCM hints to see if this was intentional.
    // Also, if the window has full screen width (like the Menu bar), don't move it.
    BOOL useGoldenRatio = NO;
    if ([window windowRect].position.x == 0 && [window windowRect].position.y == 0) {
        BOOL isFullWidth = NO;
        if (screen && [window windowRect].size.width >= [screen screen]->width_in_pixels) {
            isFullWidth = YES;
        }

        if (!isFullWidth) {
            xcb_size_hints_t *hints = [icccmService wmNormalHintsForWindow:window];
            if (hints) {
                if (!(hints->flags & XCB_ICCCM_SIZE_HINT_US_POSITION) && 
                    !(hints->flags & XCB_ICCCM_SIZE_HINT_P_POSITION)) {
                    useGoldenRatio = YES;
                }
                free(hints);
            } else {
                // No hints at all, assume (0,0) is just the default and apply golden ratio
                useGoldenRatio = YES;
            }
        }
    }

    int16_t xPos = [window windowRect].position.x;
    int16_t yPos = [window windowRect].position.y;
    uint16_t winWidth = [window windowRect].size.width;
    uint16_t winHeight = [window windowRect].size.height + titleHeight;

    NSLog(@"[MapRequest] Requested position for window %u: %d, %d (size %ux%u)", [window window], xPos, yPos, winWidth, winHeight);

    if (useGoldenRatio && screen) {
        uint16_t screenWidth = [screen screen]->width_in_pixels;
        uint16_t screenHeight = [screen screen]->height_in_pixels;
        
        xPos = (screenWidth - winWidth) / 2;
        yPos = (screenHeight - winHeight) * 0.381966; // Golden ratio from top
        
        NSLog(@"[MapRequest] Applying golden ratio placement for window %u: %d, %d", [window window], xPos, yPos);
        
        // Update the window's rect so subsequent logic uses the new position
        XCBRect newRect = [window windowRect];
        newRect.position.x = xPos;
        newRect.position.y = yPos;
        [window setWindowRect:newRect];
    }

    XCBCreateWindowTypeRequest *request = [[XCBCreateWindowTypeRequest alloc] initForWindowType:XCBFrameRequest];
    [request setDepth:(screen ? [screen screen]->root_depth : 24)];
    [request setParentWindow:(screen ? [screen rootWindow] : 0)];
    [request setXPosition:xPos];
    [request setYPosition:yPos];
    [request setWidth:winWidth];
    [request setHeight:winHeight];
    [request setBorderWidth:0];
    [request setXcbClass:XCB_WINDOW_CLASS_INPUT_OUTPUT];
    [request setVisual:visual];
    [request setValueMask:XCB_CW_BACK_PIXEL /*| XCB_CW_BACKING_STORE*/ | XCB_CW_EVENT_MASK];
    [request setValueList:values];
    [request setClientWindow:window];

    XCBWindowTypeResponse *response = [self createWindowForRequest:request registerWindow:YES];
    
    XCBFrame *frame = [response frame];
    
    // Ensure icccmService is valid
    if (icccmService == nil) {
        icccmService = [ICCCMService sharedInstanceWithConnection:self];
    }
    
    const xcb_atom_t atomProtocols[1] = {[[icccmService atomService] atomFromCachedAtomsWithKey:[icccmService WMDeleteWindow]]};

    [icccmService changePropertiesForWindow:frame
                                   withMode:XCB_PROP_MODE_REPLACE
                               withProperty:[icccmService WMProtocols]
                                   withType:XCB_ATOM_ATOM
                                 withFormat:32
                             withDataLength:1
                                   withData:atomProtocols];

    [ewmhService updateNetFrameExtentsForWindow:frame];
    /*[self mapWindow:frame];
    [self registerWindow:window];*/

    NSLog(@"Client window decorated with id %u at %d,%d", [window window], xPos, yPos);
    [frame initCursor];  // Must init cursor BEFORE decorateClientWindow - resize zones need it
    [frame decorateClientWindow];
    [self mapWindow:frame];
    [self registerWindow:window];
    [window updateAttributes];
    [frame setScreen:[window screen]];
    [window setNormalState];
    [frame setNormalState];

    if ([[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]]) {
        [frame stackBelow];
    } else {
        [frame stackAbove];
        [frame raiseResizeHandle];
    }
    [[frame childWindowForKey:TitleBar] setIsAbove:YES];
    [self drawAllTitleBarsExcept:(XCBTitleBar*)[frame childWindowForKey:TitleBar]];
    [icccmService wmClassForWindow:window];
    [frame configureClient];

    [self setNeedFlush:YES];
    window = nil;
    frame = nil;
    request = nil;
    response = nil;
    ewmhService = nil;
    screen = nil;
    visual = nil;
    settings = nil;
}

- (void)handleUnmapRequest:(xcb_unmap_window_request_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    NSLog(@"[%@] Unmap request for window %u", NSStringFromClass([self class]), [window window]);
    [self unmapWindow:window];
    [self setNeedFlush:YES];
    window = nil;
}

- (void)handleConfigureWindowRequest:(xcb_configure_request_event_t *)anEvent
{
    uint16_t config_win_mask = 0;
    uint32_t config_win_vals[7];
    unsigned short i = 0;
    XCBWindow *window = [self windowForXCBId:anEvent->window];

    /*** Handle configure requests (has it is) for windows we don't manage ***/

    if (window == nil || ![window decorated])
    {
        if (anEvent->value_mask & XCB_CONFIG_WINDOW_X)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_X;
            config_win_vals[i++] = anEvent->x;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_Y)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_Y;
            config_win_vals[i++] = anEvent->y;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_WIDTH)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_WIDTH;
            config_win_vals[i++] = anEvent->width;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_HEIGHT)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_HEIGHT;
            config_win_vals[i++] = anEvent->height;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_BORDER_WIDTH)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_BORDER_WIDTH;
            config_win_vals[i++] = anEvent->border_width;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_SIBLING)
        {
            config_win_mask |= XCB_CONFIG_WINDOW_SIBLING;
            config_win_vals[i++] = anEvent->sibling;
        }

        if (anEvent->value_mask & XCB_CONFIG_WINDOW_STACK_MODE)
        {
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
            BOOL isDesktopWindow = window && [[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];

            if (isDesktopWindow && anEvent->stack_mode == XCB_STACK_MODE_ABOVE) {
                NSLog(@"Desktop window %u attempted to stack above - forcing below", anEvent->window);
                config_win_vals[i++] = XCB_STACK_MODE_BELOW;
            } else {
                config_win_vals[i++] = anEvent->stack_mode;
            }
            config_win_mask |= XCB_CONFIG_WINDOW_STACK_MODE;
            ewmhService = nil;
        }

        xcb_configure_window(connection, anEvent->window, config_win_mask, config_win_vals);

        /*** necessary? ***/

        xcb_configure_notify_event_t event;

        event.event = anEvent->window;
        event.window = anEvent->window;
        event.x = anEvent->x;
        event.y = anEvent->y;
        event.border_width = anEvent->border_width;
        event.width = anEvent->width;
        event.height = anEvent->height;
        event.override_redirect = 0;
        event.above_sibling = anEvent->sibling;
        event.response_type = XCB_CONFIGURE_NOTIFY;
        event.sequence = 0;

        window = [[XCBWindow alloc] initWithXCBWindow:anEvent->window andConnection:self];

        [self sendEvent:(const  char*) &event toClient:window propagate:NO];

    }
    else
    {
        [window configureForEvent:anEvent];
    }

    window = nil;
}

- (void)handleConfigureNotify:(xcb_configure_notify_event_t *)anEvent
{
    // NSLog(@"In configure notify for window %u: %d, %d", anEvent->window, anEvent->x, anEvent->y);

}

- (void)handleMotionNotify:(xcb_motion_notify_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->event];
    XCBFrame *frame;

    if (dragState && [window isKindOfClass:[XCBTitleBar class]]
        /*([window window] != [rootWindow window]) &&
        ([[window parentWindow] window] != [rootWindow window])*/)
    {
        frame = (XCBFrame *) [window parentWindow];
        [window grabPointer];

        // Get the destination point from mouse position
        int16_t mouseX = anEvent->root_x;
        int16_t mouseY = anEvent->root_y;
        
        // Calculate frame position (mouse position minus offset)
        XCBPoint offset = [frame offset];
        int16_t frameX = mouseX - offset.x;
        int16_t frameY = mouseY - offset.y;
        
        // Use cached workarea for performance (no X server round-trip)
        if (self.workareaValid) {
            // Minimum pixels of window that must remain visible on each edge
            // This prevents windows from being "lost" off screen
            const int32_t MIN_VISIBLE_PIXELS = 16;

            // Get frame dimensions
            XCBRect frameRect = [frame windowRect];
            uint32_t frameWidth = frameRect.size.width;

            // Constrain frame Y position: don't allow titlebar to go above workarea top
            if (frameY < _cachedWorkareaY) {
                frameY = _cachedWorkareaY;
            }

            // Constrain left edge: at least MIN_VISIBLE_PIXELS must remain on screen
            int32_t minFrameX = _cachedWorkareaX + MIN_VISIBLE_PIXELS - (int32_t)frameWidth;
            if (frameX < minFrameX) {
                frameX = minFrameX;
            }

            // Constrain right edge: at least MIN_VISIBLE_PIXELS must remain on screen
            int32_t maxFrameX = _cachedWorkareaX + (int32_t)_cachedWorkareaWidth - MIN_VISIBLE_PIXELS;
            if (frameX > maxFrameX) {
                frameX = maxFrameX;
            }

            // Constrain bottom edge: at least MIN_VISIBLE_PIXELS must remain on screen
            int32_t maxFrameY = _cachedWorkareaY + (int32_t)_cachedWorkareaHeight - MIN_VISIBLE_PIXELS;
            if (frameY > maxFrameY) {
                frameY = maxFrameY;
            }
        }
        
        // Convert constrained frame position back to mouse coordinates for moveTo:
        // (moveTo will subtract the offset again to get the final frame position)
        int16_t destX = frameX + offset.x;
        int16_t destY = frameY + offset.y;
        XCBPoint destPoint = XCBMakePoint(destX, destY);
        [frame moveTo:destPoint];
        [frame configureClient];

        window = nil;
        frame = nil;
        needFlush = YES;

        return;
    }

    if ([window isKindOfClass:[XCBFrame class]] && !dragState)
    {
        frame = (XCBFrame *)window;
        MousePosition  position = [frame mouseIsOnWindowBorderForEvent:anEvent];

        switch (position)
        {
            case RightBorder:
                if (![[frame cursor] resizeRightSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case LeftBorder:
                if (![[frame cursor] resizeLeftSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case BottomRightCorner:
                if (![[frame cursor] resizeBottomRightCornerSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case TopBorder:
                if (![[frame cursor] resizeTopSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case BottomBorder:
                if (![[frame cursor] resizeBottomSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            default:
                if (![[frame cursor] leftPointerSelected])
                {
                    [frame showLeftPointerCursor];
                }
                break;
        }

    }
    else
    {
        if (![[frame cursor] leftPointerSelected])
        {
            [frame showLeftPointerCursor];
            [window showLeftPointerCursor];

        }
    }


    if (resizeState)
    {
        if ([window isKindOfClass:[XCBFrame class]])
            frame = (XCBFrame *) window;

        [frame resize:anEvent xcbConnection:connection];
        needFlush = YES;
    }

    window = nil;
    frame = nil;
}

- (void)handleButtonPress:(xcb_button_press_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->event];
    XCBFrame *frame;
    XCBTitleBar *titleBar;
    XCBWindow *clientWindow;

    // CRITICAL: Always allow events to prevent frozen pointer/keyboard
    // This must be done EARLY before any logic that might return early
    xcb_allow_events(connection, XCB_ALLOW_REPLAY_POINTER, anEvent->time);

    if (!window) {
        return;
    }

    if ([window isCloseButton])
    {
        XCBFrame *frame = (XCBFrame *) [[window parentWindow] parentWindow];
        currentTime = anEvent->time;

        clientWindow = [frame childWindowForKey:ClientWindow];

        [clientWindow close];
        [frame setNeedDestroy:YES];

        frame = nil;
        window = nil;
        clientWindow = nil;
        return;
    }

    if ([window isMinimizeButton])
    {
        frame = (XCBFrame*)[[window parentWindow] parentWindow];
        [frame minimize];
        frame = nil;
        window = nil;
        return;
    }

    if ([window isMaximizeButton])
    {
        frame = (XCBFrame*)[[window parentWindow] parentWindow];
        titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
        clientWindow = [frame childWindowForKey:ClientWindow];

        if ([frame isMaximized])
        {
            XCBRect startRect = [frame windowRect];
            XCBRect restoredRect = [frame oldRect];  // Get saved pre-maximize rect

            // Use programmatic resize that follows the same code path as manual resize
            [frame programmaticResizeToRect:restoredRect];
            [frame setFullScreen:NO];
            [titleBar setFullScreen:NO];
            [clientWindow setFullScreen:NO];
            [frame setIsMaximized:NO];
            [frame updateAllResizeZonePositions];
            [frame applyRoundedCornersShapeMask];

            {
                Class compositorClass = NSClassFromString(@"URSCompositingManager");
                id<URSCompositingManaging> compositor = nil;
                if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                    compositor = [compositorClass performSelector:@selector(sharedManager)];
                }
                if (compositor && [compositor compositingActive] &&
                    [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
                    XCBRect endRect = [frame windowRect];
                    [compositor animateWindowTransition:[frame window]
                                             fromRect:startRect
                                               toRect:endRect
                                             duration:0.22
                                                 fade:NO];
                }
            }

            clientWindow = nil;
            titleBar = nil;
            frame = nil;
            return;
        }

        XCBScreen *screen = [frame onScreen];
        TitleBarSettingsService *settingsService = [TitleBarSettingsService sharedInstance];
        uint16_t titleHgt = [settingsService heightDefined] ? [settingsService height] : [settingsService defaultHeight];

        // Read workarea from root window to respect struts (e.g., menu bar)
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
        int32_t workareaX = 0, workareaY = 0;
        uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
        
        XCBWindow *rootWindow = [screen rootWindow];
        if ([ewmhService readWorkareaForRootWindow:rootWindow x:&workareaX y:&workareaY width:&workareaWidth height:&workareaHeight]) {
            NSLog(@"[Maximize] Using workarea: x=%d, y=%d, width=%u, height=%u", 
                  workareaX, workareaY, workareaWidth, workareaHeight);
        } else {
            NSLog(@"[Maximize] No workarea set, using full screen: %u x %u", workareaWidth, workareaHeight);
        }

        XCBRect startRect = [frame windowRect];
        /*** Save pre-maximize rect for restore ***/
        [frame setOldRect:startRect];
        [titleBar setOldRect:[titleBar windowRect]];
        [clientWindow setOldRect:[clientWindow windowRect]];

        /*** Use programmatic resize that follows the same code path as manual resize ***/
        XCBRect targetRect = XCBMakeRect(XCBMakePoint(workareaX, workareaY),
                                          XCBMakeSize(workareaWidth, workareaHeight));
        NSLog(@"[Maximize] frame=%u startRect=(%d,%d %u x %u) target=(%d,%d %u x %u)", [frame window], (int)startRect.position.x, (int)startRect.position.y, (unsigned)startRect.size.width, (unsigned)startRect.size.height, (int)targetRect.position.x, (int)targetRect.position.y, (unsigned)targetRect.size.width, (unsigned)targetRect.size.height);
        [frame programmaticResizeToRect:targetRect];
        [frame setFullScreen:YES];
        [frame setIsMaximized:YES];
        [titleBar setFullScreen:YES];
        [clientWindow setFullScreen:YES];
        [titleBar drawTitleBarComponents];

        {
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }
            if (compositor && [compositor compositingActive] &&
                [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
                XCBRect endRect = [frame windowRect];
                [compositor animateWindowTransition:[frame window]
                                         fromRect:startRect
                                           toRect:endRect
                                         duration:0.22
                                             fade:NO];
            }
        }
        
        /*** Update resize zone positions if they exist ***/
        [frame updateAllResizeZonePositions];

        // Log geometry right before flushing and applying shape masks
        NSLog(@"[Maximize] pre-flush geometry frameRect=(%d,%d %u x %u) titleRect=(%d,%d %u x %u) clientRect=(%d,%d %u x %u)",
              (int)[frame windowRect].position.x, (int)[frame windowRect].position.y, (unsigned)[frame windowRect].size.width, (unsigned)[frame windowRect].size.height,
              (int)[titleBar windowRect].position.x, (int)[titleBar windowRect].position.y, (unsigned)[titleBar windowRect].size.width, (unsigned)[titleBar windowRect].size.height,
              (int)[clientWindow windowRect].position.x, (int)[clientWindow windowRect].position.y, (unsigned)[clientWindow windowRect].size.width, (unsigned)[clientWindow windowRect].size.height);

        /*** Flush to ensure X server has processed configure requests ***/
        xcb_flush([self connection]);

        /*** Update shape mask for new dimensions ***/
        [frame applyRoundedCornersShapeMask];
        NSLog(@"[Maximize] applied rounded corners for frame %u", [frame window]);

        ewmhService = nil;
        rootWindow = nil;
        screen = nil;
        window = nil;
        frame = nil;
        clientWindow = nil;
        settingsService = nil;
        titleBar = nil;
        return;
    }

    if ([window isMinimized])
    {
        [window restoreFromIconified];
        window = nil;
        return;
    }

    if ([window isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame *) window;
        clientWindow = [frame childWindowForKey:ClientWindow];
    }

    if ([window isKindOfClass:[XCBTitleBar class]])
    {
        frame = (XCBFrame *) [window parentWindow];
        clientWindow = [frame childWindowForKey:ClientWindow];
    }

    if ([window isKindOfClass:[XCBWindow class]] &&
        [[window parentWindow] isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame *) [window parentWindow];
        clientWindow = [frame childWindowForKey:ClientWindow];

        // Check if this is the resize handle - if so, use client window for active window
        XCBWindow *resizeHandle = [frame childWindowForKey:ResizeHandle];
        BOOL isResizeHandle = (resizeHandle && [resizeHandle window] == [window window]);

        // Set expected focus to prevent handleFocusIn: from making a duplicate update
        XCBWindow *targetWindow = isResizeHandle ? clientWindow : window;
        self.expectedFocusWindow = [targetWindow window];
        self.expectedFocusTimestamp = currentTime;

        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
        // Use client window for active window, not the resize handle
        [ewmhService updateNetActiveWindow:targetWindow];
        ewmhService = nil;
        resizeHandle = nil;

    }

    // Check if this is a menu-type window - don't change focus for menus
    // as this would interfere with how GNUstep/AppKit manages menu focus
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    NSString *windowType = [window windowType];
    BOOL isMenuWindow = [windowType isEqualToString:[ewmhService EWMHWMWindowTypeMenu]] ||
                        [windowType isEqualToString:[ewmhService EWMHWMWindowTypePopupMenu]] ||
                        [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDropdownMenu]];
    
    // Check if this is a desktop window - don't raise desktop windows
    BOOL isDesktopWindow = [windowType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];
    // Also check clientWindow's type in case window is undecorated
    if (!isDesktopWindow && clientWindow) {
        NSString *clientType = [clientWindow windowType];
        isDesktopWindow = [clientType isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];
    }
    ewmhService = nil;
    
    if (isMenuWindow) {
        // For menu windows, just return - let the application handle its own menu events
        window = nil;
        clientWindow = nil;
        return;
    }

    // CRITICAL: ALWAYS set focus when clicking on a window
    // This ensures that no matter what, clicking allows typing in that window
    if (clientWindow && frame) {
        NSLog(@"[ACTIVATE] Button press on frame %u - focusing client window %u", [frame window], [clientWindow window]);
        [clientWindow focus];
        NSLog(@"[ACTIVATE] Client window focused, now raising frame");
        // Don't raise desktop windows - they should always stay at the bottom
        if (!isDesktopWindow) {
            [frame stackAbove];
            [frame raiseResizeHandle];
            NSLog(@"[ACTIVATE] Frame raised");
        }
    } else if (window && [window isKindOfClass:[XCBWindow class]]) {
        // Fallback: If we couldn't find client/frame but have a window, focus it directly
        [window focus];
        // Don't raise desktop windows - they should always stay at the bottom
        if (!isDesktopWindow) {
            uint32_t values[] = { XCB_STACK_MODE_ABOVE };
            xcb_configure_window(connection, [window window], XCB_CONFIG_WINDOW_STACK_MODE, values);
            [self flush];
        }
    } else {
        // Last resort: ungrab keyboard to prevent being stuck
        xcb_ungrab_keyboard(connection, XCB_CURRENT_TIME);
        [self flush];
        return;
    }

    // Only proceed with frame-specific operations if we have a valid frame
    if (!frame) {
        window = nil;
        clientWindow = nil;
        return;
    }

    titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar];
    [titleBar setIsAbove:YES];
    [titleBar setButtonsAbove:YES];
    [titleBar drawTitleBarComponents];
    [self drawAllTitleBarsExcept:titleBar];

    XCBRect frameRect = [frame windowRect];
    XCBPoint relativeOffset = XCBMakePoint(anEvent->root_x - frameRect.position.x, anEvent->root_y - frameRect.position.y);
    [frame setOffset:relativeOffset];
    NSLog(@"CLICK: Setting offset to relative coords (%d, %d) from frame position (%d, %d)",
          (int)relativeOffset.x, (int)relativeOffset.y, (int)frameRect.position.x, (int)frameRect.position.y);

    if ([frame window] != anEvent->root && [[frame childWindowForKey:ClientWindow] canMove])
    {
        dragState = YES;
        
        // Cache workarea when drag starts for performance
        XCBScreen *screen = [frame onScreen];
        if (screen) {
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
            XCBWindow *rootWindow = [screen rootWindow];
            self.workareaValid = [ewmhService readWorkareaForRootWindow:rootWindow 
                                                                      x:&_cachedWorkareaX 
                                                                      y:&_cachedWorkareaY 
                                                                  width:&_cachedWorkareaWidth 
                                                                 height:&_cachedWorkareaHeight];
            if (!self.workareaValid) {
                // No workarea set, use full screen
                _cachedWorkareaX = 0;
                _cachedWorkareaY = 0;
                _cachedWorkareaWidth = [screen width];
                _cachedWorkareaHeight = [screen height];
                self.workareaValid = YES;
            }
            ewmhService = nil;
            rootWindow = nil;
        } else {
            self.workareaValid = NO;
        }
    }
    else
        dragState = NO;


    /*** RESIZE WINDOW BY CLICKING ON THE BORDER ***/

    if ([titleBar window] != anEvent->event && [[frame childWindowForKey:ClientWindow] canResize])
    {
        // Check if click is on any resize zone (new theme-driven zones or legacy handle)
        BOOL handledResizeZone = NO;
        xcb_window_t clickedWindow = anEvent->event;

        // Check legacy resize handle (SE corner)
        XCBWindow *resizeHandle = [frame childWindowForKey:ResizeHandle];
        if (resizeHandle && [resizeHandle window] == clickedWindow) {
            [frame setBottomBorderClicked:YES];
            [frame setRightBorderClicked:YES];
            handledResizeZone = YES;
        }

        // Check theme-driven resize zones
        // SE corner
        XCBWindow *zoneSE = [frame childWindowForKey:ResizeZoneSE];
        if (!handledResizeZone && zoneSE && [zoneSE window] == clickedWindow) {
            [frame setBottomBorderClicked:YES];
            [frame setRightBorderClicked:YES];
            handledResizeZone = YES;
        }

        // NW corner
        XCBWindow *zoneNW = [frame childWindowForKey:ResizeZoneNW];
        if (!handledResizeZone && zoneNW && [zoneNW window] == clickedWindow) {
            [frame setTopBorderClicked:YES];
            [frame setLeftBorderClicked:YES];
            handledResizeZone = YES;
        }

        // NE corner
        XCBWindow *zoneNE = [frame childWindowForKey:ResizeZoneNE];
        if (!handledResizeZone && zoneNE && [zoneNE window] == clickedWindow) {
            [frame setTopBorderClicked:YES];
            [frame setRightBorderClicked:YES];
            handledResizeZone = YES;
        }

        // SW corner
        XCBWindow *zoneSW = [frame childWindowForKey:ResizeZoneSW];
        if (!handledResizeZone && zoneSW && [zoneSW window] == clickedWindow) {
            [frame setBottomBorderClicked:YES];
            [frame setLeftBorderClicked:YES];
            handledResizeZone = YES;
        }

        // N edge
        XCBWindow *zoneN = [frame childWindowForKey:ResizeZoneN];
        if (!handledResizeZone && zoneN && [zoneN window] == clickedWindow) {
            [frame setTopBorderClicked:YES];
            handledResizeZone = YES;
        }

        // S edge
        XCBWindow *zoneS = [frame childWindowForKey:ResizeZoneS];
        if (!handledResizeZone && zoneS && [zoneS window] == clickedWindow) {
            [frame setBottomBorderClicked:YES];
            handledResizeZone = YES;
        }

        // E edge
        XCBWindow *zoneE = [frame childWindowForKey:ResizeZoneE];
        if (!handledResizeZone && zoneE && [zoneE window] == clickedWindow) {
            [frame setRightBorderClicked:YES];
            handledResizeZone = YES;
        }

        // W edge
        XCBWindow *zoneW = [frame childWindowForKey:ResizeZoneW];
        if (!handledResizeZone && zoneW && [zoneW window] == clickedWindow) {
            [frame setLeftBorderClicked:YES];
            handledResizeZone = YES;
        }

        // Grow box zone (overlays SE corner with larger size)
        XCBWindow *zoneGrowBox = [frame childWindowForKey:ResizeZoneGrowBox];
        if (!handledResizeZone && zoneGrowBox && [zoneGrowBox window] == clickedWindow) {
            [frame setBottomBorderClicked:YES];
            [frame setRightBorderClicked:YES];
            handledResizeZone = YES;
        }

        if (handledResizeZone) {
            if ([frame grabPointer]) {
                resizeState = YES;
                dragState = NO;
            }
        } else {
            // Check border clicks (fallback for clicking on frame borders directly)
            [self borderClickedForFrameWindow:frame withEvent:anEvent];
        }
    }

    frame = nil;
    window = nil;
    titleBar = nil;
    clientWindow = nil;
}

- (void)handleButtonRelease:(xcb_button_release_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->event];
    XCBFrame *frame;

    if ([window isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame *) window;
        [frame setBottomBorderClicked:NO];
        [frame setRightBorderClicked:NO];
        [frame setLeftBorderClicked:NO];
        [frame setTopBorderClicked:NO];
        [frame showLeftPointerCursor];
        [window showLeftPointerCursor];

        if (resizeState)
        {
            [frame refreshBorder];
            [frame configureClient];
        }
    }

    /*if (resizeState && [window isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame*) window;
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        [frame description];
        [clientWindow description];
        [frame refreshBorder];
        [frame configureClient];

        clientWindow = nil;
    }*/

    [window ungrabPointer];
    dragState = NO;
    self.workareaValid = NO;  // Clear cached workarea
    resizeState = NO;
    window = nil;
    frame = nil;
}

- (void)handleFocusOut:(xcb_focus_out_event_t *)anEvent
{
    NSLog(@"Focus Out event for window: %u", anEvent->event);
}

- (void)handleFocusIn:(xcb_focus_in_event_t *)anEvent
{
    // Update _NET_ACTIVE_WINDOW when focus changes (e.g., from Alt-Tab)
    // Only handle focus changes that aren't from pointer grabs to avoid feedback loops
    if (anEvent->mode == XCB_NOTIFY_MODE_NORMAL || anEvent->mode == XCB_NOTIFY_MODE_WHILE_GRABBED) {
        // Clear stale expected focus (older than 100ms)
        // xcb_timestamp_t is in milliseconds from server
        if (self.expectedFocusWindow != 0 &&
            self.expectedFocusTimestamp != 0 &&
            currentTime > self.expectedFocusTimestamp &&
            (currentTime - self.expectedFocusTimestamp) > 100) {
            NSLog(@"[FOCUS] handleFocusIn: Clearing stale expected focus (age: %u ms)",
                  (unsigned int)(currentTime - self.expectedFocusTimestamp));
            self.expectedFocusWindow = 0;
            self.expectedFocusTimestamp = 0;
        }

        XCBWindow *window = [self windowForXCBId:anEvent->event];
        if (window) {
            // Determine the target window for _NET_ACTIVE_WINDOW
            xcb_window_t targetWindowId = 0;
            XCBWindow *targetWindow = nil;

            // If this is a frame window, get the client window
            if ([window isKindOfClass:[XCBFrame class]]) {
                XCBFrame *frame = (XCBFrame *)window;
                XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
                if (clientWindow) {
                    targetWindowId = [clientWindow window];
                    targetWindow = clientWindow;
                }
            }
            // If this is a client window directly, use it
            else if ([window decorated]) {
                targetWindowId = [window window];
                targetWindow = window;
            }

            if (targetWindow != nil && targetWindowId != 0) {
                // Check if this FocusIn is from our own focus call
                if (targetWindowId == self.expectedFocusWindow) {
                    // Skip - this FocusIn is from our own explicit focus call
                    // The updateNetActiveWindow was already called in the focus method
                    NSLog(@"[FOCUS] handleFocusIn: Skipping expected window %u (already updated)", targetWindowId);
                } else {
                    // External focus change - do the update
                    NSLog(@"[FOCUS] handleFocusIn: External focus to %u", targetWindowId);
                    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
                    [ewmhService updateNetActiveWindow:targetWindow];
                    ewmhService = nil;
                }
                // Clear expected focus after processing
                self.expectedFocusWindow = 0;
                self.expectedFocusTimestamp = 0;
            }
        }
    }
}

- (void) handlePropertyNotify:(xcb_property_notify_event_t*)anEvent
{
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:self];

    NSString *name = [atomService atomNameFromAtom:anEvent->atom];
    NSLog(@"Property changed for window: %u, with name: %@", anEvent->window, name);

    XCBWindow *window = [self windowForXCBId:anEvent->window];

    if (!window)
    {
        atomService = nil;
        name = nil;
        return;
    }

    if ([name isEqualToString:@"WM_HINTS"])
    {
        [window refreshCachedWMHints];
    }

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];

    if ([name isEqualToString:[ewmhService EWMHWMWindowType]])
    {
        void *windowTypeReply = [ewmhService getProperty:[ewmhService EWMHWMWindowType]
                                            propertyType:XCB_ATOM_ATOM
                                               forWindow:window
                                                  delete:NO
                                                  length:UINT32_MAX];
        if (windowTypeReply)
        {
            xcb_atom_t *atom = (xcb_atom_t *) xcb_get_property_value(windowTypeReply);

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDesktop]])
            {
                NSLog(@"PropertyNotify: Window %u identified as desktop type - stacking below", anEvent->window);
                [window setWindowType:[ewmhService EWMHWMWindowTypeDesktop]];
                [window stackBelow];
            }
            free(windowTypeReply);
        }
    }
    
    // Handle _NET_WORKAREA changes on root window to update cached workarea
    XCBScreen *screen = [[self screens] objectAtIndex:0];
    XCBWindow *rootWindow = [screen rootWindow];
    if ([name isEqualToString:[ewmhService EWMHWorkarea]] && anEvent->window == [rootWindow window])
    {
        NSLog(@"PropertyNotify: _NET_WORKAREA changed on root window - updating cached workarea");
        if (screen && rootWindow) {
            self.workareaValid = [ewmhService readWorkareaForRootWindow:rootWindow 
                                                                      x:&_cachedWorkareaX 
                                                                      y:&_cachedWorkareaY 
                                                                  width:&_cachedWorkareaWidth 
                                                                 height:&_cachedWorkareaHeight];
            if (!self.workareaValid) {
                // Fallback to full screen if workarea read fails
                _cachedWorkareaX = 0;
                _cachedWorkareaY = 0;
                _cachedWorkareaWidth = [screen width];
                _cachedWorkareaHeight = [screen height];
            }
        }
    }

    ewmhService = nil;
    atomService = nil;
    name = nil;
    window = nil;

    return;
}

- (BOOL)resolveIconGeometryForWindow:(XCBWindow *)window outRect:(XCBRect *)rectOut
{
    if (!window || !rectOut) {
        return NO;
    }

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    xcb_get_property_reply_t *reply = [ewmhService getProperty:[ewmhService EWMHWMIconGeometry]
                                                  propertyType:XCB_ATOM_CARDINAL
                                                     forWindow:window
                                                        delete:NO
                                                        length:4];
    if (reply) {
        int len = xcb_get_property_value_length(reply);
        if (len >= (int)(sizeof(uint32_t) * 4)) {
            uint32_t *values = (uint32_t *)xcb_get_property_value(reply);
            XCBPoint pos = XCBMakePoint(values[0], values[1]);
            XCBSize size = XCBMakeSize((uint16_t)values[2], (uint16_t)values[3]);
            if (size.width > 0 && size.height > 0) {
                *rectOut = XCBMakeRect(pos, size);
                free(reply);
                return YES;
            }
        }
        free(reply);
    }

    XCBScreen *screen = [window onScreen];
    if (!screen) {
        return NO;
    }

    uint16_t iconSize = 48;
    double x = ((double)[screen width] - iconSize) * 0.5;
    double y = (double)[screen height] - iconSize;
    *rectOut = XCBMakeRect(XCBMakePoint(x, y), XCBMakeSize(iconSize, iconSize));
    return NO;
}

- (void)handleClientMessage:(xcb_client_message_event_t *)anEvent
{
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:self];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    NSString *atomMessageName = [atomService atomNameFromAtom:anEvent->type];

    NSLog(@"Atom name: %@, for atom id: %u", atomMessageName, anEvent->type);

    XCBWindow *window;
    XCBTitleBar *titleBar;
    XCBFrame *frame;
    XCBWindow *clientWindow;

    ICCCMService *icccmService = [ICCCMService sharedInstanceWithConnection:self];
    window = [self windowForXCBId:anEvent->window];

    if (window == nil && frame == nil && titleBar == nil)
    {
        if ([ewmhService ewmhClientMessage:atomMessageName])
        {
            window = [[XCBWindow alloc] initWithXCBWindow:anEvent->window andConnection:self];
            [ewmhService handleClientMessage:atomMessageName forWindow:window data:anEvent->data];
        }

        atomService = nil;
        ewmhService = nil;
        atomMessageName = nil;
        window = nil;
        return;
    }
    else if (window)
    {
        if ([ewmhService ewmhClientMessage:atomMessageName])
        {
            [ewmhService handleClientMessage:atomMessageName forWindow:window data:anEvent->data];

            if ([[window parentWindow] isKindOfClass:[XCBFrame class]]) //TODO: debUg to see if this is still necessary!!
            {
                frame = (XCBFrame *) [window parentWindow];
                [frame stackAbove];
                [frame raiseResizeHandle];
                titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar]; //TODO: Can i put all this in a single method?
                [titleBar drawTitleBarComponents];
                [self drawAllTitleBarsExcept:titleBar];
            }
        }
    }


    if ([window isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame *) [self windowForXCBId:anEvent->window];
        titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar]; //FIXME: just cast!
        clientWindow = [frame childWindowForKey:ClientWindow];
    }
    else if ([window isKindOfClass:[XCBTitleBar class]])
    {
        titleBar = (XCBTitleBar *) [self windowForXCBId:anEvent->window]; //FIXME: just cast!
        frame = (XCBFrame *) [titleBar parentWindow];
        clientWindow = [frame childWindowForKey:ClientWindow];
    }
    else if ([window isKindOfClass:[XCBWindow class]])
    {
        window = [self windowForXCBId:anEvent->window]; // FIXME: ??????

        if ([window decorated])
        {
            frame = (XCBFrame *) [window parentWindow];
            titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar];
            clientWindow = [frame childWindowForKey:ClientWindow];
        }
    }


    if (anEvent->type == [atomService atomFromCachedAtomsWithKey:[icccmService WMChangeState]] &&
        anEvent->format == 32 &&
        anEvent->data.data32[0] == ICCCM_WM_STATE_ICONIC &&
        ![frame isMinimized])
    {
        NSLog(@"[WM_CHANGE_STATE] Minimizing window %u - just hiding", anEvent->window);

        XCBWindow *targetWindow = frame ? (XCBWindow *)frame : window;
        if (targetWindow) {
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }
            if (compositor && [compositor compositingActive]) {
                XCBWindow *iconWindow = clientWindow ? clientWindow : targetWindow;
                XCBRect iconRect = XCBInvalidRect;
                [self resolveIconGeometryForWindow:iconWindow outRect:&iconRect];
                XCBRect startRect = [targetWindow windowRect];
                [compositor animateWindowMinimize:[targetWindow window]
                                        fromRect:startRect
                                          toRect:iconRect];
            }
        }

        // Simply hide the windows - no preview, no mini window
        if (frame != nil)
        {
            [frame setIconicState];
            [frame setIsMinimized:YES];
            [self unmapWindow:frame];
        }

        if (titleBar != nil)
        {
            [self unmapWindow:titleBar];
        }

        if (clientWindow)
        {
            [clientWindow setIconicState];
            [clientWindow setIsMinimized:YES];
            [self unmapWindow:clientWindow];
        }

        NSLog(@"[WM_CHANGE_STATE] Window minimized (hidden)");
    }
    else if ([frame isMinimized] &&
             anEvent->type == [atomService atomFromCachedAtomsWithKey:[icccmService WMChangeState]] &&
             anEvent->format == 32 &&
             anEvent->data.data32[0] != ICCCM_WM_STATE_ICONIC)
    {
        NSLog(@"[WM_CHANGE_STATE] Restoring window %u", anEvent->window);

        if (frame != nil)
        {
            [self mapWindow:frame];
            [frame setIsMinimized:NO];
            [frame setNormalState];
        }

        if (titleBar != nil)
        {
            [self mapWindow:titleBar];
            [titleBar drawTitleBarComponents];
        }

        if (clientWindow)
        {
            [self mapWindow:clientWindow];
            [clientWindow setIsMinimized:NO];
            [clientWindow setNormalState];
        }

        XCBWindow *restoreTarget = frame ? (XCBWindow *)frame : window;
        if (restoreTarget) {
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }
            if (compositor && [compositor compositingActive]) {
                XCBWindow *iconWindow = clientWindow ? clientWindow : restoreTarget;
                XCBRect iconRect = XCBInvalidRect;
                [self resolveIconGeometryForWindow:iconWindow outRect:&iconRect];
                XCBRect endRect = [restoreTarget windowRect];
                [compositor animateWindowRestore:[restoreTarget window]
                                       fromRect:iconRect
                                         toRect:endRect];
            }
        }

        [frame stackAbove];
        [frame raiseResizeHandle];
        [clientWindow focus];
        [self drawAllTitleBarsExcept:titleBar];

        NSLog(@"[WM_CHANGE_STATE] Window restored");
    }

    window = nil;
    titleBar = nil;
    frame = nil;
    clientWindow = nil;
    atomService = nil;
    atomMessageName = nil;
    ewmhService = nil;
    icccmService = nil;

    return;
}

- (void)handleEnterNotify:(xcb_enter_notify_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->event];

    if ([window isKindOfClass:[XCBWindow class]] &&
        [[window parentWindow] isKindOfClass:[XCBFrame class]])
    {
        [window grabButton];
        
        // Check if this is the resize handle - change cursor to resize cursor
        XCBFrame *frameWindow = (XCBFrame *)[window parentWindow];
        XCBWindow *resizeHandle = [frameWindow childWindowForKey:ResizeHandle];
        if (resizeHandle && [resizeHandle window] == anEvent->event) {
            // Mouse entered the resize handle - show resize cursor
            [frameWindow showResizeCursorForPosition:BottomRightCorner];
        }

        // Theme-driven resize zones
        XCBWindow *zoneN = [frameWindow childWindowForKey:ResizeZoneN];
        XCBWindow *zoneS = [frameWindow childWindowForKey:ResizeZoneS];
        XCBWindow *zoneE = [frameWindow childWindowForKey:ResizeZoneE];
        XCBWindow *zoneW = [frameWindow childWindowForKey:ResizeZoneW];
        XCBWindow *zoneNE = [frameWindow childWindowForKey:ResizeZoneNE];
        XCBWindow *zoneNW = [frameWindow childWindowForKey:ResizeZoneNW];
        XCBWindow *zoneSE = [frameWindow childWindowForKey:ResizeZoneSE];
        XCBWindow *zoneSW = [frameWindow childWindowForKey:ResizeZoneSW];
        XCBWindow *zoneGrowBox = [frameWindow childWindowForKey:ResizeZoneGrowBox];

        if (zoneN && [zoneN window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:TopBorder];
        else if (zoneS && [zoneS window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:BottomBorder];
        else if (zoneE && [zoneE window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:RightBorder];
        else if (zoneW && [zoneW window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:LeftBorder];
        else if (zoneNE && [zoneNE window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:TopRightCorner];
        else if (zoneNW && [zoneNW window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:TopLeftCorner];
        else if (zoneSE && [zoneSE window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:BottomRightCorner];
        else if (zoneSW && [zoneSW window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:BottomLeftCorner];
        else if (zoneGrowBox && [zoneGrowBox window] == anEvent->event)
            [frameWindow showResizeCursorForPosition:BottomRightCorner];

        frameWindow = nil;
        resizeHandle = nil;
    }

    if ([window isKindOfClass:[XCBFrame class]])
    {
        XCBFrame *frameWindow = (XCBFrame *) window;
        XCBWindow *clientWindow = [frameWindow childWindowForKey:ClientWindow];

        [clientWindow grabButton];
        clientWindow = nil;
        frameWindow = nil;
    }

    if ([window isKindOfClass:[XCBTitleBar class]])
    {
        XCBTitleBar *titleBar = (XCBTitleBar *) window;
        XCBFrame *frameWindow = (XCBFrame *) [titleBar parentWindow];
        XCBWindow *clientWindow = [frameWindow childWindowForKey:ClientWindow];

        [clientWindow grabButton];

        titleBar = nil;
        frameWindow = nil;
        clientWindow = nil;
    }
    
    // Handle undecorated windows (no frame parent) - these still need button grabs
    // so we can track focus changes for _NET_ACTIVE_WINDOW
    if (window && [window isKindOfClass:[XCBWindow class]] && ![window decorated])
    {
        // Check if parent is not a frame (undecorated window)
        XCBWindow *parent = [window parentWindow];
        if (!parent || ![parent isKindOfClass:[XCBFrame class]])
        {
            [window grabButton];
            NSLog(@"[EnterNotify] Grabbed button on undecorated window %u", [window window]);
        }
    }

    window = nil;
}

- (void)handleLeaveNotify:(xcb_leave_notify_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->event];

    if ([window isKindOfClass:[XCBWindow class]] &&
        [[window parentWindow] isKindOfClass:[XCBFrame class]])
    {
        // Check if this is the resize handle - change cursor back to normal pointer
        XCBFrame *frameWindow = (XCBFrame *)[window parentWindow];
        XCBWindow *resizeHandle = [frameWindow childWindowForKey:ResizeHandle];
        if (resizeHandle && [resizeHandle window] == anEvent->event) {
            // Mouse left the resize handle - show normal pointer cursor
            [frameWindow showLeftPointerCursor];
        }

        // Theme-driven resize zones - restore cursor when leaving
        XCBWindow *zoneN = [frameWindow childWindowForKey:ResizeZoneN];
        XCBWindow *zoneS = [frameWindow childWindowForKey:ResizeZoneS];
        XCBWindow *zoneE = [frameWindow childWindowForKey:ResizeZoneE];
        XCBWindow *zoneW = [frameWindow childWindowForKey:ResizeZoneW];
        XCBWindow *zoneNE = [frameWindow childWindowForKey:ResizeZoneNE];
        XCBWindow *zoneNW = [frameWindow childWindowForKey:ResizeZoneNW];
        XCBWindow *zoneSE = [frameWindow childWindowForKey:ResizeZoneSE];
        XCBWindow *zoneSW = [frameWindow childWindowForKey:ResizeZoneSW];
        XCBWindow *zoneGrowBox = [frameWindow childWindowForKey:ResizeZoneGrowBox];

        if ((zoneN && [zoneN window] == anEvent->event) ||
            (zoneS && [zoneS window] == anEvent->event) ||
            (zoneE && [zoneE window] == anEvent->event) ||
            (zoneW && [zoneW window] == anEvent->event) ||
            (zoneNE && [zoneNE window] == anEvent->event) ||
            (zoneNW && [zoneNW window] == anEvent->event) ||
            (zoneSE && [zoneSE window] == anEvent->event) ||
            (zoneSW && [zoneSW window] == anEvent->event) ||
            (zoneGrowBox && [zoneGrowBox window] == anEvent->event))
        {
            [frameWindow showLeftPointerCursor];
        }

        frameWindow = nil;
        resizeHandle = nil;
    }

    window = nil;
}

- (void)handleVisibilityEvent:(xcb_visibility_notify_event_t *)anEvent
{
    /*XCBWindow *window = [self windowForXCBId:anEvent->window];
    XCBFrame *frame;
    XCBWindow *clientWindow;
    XCBTitleBar* titleBar;*/

    /*if ([window isKindOfClass:[XCBFrame class]])
    {
        frame = (XCBFrame *) window;
        clientWindow = [frame childWindowForKey:ClientWindow];
    }*/

    /*if (anEvent->state == XCB_VISIBILITY_UNOBSCURED &&
        anEvent->window == [frame window] &&
        [frame isAbove])
    {
        if ([clientWindow pixmap] == 0)
            [clientWindow createPixmap];
    }*/

    /*window = nil;
    clientWindow = nil;
    titleBar = nil;*/
}

- (void)handleExpose:(xcb_expose_event_t *)anEvent
{
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    [window onScreen];
    XCBTitleBar *titleBar;
    XCBRect area;
    XCBPoint position;
    XCBSize size;

    //NSLog(@"EXPOSE EVENT FOR WINDOW: %u of kind: %@", [window window], NSStringFromClass([window class]));

    /*if ([window isKindOfClass:[XCBWindow class]] && [[window parentWindow] isKindOfClass:[XCBFrame class]])
    {
        //TODO: frame needs a pixmap too.
        NSLog(@"EXPOSE EVENT FOR WINDOW: %u of kind: %@", [window window], NSStringFromClass([window class]));
        XCBFrame *frame = (XCBFrame*)window;
        position = XCBMakePoint(anEvent->x, anEvent->y);
        size = XCBMakeSize(anEvent->width, anEvent->height);
        area = XCBMakeRect(position, size);
        [window drawArea:area];
    }*/

    if ([window isMaximizeButton])
    {
        titleBar = (XCBTitleBar*) [window parentWindow];
        position = XCBMakePoint(anEvent->x, anEvent->y);
        size = XCBMakeSize(anEvent->width, anEvent->height);
        area = XCBMakeRect(position, size);
        [[titleBar maximizeWindowButton] drawArea:area];
    }

    if ([window isCloseButton])
    {
        titleBar = (XCBTitleBar*) [window parentWindow];
        position = XCBMakePoint(anEvent->x, anEvent->y);
        size = XCBMakeSize(anEvent->width, anEvent->height);
        area = XCBMakeRect(position, size);
        [[titleBar hideWindowButton] drawArea:area];
    }

    if ([window isMinimizeButton])
    {
        titleBar = (XCBTitleBar*) [window parentWindow];
        position = XCBMakePoint(anEvent->x, anEvent->y);
        size = XCBMakeSize(anEvent->width, anEvent->height);
        area = XCBMakeRect(position, size);
        [[titleBar minimizeWindowButton] drawArea:area];
    }

    if ([window isKindOfClass:[XCBTitleBar class]])
    {
        //NSLog(@"EXPOSE EVENT FOR WINDOW: %u of kind: %@", [window window], NSStringFromClass([window class]));
        titleBar = (XCBTitleBar *) window;

        if (!resizeState)
        {
            /*[titleBar drawTitleBarComponents[[titleBar parentWindow] isAbove] ? TitleBarUpColor
                                                                                       : TitleBarDownColor];*/
            position = XCBMakePoint(anEvent->x, anEvent->y);
            size = XCBMakeSize(anEvent->width, anEvent->height);
            area = XCBMakeRect(position, size);
            [titleBar drawArea:area];
        }
        else if (resizeState && anEvent->count == 0)
        {
            /*xcb_copy_area(connection,
                          [titleBar pixmap],
                          [titleBar window],
                          [titleBar graphicContextId],
                          0,
                          0,
                          anEvent->x,
                          anEvent->y,
                          anEvent->width,
                          anEvent->height);*/
            //[titleBar setTitleIsSet:NO];
            //[titleBar setWindowTitle:[titleBar windowTitle]];
            /* [titleBar drawArcsForColor:[[titleBar parentWindow] isAbove] ? TitleBarUpColor
                                                                         : TitleBarDownColor];*/
            position = XCBMakePoint(anEvent->x, anEvent->y);
            size = XCBMakeSize(anEvent->width, anEvent->height);
            area = XCBMakeRect(position, size);
            [titleBar drawArea:area];
        }

    }

    window = nil;
    titleBar = nil;
}

- (void)handleReparentNotify:(xcb_reparent_notify_event_t *)anEvent
{
    NSLog(@"Reparent Notify for window: %u", anEvent->window);

    XCBWindow *window = [self windowForXCBId:anEvent->window];
    XCBWindow *parent = [self windowForXCBId:anEvent->parent];

    if (parent == nil)
        parent = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];

    [window setParentWindow:parent];

    window = nil;
    parent = nil;
}

- (void)handleDestroyNotify:(xcb_destroy_notify_event_t *)anEvent
{
    /* case to handle:
     * the window is a client window: get the frame
     * the window is a title bar child button window: get the frame from the title bar
     * after getting the frame:
     * unregister title bar, title bar children and client window.
     */

    XCBWindow *window = [self windowForXCBId:anEvent->window];
    XCBFrame *frameWindow = nil;
    XCBTitleBar *titleBarWindow = nil;
    XCBWindow *clientWindow = nil;

    if ([window isKindOfClass:[XCBFrame class]])
    {
        frameWindow = (XCBFrame *) window;
        titleBarWindow = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
        clientWindow = [frameWindow childWindowForKey:ClientWindow];
    }

    if ([window isKindOfClass:[XCBWindow class]])
    {
        if ([[window parentWindow] isKindOfClass:[XCBFrame class]]) /* then is the client window */
        {
            frameWindow = (XCBFrame *) [window parentWindow];
            clientWindow = window;
            titleBarWindow = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
            [frameWindow setNeedDestroy:YES]; /* at this point maybe i can avoid to force this to YES */
        }

        if ([[window parentWindow] isKindOfClass:[XCBTitleBar class]]) /* then is the client window */
        {
            frameWindow = (XCBFrame *) [[window parentWindow] parentWindow];
            [frameWindow setNeedDestroy:YES]; /* at this point maybe i can avoid to force this to YES */
            titleBarWindow = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
            clientWindow = [frameWindow childWindowForKey:ClientWindow];
        }

    }

    if ([window isKindOfClass:[XCBTitleBar class]])
    {
        titleBarWindow = (XCBTitleBar *) window;
        frameWindow = (XCBFrame *) [titleBarWindow parentWindow];
        clientWindow = [frameWindow childWindowForKey:ClientWindow];
    }

    if (frameWindow != nil &&
        [frameWindow needDestroy]) /*evaluete if the check on destroy window is necessary or not */
    {
        titleBarWindow = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
        [self unregisterWindow:[titleBarWindow hideWindowButton]];
        [self unregisterWindow:[titleBarWindow minimizeWindowButton]];
        [self unregisterWindow:[titleBarWindow maximizeWindowButton]];
        [self unregisterWindow:titleBarWindow];
        [self unregisterWindow:clientWindow];
        [[frameWindow getChildren] removeAllObjects];
        [frameWindow destroy];
    }

    [self unregisterWindow:window];


    frameWindow = nil;
    titleBarWindow = nil;
    window = nil;
    clientWindow = nil;

    return;
}

- (void)borderClickedForFrameWindow:(XCBFrame *)aFrame withEvent:(xcb_button_press_event_t *)anEvent
{
    int rightBorder = [aFrame windowRect].size.width;
    int bottomBorder = [aFrame windowRect].size.height;
    int leftBorder = [aFrame windowRect].position.x;
    int topBorder = [aFrame windowRect].position.y;

    if (rightBorder == anEvent->event_x || (rightBorder - 1) < anEvent->event_x)
    {
        if (![aFrame grabPointer])
        {
            NSLog(@"Unable to grab the pointer");
            return;
        }

        resizeState = YES;
        dragState = NO;
        [aFrame setRightBorderClicked:YES];
    }

    if (bottomBorder == anEvent->event_y || (bottomBorder - 1) < anEvent->event_y)
    {
        if (![aFrame grabPointer])
        {
            NSLog(@"Unable to grab the pointer");
            return;
        }

        resizeState = YES;
        dragState = NO;
        [aFrame setBottomBorderClicked:YES];

    }

    if ((bottomBorder == anEvent->event_y || (bottomBorder - 1) < anEvent->event_y) &&
        (rightBorder == anEvent->event_x || (rightBorder - 1) < anEvent->event_x))
    {
        if (![aFrame grabPointer])
        {
            NSLog(@"Unable to grab the pointer");
            return;
        }

        resizeState = YES;
        dragState = NO;
        [aFrame setBottomBorderClicked:YES];
        [aFrame setRightBorderClicked:YES];
    }

    if (leftBorder == anEvent->root_x || (leftBorder + 3) > anEvent->root_x)
    {
        if (![aFrame grabPointer])
        {
            NSLog(@"Unable to grab the pointer");
            return;
        }

        resizeState = YES;
        dragState = NO;

        [aFrame setLeftBorderClicked:YES];
    }

    if (topBorder == anEvent->root_y)
    {
        if (![aFrame grabPointer])
        {
            NSLog(@"Unable to grab the pointer");
            return;
        }

        resizeState = YES;
        dragState = NO;

        [aFrame setTopBorderClicked:YES];
    }

}

- (void)drawAllTitleBarsExcept:(XCBTitleBar *)aTitileBar
{
    NSArray *windows = [windowsMap allValues];
    NSUInteger size = [windows count];

    for (int i = 0; i < size; i++)
    {
        XCBWindow *tmp = [windows objectAtIndex:i];

        if ([tmp isKindOfClass:[XCBTitleBar class]])
        {
            XCBTitleBar *titleBar = (XCBTitleBar *) tmp;

            if (titleBar != aTitileBar)
            {
                XCBFrame *frame = (XCBFrame *) [titleBar parentWindow];
                XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];

                if ([clientWindow alwaysOnTop])
                {
                    NSLog(@"Always on top");
                    windows = nil;
                    tmp = nil;
                    frame = nil;
                    clientWindow = nil;
                    titleBar = nil;
                    continue;
                }

                [titleBar setIsAbove:NO];
                [titleBar setButtonsAbove:NO];
                [titleBar drawTitleBarComponents];
                [frame setIsAbove:NO];
                frame = nil;
            }

            titleBar = nil;
        }

        tmp = nil;
    }

    windows = nil;
}

- (void) sendEvent:(const char *)anEvent toClient:(XCBWindow*)aWindow propagate:(BOOL)propagating
{
    xcb_send_event(connection, propagating, [aWindow window], XCB_EVENT_MASK_STRUCTURE_NOTIFY, anEvent);
}

//TODO: tenere traccia del tempo per ogni evento.

- (xcb_timestamp_t)currentTime
{
    return currentTime;
}

- (void)setCurrentTime:(xcb_timestamp_t)time
{
    currentTime = time;
}

- (BOOL) registerAsWindowManager:(BOOL)replace screenId:(uint32_t)screenId selectionWindow:(XCBWindow *)selectionWindow
{
    [selectionWindow onScreen];
    XCBScreen *screen = [selectionWindow screen];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];

    uint32_t values[1];
    values[0] = XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY;
    XCBWindow *rootWindow = [[XCBWindow alloc] initWithXCBWindow:[[screen rootWindow] window] andConnection:self];

    if (replace)
    {
        BOOL attributesChanged = [rootWindow changeAttributes:values withMask:XCB_CW_EVENT_MASK checked:YES];

        if (!attributesChanged)
        {
            NSLog(@"[WM] Can't register as WM (root SubstructureRedirect busy). Attempting replace via selection");

            NSString *atomName = [NSString stringWithFormat:@"WM_S%d", screenId];
            [[ewmhService atomService] cacheAtom:atomName];
            xcb_atom_t internedAtom = [[ewmhService atomService] atomFromCachedAtomsWithKey:atomName];
            XCBSelection *selector = [[XCBSelection alloc] initWithConnection:self andAtom:internedAtom];

            BOOL acquired = [selector aquireWithWindow:selectionWindow replace:YES];
            if (!acquired)
            {
                NSLog(@"[WM] Failed to acquire WM selection for replacement");
                rootWindow = nil;
                screen = nil;
                selector = nil;
                atomName = nil;
                ewmhService = nil;
                return NO;
            }

            attributesChanged = [rootWindow changeAttributes:values withMask:XCB_CW_EVENT_MASK checked:YES];

            if (!attributesChanged)
            {
                NSLog(@"[WM] Replacement attempt failed; still cannot set SubstructureRedirect");
                rootWindow = nil;
                screen = nil;
                selector = nil;
                atomName = nil;
                ewmhService = nil;
                return NO;
            }
        }

        NSLog(@"Subtructure redirect was set to the root window");

        rootWindow = nil;
        screen = nil;
        ewmhService = nil;
        return YES;
    }

    NSLog(@"Replacing window manager");

    NSString *atomName = [NSString stringWithFormat:@"WM_S%d", screenId];

    [[ewmhService atomService] cacheAtom:atomName];

    xcb_atom_t internedAtom = [[ewmhService atomService] atomFromCachedAtomsWithKey:atomName];

    XCBSelection *selector = [[XCBSelection alloc] initWithConnection:self andAtom:internedAtom];

    BOOL aquired = [selector aquireWithWindow:selectionWindow replace:YES];

    if (aquired)
    {
        BOOL attributesChanged = [rootWindow changeAttributes:values withMask:XCB_CW_EVENT_MASK checked:YES];

        if (!attributesChanged)
        {
            NSLog(@"Can't register as window manager.");

            rootWindow = nil;
            screen = nil;
            selector = nil;
            atomName = nil;
            ewmhService = nil;
            return NO;
        }
    }

    NSLog(@"Registered as window manager");

    screen = nil;
    rootWindow = nil;
    selector = nil;
    atomName = nil;
    ewmhService = nil;

    return YES;
}

- (XCBWindow *)rootWindowForScreenNumber:(int)number
{
    return [[screens objectAtIndex:number] rootWindow];
}

- (void)addDamagedRegion:(XCBRegion *)damagedRegion
{
    if (damagedRegions == nil)
        damagedRegions = [[XCBRegion alloc] initWithConnection:self rectagles:0 count:0];

    [damagedRegions unionWithRegion:damagedRegion destination:damagedRegions];
    [self setNeedFlush:YES];
}

- (xcb_window_t*)clientList
{
    return clientList;
}

- (void) grabServer
{
    xcb_grab_server(connection);
}

- (void) ungrabServer
{
    xcb_ungrab_server(connection);
}

- (void)dealloc
{
    [screens removeAllObjects];
    screens = nil;
    [windowsMap removeAllObjects];
    windowsMap = nil;
    displayName = nil;
    damagedRegions = nil;

    xcb_disconnect(connection);
    icccmService = nil;
}

- (void) handleCreateNotify: (xcb_create_notify_event_t*)anEvent
{
    NSLog(@"[%@] Create notify for window %u", NSStringFromClass([self class]), anEvent->window);

    // Create notify is sent when a window is created
    // We typically don't need to take action here as we handle windows on MapRequest
    // But we can track it for debugging purposes

    XCBWindow *parentWindow = [self windowForXCBId:anEvent->parent];
    if (parentWindow) {
        NSLog(@"New window %u created with parent %u", anEvent->window, anEvent->parent);
    }
}

- (void) handleKeyPress: (xcb_key_press_event_t*)anEvent
{
    // Handle keyboard input events
    // For now, we'll implement basic key handling for window manager shortcuts

    // Update current time for this event
    [self setCurrentTime:anEvent->time];

    // Get the focused window
    XCBWindow *focusedWindow = [self windowForXCBId:anEvent->event];

    // Log key press for debugging (can be removed later)
    NSLog(@"Key press: keycode %u, state %u, window %u", anEvent->detail, anEvent->state, anEvent->event);

    // Basic Alt+Tab window switching could be implemented here
    // For now, just forward the key event to the focused window
    if (focusedWindow) {
        // The key event is automatically delivered to the focused window by X11
        // Additional window manager key bindings can be implemented here
    }
}

- (void) handleKeyRelease: (xcb_key_release_event_t*)anEvent
{
    // Handle keyboard release events
    // Typically used to complete key combinations like Alt+Tab

    // Update current time for this event
    [self setCurrentTime:anEvent->time];

    // Log key release for debugging (can be removed later)
    NSLog(@"Key release: keycode %u, state %u, window %u", anEvent->detail, anEvent->state, anEvent->event);

    // End of key combination sequences can be handled here
    // For example, completing Alt+Tab window switching
}

- (void) handleCirculateRequest: (xcb_circulate_request_event_t*)anEvent
{
    // Handle window circulation requests (bring to front/send to back)
    NSLog(@"[%@] Circulate request for window %u, place: %s",
          NSStringFromClass([self class]),
          anEvent->window,
          anEvent->place == XCB_CIRCULATE_RAISE_LOWEST ? "raise" : "lower");

    XCBWindow *window = [self windowForXCBId:anEvent->window];
    if (!window) {
        NSLog(@"Window %u not found for circulate request", anEvent->window);
        return;
    }

    // Handle the circulation request
    if (anEvent->place == XCB_CIRCULATE_RAISE_LOWEST) {
        // Raise the lowest window to the top
        [window stackAbove];
        NSLog(@"Raised window %u to top", anEvent->window);
    } else if (anEvent->place == XCB_CIRCULATE_LOWER_HIGHEST) {
        // Lower the highest window to the bottom
        [window stackBelow];
        NSLog(@"Lowered window %u to bottom", anEvent->window);
    }

    // If this is a frame window, also handle its children
    if ([window isKindOfClass:[XCBFrame class]]) {
        XCBFrame *frame = (XCBFrame *)window;
        XCBTitleBar *titleBar = (XCBTitleBar *)[frame childWindowForKey:TitleBar];
        if (titleBar) {
            [titleBar setIsAbove:(anEvent->place == XCB_CIRCULATE_RAISE_LOWEST)];
            [titleBar drawTitleBarComponents];
        }
    }

    [self setNeedFlush:YES];
}

#pragma mark - Directional Maximize

- (void)ensureWorkareaCache:(XCBFrame*)frame {
    // Ensure workarea is cached if not already valid
    if (!self.workareaValid) {
        XCBScreen *screen = [frame screen];
        if (screen) {
            XCBWindow *rootWindow = [screen rootWindow];
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
            self.workareaValid = [ewmhService readWorkareaForRootWindow:rootWindow
                                                                      x:&_cachedWorkareaX
                                                                      y:&_cachedWorkareaY
                                                                  width:&_cachedWorkareaWidth
                                                                 height:&_cachedWorkareaHeight];
            if (!self.workareaValid) {
                // Fallback to screen dimensions
                _cachedWorkareaX = 0;
                _cachedWorkareaY = 0;
                _cachedWorkareaWidth = [screen width];
                _cachedWorkareaHeight = [screen height];
                self.workareaValid = YES;
            }
        }
    }
}

- (void)maximizeFrameVertically:(XCBFrame*)frame {
    [self ensureWorkareaCache:frame];

    // Keep current X and width, expand Y and height to workarea
    XCBRect current = [frame windowRect];

    // Save pre-maximize rect for restore
    [frame setOldRect:current];

    XCBRect target = XCBMakeRect(
        XCBMakePoint(current.position.x, _cachedWorkareaY),
        XCBMakeSize(current.size.width, _cachedWorkareaHeight));

    [frame programmaticResizeToRect:target];
    [frame setMaximizedVertically:YES];
    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];

    [self flush];
}

- (void)maximizeFrameHorizontally:(XCBFrame*)frame {
    [self ensureWorkareaCache:frame];

    // Keep current Y and height, expand X and width to workarea
    XCBRect current = [frame windowRect];

    // Save pre-maximize rect for restore
    [frame setOldRect:current];

    XCBRect target = XCBMakeRect(
        XCBMakePoint(_cachedWorkareaX, current.position.y),
        XCBMakeSize(_cachedWorkareaWidth, current.size.height));

    [frame programmaticResizeToRect:target];
    [frame setMaximizedHorizontally:YES];
    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];

    [self flush];
}

@end
