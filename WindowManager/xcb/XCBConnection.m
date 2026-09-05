//
//  XCBConnection.m
//  XCBKit
//
//  Created by alex on 27/04/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBConnection.h"
#import "EWMHService.h"
#import "XCBFrame.h"
#import "XCBSelection.h"
#import "XCBTitleBar.h"
#import "Transformers.h"
#import "ICCCMService.h"
#import "XCBRegion.h"
#import <xcb/xcb_aux.h>
#import <enums/EIcccm.h>
#import "TitleBarSettingsService.h"
#import "XCBTypes.h"
#import <GNUstepGUI/GSTheme.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphics.h>
#import <dirent.h>
#import <unistd.h>

#import <objc/message.h> // for dynamic messaging to compositor helper

@protocol URSCompositingManaging <NSObject>
+ (instancetype)sharedManager;
- (BOOL)compositingActive;
- (void)updateBypassCompositorForWindow:(xcb_window_t)windowId;
- (void)setCloseAnimating:(BOOL)closeAnimating forWindow:(xcb_window_t)windowId;
- (void)captureCloseSnapshotNowForWindow:(xcb_window_t)windowId;
- (void)animateWindowMinimize:(xcb_window_t)windowId
                                         fromRect:(XCBRect)startRect
                                             toRect:(XCBRect)endRect;
- (void)animateWindowMinimize:(xcb_window_t)windowId
                                         fromRect:(XCBRect)startRect
                                             toRect:(XCBRect)endRect
                                         completion:(void (^)(void))completion;
- (void)animateWindowRestore:(xcb_window_t)windowId
                                        fromRect:(XCBRect)startRect
                                            toRect:(XCBRect)endRect;
- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade;
- (void)animateWindowTransition:(xcb_window_t)windowId
                                                fromRect:(XCBRect)startRect
                                                    toRect:(XCBRect)endRect
                                                duration:(NSTimeInterval)duration
                                                        fade:(BOOL)fade
                                                 completion:(void (^)(void))completion;
- (void)animateWindowShrink:(xcb_window_t)windowId
                   fromRect:(XCBRect)startRect
                     toRect:(XCBRect)endRect
                   duration:(NSTimeInterval)duration;
- (void)animateWindowShrink:(xcb_window_t)windowId
                   fromRect:(XCBRect)startRect
                     toRect:(XCBRect)endRect
                   duration:(NSTimeInterval)duration
                 completion:(void (^)(void))completion;
+ (void)animateZoomRectsFromRect:(XCBRect)startRect
                          toRect:(XCBRect)endRect
                      connection:(XCBConnection *)connection
                          screen:(xcb_screen_t *)screen
                        duration:(NSTimeInterval)duration;
- (void)setSkipShadowForWindow:(xcb_window_t)windowId;
- (void)invalidateWindowPixmap:(xcb_window_t)windowId;
- (void)markStackingOrderDirty;
- (void)markStackingOrderDirtyForWindow:(xcb_window_t)windowId;
@end

// Find 32-bit ARGB visual for alpha transparency support
// Returns visual ID and fills in visualType if found
static xcb_visualid_t findARGBVisual(xcb_screen_t *screen, xcb_visualtype_t **outVisualType) {
    if (!screen) return 0;

    xcb_depth_iterator_t depth_iter = xcb_screen_allowed_depths_iterator(screen);

    for (; depth_iter.rem; xcb_depth_next(&depth_iter)) {
        if (depth_iter.data->depth != 32) continue;

        xcb_visualtype_iterator_t visual_iter = xcb_depth_visuals_iterator(depth_iter.data);

        for (; visual_iter.rem; xcb_visualtype_next(&visual_iter)) {
            xcb_visualtype_t *visual = visual_iter.data;

            // Look for TrueColor with 8-bit alpha channel
            if (visual->_class == XCB_VISUAL_CLASS_TRUE_COLOR) {
                if (outVisualType) *outVisualType = visual;
                return visual->visual_id;
            }
        }
    }

    return 0;
}

// Resolve a symlink to its actual path
static NSString *resolveSymlink(NSString *linkPath) {
    char buffer[PATH_MAX];
    ssize_t len = readlink([linkPath fileSystemRepresentation], buffer, sizeof(buffer) - 1);
    if (len != -1) {
        buffer[len] = '\0';
        return [NSString stringWithUTF8String:buffer];
    }
    return nil;
}

// Resolve an executable path to its canonical absolute path when possible.
static NSString *canonicalPathForExecutable(NSString *path)
{
    char resolved[PATH_MAX];

    if (!path) {
        return nil;
    }

    if (realpath([path fileSystemRepresentation], resolved) != NULL) {
        return [NSString stringWithUTF8String:resolved];
    }

    return path;
}

// Kill any other instances of this application after we've registered as WM
static void killOtherInstances(void) {
    NSString *currentPath = [[NSBundle mainBundle] executablePath];
    if (!currentPath) {
        return;
    }

    pid_t currentPID = getpid();
    NSString *currentRealPath = canonicalPathForExecutable(currentPath);

    DIR *procDir = opendir("/proc");
    if (!procDir) {
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(procDir)) != NULL) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') {
            continue;
        }

        pid_t otherPID = (pid_t)strtol(entry->d_name, NULL, 10);
        if (otherPID <= 0 || otherPID == currentPID) {
            continue;
        }

        NSString *exePath = [NSString stringWithFormat:@"/proc/%d/exe", otherPID];
        NSString *linkedPath = resolveSymlink(exePath);

        if (!linkedPath) {
            exePath = [NSString stringWithFormat:@"/proc/%d/file", otherPID];
            linkedPath = resolveSymlink(exePath);
        }

        if (!linkedPath) {
            continue;
        }

        NSString *otherRealPath = canonicalPathForExecutable(linkedPath);

        if ([otherRealPath isEqualToString:currentRealPath]) {
            NSLog(@"[WindowManager] Killing stale instance with PID %d", otherPID);
            kill(otherPID, SIGTERM);
            usleep(100000);

            BOOL stillAlive = (kill(otherPID, 0) == 0);
            int waitedMs = 100;
            while (stillAlive && waitedMs < 2000) {
                usleep(100000);
                waitedMs += 100;
                stillAlive = (kill(otherPID, 0) == 0);
            }

            if (stillAlive) {
                NSLog(@"[WindowManager] Force killing stale instance with PID %d", otherPID);
                kill(otherPID, SIGKILL);
            }
        }
    }

    closedir(procDir);
}

@interface XCBConnection ()
{
    // Last titlebar ButtonPress, for double-click (WindowShade toggle) detection.
    xcb_timestamp_t _lastTitlebarClickTime;
    xcb_window_t _lastTitlebarClickWindow;
}
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
        //NSLog(@"[XCBConnection] Connecting to the default display in env DISPLAY");
    } else
    {
        //NSLog(@"XCBConnection: Creating connection with display: %@", aDisplay);
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

//    int fd = xcb_get_file_descriptor(connection);
//
//    NSLog(@"XCBConnection: Connection: %d", fd);

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
            //NSLog(@"[XCBConnection]: Creating shared connection as window manager...");
            sharedInstance = [[self alloc] initAsWindowManager:asWindowManager];
        }
        else
        {
            //NSLog(@"[XCBConnection]: Creating shared connection...");
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

    NSNumber *key = [[NSNumber alloc] initWithInt:win];
    XCBWindow *window = [windowsMap objectForKey:key];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];

    if (window != nil)
    {
        // Window already registered - skip duplicate registration
        window = nil;
        key = nil;
        ewmhService = nil;
        return;
    }
    
    if ([aWindow isKindOfClass:[XCBFrame class]] ||
        [aWindow isKindOfClass:[XCBTitleBar class]] ||
        [aWindow isCloseButton] || [aWindow isMaximizeButton] || [aWindow isMinimizeButton])
    {
        win = 0;
    }

    BOOL isRootWindow = NO;
    for (XCBScreen *screen in screens)
    {
        XCBWindow *screenRootWindow = [screen rootWindow];
        if (screenRootWindow && [screenRootWindow window] == win)
        {
            isRootWindow = YES;
            break;
        }
    }

    if (win != 0)
    {
        //NSLog(@"[XCBConnection] Adding the window %u in the windowsMap", win);
        clientList[clientListIndex++] = win;
        
        if (!isRootWindow)
        {
            // Initialize standard EWMH atoms for client windows
            [ewmhService initializeClientWindowAtomsForWindow:aWindow];
        }
    }

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
    //if (win != 0)
    //    NSLog(@"[XCBConnection] Removing the window %u from the windowsMap", win);
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

- (void)restackDockWindowsAbove
{
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    NSString *dockType = [ewmhService EWMHWMWindowTypeDock];

    // PID of the currently focused application.  Auxiliary and transient
    // windows (dialogs, tooltips, notifications, menus) must stay above their
    // OWN application's windows, but must never be raised above a window of a
    // different application that the user just focused.  Without this guard a
    // leftover tooltip/notification/dialog from an unfocused app would pop on
    // top of the active window for no apparent reason whenever any window is
    // raised.
    uint32_t fpid = 0;
    {
        xcb_get_input_focus_cookie_t focC = xcb_get_input_focus(connection);
        xcb_get_input_focus_reply_t *focR = xcb_get_input_focus_reply(connection, focC, NULL);
        if (focR) {
            XCBWindow *fw = [self windowForXCBId:focR->focus];
            free(focR);
            if (fw) fpid = [fw pid];
        }
    }

    // Notify the compositor per restacked window: a raise only changes
    // pixels inside the raised window's extents, so the compositor can
    // repair just those instead of repainting the whole screen.
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    id<URSCompositingManaging> compositor = nil;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)])
    {
        compositor = [compositorClass performSelector:@selector(sharedManager)];
    }

    for (XCBWindow *aWindow in [windowsMap allValues])
    {
        if ([[aWindow windowType] isEqualToString:dockType])
        {
            [aWindow stackAbove];
            if (compositor && [compositor respondsToSelector:@selector(markStackingOrderDirtyForWindow:)])
            {
                [compositor markStackingOrderDirtyForWindow:[aWindow window]];
            }
        }
    }

    // Menu-type windows must remain above the dock so that context menus,
    // popup menus, and dropdown menus are always fully visible.
    // Stack them above the dock after the dock has been raised.
    {
        NSString *menuType = [ewmhService EWMHWMWindowTypeMenu];
        NSString *popupMenuType = [ewmhService EWMHWMWindowTypePopupMenu];
        NSString *dropdownMenuType = [ewmhService EWMHWMWindowTypeDropdownMenu];

        for (XCBWindow *aWindow in [windowsMap allValues])
        {
            NSString *wtype = [aWindow windowType];
            if ([wtype isEqualToString:menuType] ||
                [wtype isEqualToString:popupMenuType] ||
                [wtype isEqualToString:dropdownMenuType])
            {
                [aWindow stackAbove];
                if (compositor && [compositor respondsToSelector:@selector(markStackingOrderDirtyForWindow:)])
                {
                    [compositor markStackingOrderDirtyForWindow:[aWindow window]];
                }
            }
        }
    }

    // Fullscreen windows must stay above docks/panels even after restack.
    for (XCBWindow *aWindow in [windowsMap allValues])
    {
        if ([aWindow fullScreen] && [[aWindow parentWindow] isKindOfClass:[XCBFrame class]])
        {
            XCBFrame *fsFrame = (XCBFrame *)[aWindow parentWindow];
            [fsFrame stackAbove];
            if (compositor && [compositor respondsToSelector:@selector(markStackingOrderDirtyForWindow:)])
            {
                [compositor markStackingOrderDirtyForWindow:[fsFrame window]];
            }
        }
    }

    // All undecorated (auxiliary) windows of the focused application must
    // stay above their parent after any restack operation.  Broad check:
    // any window with the same PID that is not itself an XCBFrame.
    if (fpid > 0) {
        for (XCBWindow *aWindow in [windowsMap allValues]) {
            if ([aWindow pid] != fpid) continue;
            if ([aWindow isKindOfClass:[XCBFrame class]]) continue;
            if (![aWindow decorated]) {
                [aWindow stackAbove];
                if (compositor && [compositor respondsToSelector:@selector(markStackingOrderDirtyForWindow:)])
                {
                    [compositor markStackingOrderDirtyForWindow:[aWindow window]];
                }
            }
        }
    }

    // Transient popup windows (dialog, tooltip, notification, utility, splash)
    // must stay above the dock so they are always visible.  Only transients of
    // the focused application are raised; transients belonging to other apps
    // must not cover the window the user is working with.
    {
        NSSet<NSString *> *transientTypes = [NSSet setWithObjects:
            [ewmhService EWMHWMWindowTypeDialog],
            [ewmhService EWMHWMWindowTypeTooltip],
            [ewmhService EWMHWMWindowTypeNotification],
            [ewmhService EWMHWMWindowTypeUtility],
            [ewmhService EWMHWMWindowTypeSplash],
            nil];
        [self flush];
        for (XCBWindow *aWindow in [windowsMap allValues]) {
            if (![transientTypes containsObject:[aWindow windowType]]) continue;
            if (fpid == 0 || [aWindow pid] != fpid) continue;
            // Decorated transients already live inside a managed frame; there
            // is nothing to raise at the root level.
            if ([aWindow parentWindow] &&
                [[aWindow parentWindow] isKindOfClass:[XCBFrame class]]) continue;
            [aWindow stackAbove];
            if (compositor && [compositor respondsToSelector:@selector(markStackingOrderDirtyForWindow:)])
            {
                [compositor markStackingOrderDirtyForWindow:[aWindow window]];
            }
        }
        [self flush];
    }

    ewmhService = nil;
}

// Called from the compositor damage path.  A dedicated Damage object is
// created on each managed client window (see URSCompositingManager
// -addWindow:), so a DamageNotify whose drawable IS that client window is an
// unambiguous, reliable signal that the application redrew its content.  The
// X server only emits damage when the client actually draws, so no pixel
// comparison is needed - the old snapshot-diff heuristic was fragile and
// missed redraws (e.g. Terminal.app output).
//
// This fires regardless of visibility: while WindowShaded the client window is
// deliberately left mapped and untouched, so it keeps drawing and its Damage
// object keeps reporting - the frame's own (clipped) Damage would be silent,
// which is exactly why the client-level object is what makes shaded-activity
// detection work.
- (void)noteClientContentDamage:(xcb_window_t)windowId
                           area:(xcb_rectangle_t)area
{
    // Resolve the owning managed frame by walking the tracked window
    // hierarchy (cheap, in-process - no X round-trips).  The drawable is
    // either the frame itself or, for the client-level Damage object, the
    // client child.
    XCBWindow *cur = [self windowForXCBId:windowId];
    XCBFrame *frame = nil;
    for (int i = 0; i < 16 && cur; i++) {
        if ([cur isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame *)cur;
            break;
        }
        cur = [cur parentWindow];
    }
    if (!frame)
        return;

    // Only the client window's own drawable counts as content activity.
    // Titlebar/chrome redraws arrive on their own windows and are ignored.
    XCBWindow *client = [frame childWindowForKey:ClientWindow];
    if (!client || [client window] != windowId)
        return;

    [frame noteContentChanged];
}


// X window id of the LOWEST root-level child that belongs to another
// managed, decorated, ordinary window (frame).  Desktops, docks, menus and
// fullscreen frames never count as peers: removing keep-above must place a
// window among its normal siblings, not below (or above) special layers.
- (xcb_window_t)lowestManagedNormalFrameIdExcluding:(xcb_window_t)excludeWin
{
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    NSString *dockType = [ewmhService EWMHWMWindowTypeDock];
    NSString *desktopType = [ewmhService EWMHWMWindowTypeDesktop];
    NSString *menuType = [ewmhService EWMHWMWindowTypeMenu];
    NSString *popupMenuType = [ewmhService EWMHWMWindowTypePopupMenu];
    NSString *dropdownMenuType = [ewmhService EWMHWMWindowTypeDropdownMenu];

    xcb_window_t rootWin = [[[[self screens] firstObject] rootWindow] window];
    xcb_query_tree_cookie_t treeCookie = xcb_query_tree(connection, rootWin);
    xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(connection, treeCookie, NULL);
    xcb_window_t peer = 0;

    if (treeReply)
    {
        int n = xcb_query_tree_children_length(treeReply);
        xcb_window_t *kids = xcb_query_tree_children(treeReply);

        // Children are listed bottom-most first, so scan from the start.
        for (int i = 0; i < n && peer == 0; i++)
        {
            if (kids[i] == excludeWin)
                continue;

            XCBWindow *managed = [self windowForXCBId:kids[i]];
            if (![managed isKindOfClass:[XCBFrame class]])
                continue;

            XCBWindow *client = [(XCBFrame *)managed childWindowForKey:ClientWindow];
            if (!client)
                continue;

            // Fullscreen frames live above the dock layer, not in the
            // normal sibling order.
            if ([client fullScreen])
                continue;

            NSString *type = [client windowType];
            if ([type isEqualToString:dockType] ||
                [type isEqualToString:desktopType] ||
                [type isEqualToString:menuType] ||
                [type isEqualToString:popupMenuType] ||
                [type isEqualToString:dropdownMenuType])
                continue;

            peer = kids[i];
        }
        free(treeReply);
    }

    ewmhService = nil;
    return peer;
}

// Place aWindow directly beneath the LOWEST other managed normal frame,
// i.e. beneath ALL of them, so a removed keep-above (_NET_WM_STATE_ABOVE)
// or keep-below state returns the window to ordinary stacking instead of
// leaving it stuck above (or at the very bottom of) its peers.
- (void)lowerNormalWindowBeneathAllPeers:(XCBWindow *)aWindow
{
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    BOOL isDesktop = [aWindow windowType] &&
        [[aWindow windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]];
    ewmhService = nil;

    if (!aWindow || isDesktop)
        return;

    uint32_t selfWin = [aWindow window];
    xcb_window_t peer = [self lowestManagedNormalFrameIdExcluding:selfWin];

    if (peer != 0)
    {
        uint32_t values[2] = { peer, XCB_STACK_MODE_BELOW };
        xcb_configure_window(connection,
                             selfWin,
                             XCB_CONFIG_WINDOW_SIBLING | XCB_CONFIG_WINDOW_STACK_MODE,
                             values);
        [self flush];
    }

    [self restackDockWindowsAbove];
}

// Place aWindow directly above the lowest desktop window.  Used when
// _NET_WM_STATE_BELOW is added: "below" must not push a window underneath
// the desktop layer, where it would be invisible.
//
// The desktop surface cannot be looked up through windowsMap: Workspace's
// desktop window is kept UNMANAGED (a plain root child), so its type must
// be read straight off the tree.
- (void)lowerNormalWindowAboveDesktop:(XCBWindow *)aWindow
{
    if (!aWindow)
        return;

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:self];
    xcb_atom_t desktopTypeAtom = [atomService atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDesktop]];
    xcb_atom_t typePropertyAtom = [atomService atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowType]];
    ewmhService = nil;
    atomService = nil;

    xcb_window_t rootWin = [[[[self screens] firstObject] rootWindow] window];
    xcb_query_tree_cookie_t treeCookie = xcb_query_tree(connection, rootWin);
    xcb_query_tree_reply_t *treeReply = xcb_query_tree_reply(connection, treeCookie, NULL);

    if (treeReply)
    {
        int n = xcb_query_tree_children_length(treeReply);
        xcb_window_t *kids = xcb_query_tree_children(treeReply);
        xcb_window_t desktopWin = 0;

        // Bottom-most root child carrying _NET_WM_WINDOW_TYPE_DESKTOP,
        // managed or not.
        for (int i = 0; i < n && desktopWin == 0; i++)
        {
            xcb_get_property_cookie_t pc = xcb_get_property(connection,
                                                            0,
                                                            kids[i],
                                                            typePropertyAtom,
                                                            XCB_ATOM_ATOM,
                                                            0,
                                                            32);
            xcb_get_property_reply_t *pr = xcb_get_property_reply(connection, pc, NULL);
            if (pr && xcb_get_property_value_length(pr) > 0
                && ((xcb_atom_t *)xcb_get_property_value(pr))[0] == desktopTypeAtom)
                desktopWin = kids[i];
            free(pr);
        }
        free(treeReply);

        if (desktopWin != 0 && desktopWin != [aWindow window])
        {
            uint32_t values[2] = { desktopWin, XCB_STACK_MODE_ABOVE };
            xcb_configure_window(connection,
                                 [aWindow window],
                                 XCB_CONFIG_WINDOW_SIBLING | XCB_CONFIG_WINDOW_STACK_MODE,
                                 values);
            [self flush];
        }
    }

    [self restackDockWindowsAbove];
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

        //NSLog(@"[XCBConnection] Screen with root window: %d;\n\
//			  With width in pixels: %d;\n\
//			  With height in pixels: %d\n",
//              scr->root,
//              scr->width_in_pixels,
//              scr->height_in_pixels);

        [self registerWindow:rootWindow];

        [rootWindow setScreen:screen];
        [rootWindow initCursor];
        [rootWindow showLeftPointerCursor];
        [[rootWindow cursor] destroyCursor];

        xcb_screen_next(&iterator);
        rootWindow = nil;
        screen = nil;

    }

    //NSLog(@"Number of screens: %lu", (unsigned long) [screens count]);
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
    //NSLog(@"[%@] The window %u is mapped!", NSStringFromClass([self class]), [window window]);
    [window setIsMapped:YES];

    window = nil;
}

/* Find the first free cascade position by scanning existing managed windows.
 * Classic HIG: start at workarea origin + (22, 48), step 24px diagonally.
 * Returns the first position that doesn't overlap any existing managed
 * non-dialog/non-desktop frame. */
- (XCBPoint)nextCascadePositionForSize:(XCBSize)size
                             screenX:(int32_t)scrX
                             screenY:(int32_t)scrY
                        screenWidth:(uint32_t)scrW
                       screenHeight:(uint32_t)scrH
{
    const int step = 22;
    /* 22 = Eau theme menuBarHeight (Eau+Menu.m:33), 12 = padding.
       Must match at runtime; Menu.app may not be launched yet. */
    const int menuBarHeight = 22;
    const int padY = menuBarHeight + 12;
    const int padX = 12;
    EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:self];
    NSString *dialogType = [ewmh EWMHWMWindowTypeDialog];
    NSString *desktopType = [ewmh EWMHWMWindowTypeDesktop];
    NSString *dockType = [ewmh EWMHWMWindowTypeDock];

    /* Count managed non-special decorated windows to determine cascade offset. */
    NSUInteger count = 0;
    for (XCBWindow *w in [windowsMap allValues])
    {
        if (![w isKindOfClass:[XCBFrame class]])
            continue;

        XCBFrame *frame = (XCBFrame *)w;
        XCBWindow *client = [frame childWindowForKey:ClientWindow];
        if (client == nil || ![client decorated])
            continue;

        NSString *wType = [client windowType];
        if (wType != nil)
        {
            if ([wType isEqualToString:dialogType] ||
                [wType isEqualToString:desktopType] ||
                [wType isEqualToString:dockType])
                continue;
        }

        count++;
    }

    /* Classic HIG: step diagonally by count, wrapping when past screen.
       No overlap avoidance - windows overlap but title bars stay visible. */
    int16_t x = scrX + padX + (int)(count % 20) * step;
    int16_t y = scrY + padY + (int)(count % 20) * step;

    /* Wrap within raw screen bounds. */
    if (x + (int32_t)size.width > scrX + (int32_t)scrW)
        x = scrX + padX;
    if (y + (int32_t)size.height > scrY + (int32_t)scrH)
        y = scrY + padY;

    return XCBMakePoint(x, y);
}

- (void)handleUnMapNotify:(xcb_unmap_notify_event_t *)anEvent
{
    // If we were dragging when this window unmapped, cancel the drag.
    // A missed button release (e.g., window unmapped during drag) leaves dragState stuck.
    if (dragState) {
        //NSLog(@"DRAG SAFETY: Window %u unmapped while dragState=YES — clearing drag state", anEvent->window);
        dragState = NO;
        resizeState = NO;
        xcb_ungrab_pointer(connection, XCB_CURRENT_TIME);
        [self flush];
    }

    XCBWindow *window = [self windowForXCBId:anEvent->window];

    // Absorb synthetic UnmapNotify events generated when the WM reparents an already-mapped
    // client into its decoration frame.  The X server issues one from root's SubstructureNotify
    // and one from the client's own StructureNotify (selected via CLIENT_SELECT_INPUT_EVENT_MASK).
    // Consuming them here prevents the frame-destruction path from running on these stale events.
    if (window.ignoreUnmapCount > 0) {
        window.ignoreUnmapCount--;
        //NSLog(@"[handleUnMapNotify] Absorbed synthetic unmap for window %u (remaining=%d)",
        //      anEvent->window, window.ignoreUnmapCount);
        return;
    }

    [window setIsMapped:NO];
    //NSLog(@"[%@] The window %u is unmapped!", NSStringFromClass([self class]), [window window]);

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
            //NSLog(@"[%u] Cleared _NET_ACTIVE_WINDOW", [window window]);
        }
        free(reply);
    }

    /* Close animation, unmap-driven: the Workspace close message (received
     * before the app's orderOut) only PREPARES the animation - it captures a
     * snapshot of the still-mapped window and stores the target rect.  The
     * app's UnmapNotify IS the close event; it triggers the shrink/fade, like
     * KDE fading every window on unmap.  Only windows carrying the close
     * atom get the animation; everything else tears down immediately.
     *
     * Note: the frame itself is never unmapped by the app - only the client
     * child is - so the frame stays viewable and in the paint list on its own;
     * the compositor's closeAnimating keeps its picture alive. */
    if (frameWindow && [frameWindow isKindOfClass:[XCBFrame class]])
    {
        XCBFrame *closeFrame = (XCBFrame *)frameWindow;
        if (closeFrame.closeAnimating)
        {
            frameWindow = nil;
            scr = nil;
            ewmhService = nil;
            rootWindow = nil;
            return;
        }
        if (closeFrame.closeAnimationPrepared)
        {
            /* This UnmapNotify is the close event: start the shrink/fade now
             * and defer the teardown until it completes. */
            [self startCloseAnimationForFrame:closeFrame];
            frameWindow = nil;
            scr = nil;
            ewmhService = nil;
            rootWindow = nil;
            return;
        }
    }

    if (frameWindow &&
        ![frameWindow isMinimized] &&
        [frameWindow window] != [[scr rootWindow] window])
    {
        // Damage the window and its decoration frame together so the client
        // content, titlebar, and any remaining shadow are repainted atomically.
        XCBRect frameRect = [frameWindow windowRect];
        XCBRect clientRect = [window windowRect];

        int16_t left = (frameRect.position.x < clientRect.position.x) ? frameRect.position.x : clientRect.position.x;
        int16_t top = (frameRect.position.y < clientRect.position.y) ? frameRect.position.y : clientRect.position.y;
        int16_t right = (frameRect.position.x + frameRect.size.width > clientRect.position.x + clientRect.size.width)
                           ? frameRect.position.x + frameRect.size.width
                           : clientRect.position.x + clientRect.size.width;
        int16_t bottom = (frameRect.position.y + frameRect.size.height > clientRect.position.y + clientRect.size.height)
                            ? frameRect.position.y + frameRect.size.height
                            : clientRect.position.y + clientRect.size.height;

        const int16_t padding = 10;
        left -= padding;
        top -= padding;
        right += padding;
        bottom += padding;

        xcb_rectangle_t frameDamage = { left, top, (uint16_t)(right - left), (uint16_t)(bottom - top) };
        XCBRegion *damageRegion = [[XCBRegion alloc] initWithConnection:self
                                                               rectagles:&frameDamage
                                                                   count:1];
        [self addDamagedRegion:damageRegion];
        damageRegion = nil;

        //NSLog(@"Destroying window %u", [frameWindow window]);

        // Reparent using root-relative coordinates. windowRect is frame-relative
        // for decorated clients and causes visible position drift if used directly.
        xcb_translate_coordinates_reply_t *translated =
            xcb_translate_coordinates_reply(connection,
                                           xcb_translate_coordinates(connection,
                                                                     [window window],
                                                                     [rootWindow window],
                                                                     0,
                                                                     0),
                                           NULL);

        XCBPoint reparentPos = XCBMakePoint(0, 0);
        if (translated) {
            reparentPos = XCBMakePoint(translated->dst_x, translated->dst_y);
            free(translated);
        } else {
            XCBRect frameRect = [frameWindow windowRect];
            XCBRect clientRect = [window windowRect];
            reparentPos = XCBMakePoint(frameRect.position.x + clientRect.position.x,
                                       frameRect.position.y + clientRect.position.y);
        }

        [self reparentWindow:window toWindow:[[window queryTree] rootWindow] position:reparentPos];
        [window setDecorated:NO];
        [self unregisterWindow:frameWindow];
        XCBTitleBar *titleBar = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
        if (titleBar != nil) {
            [self unregisterWindow:titleBar];
        }
        [[frameWindow getChildren] removeAllObjects];
        [frameWindow destroy];
        [self unregisterWindow:window];
    }

    window = nil;
    frameWindow = nil;
    scr = nil;
    ewmhService = nil;
    rootWindow = nil;
}

// Fade in and grow slightly for a window that was just mapped.
// Desktop windows and windows adopted at startup are skipped.
// If the client carries a _WINDOW_BIRTH_ANIMATION property (set by the
// Workspace app) when it is mapped, animate from that source rect
// instead of the default 90% grow, and honour its animation type
// (type 1 = NoAnimation).  The property is present only when a folder was
// opened; a re-mapped window without a fresh property (e.g. unminimized)
// must not use it.
- (void)animateMappedWindow:(xcb_window_t)frameId
                   clientId:(xcb_window_t)clientId
                 windowRect:(XCBRect)windowRect
                  newWindow:(BOOL)newWindow
{
    if (self.adoptingExistingWindows)
    {
        return;
    }

    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    if (!compositorClass || ![compositorClass respondsToSelector:@selector(sharedManager)])
    {
        return;
    }
    id<URSCompositingManaging> compositor = [compositorClass performSelector:@selector(sharedManager)];
    if (!compositor || ![compositor compositingActive])
    {
        return;
    }

    // Desktop windows must not animate; they always sit at the bottom.
    XCBWindow *frame = [self windowForXCBId:frameId];
    if (frame && [frame isKindOfClass:[XCBFrame class]])
    {
        XCBWindow *client = [(XCBFrame *)frame childWindowForKey:ClientWindow];
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
        if (client && [[client windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]])
        {
            return;
        }
    }

    // Read _WINDOW_BIRTH_ANIMATION (source rect + animation type) from the
    // client window, if present.  Layout: 9 x int32 = src(x,y,w,h), dst(x,y,w,h),
    // animationType.  animationType == 1 means "NoAnimation" (suppress).
    // Read the birth rect whenever a fresh _WINDOW_BIRTH_ANIMATION property is present.
    // Workspace sets it only on a real folder open (never on unminimize), so
    // gating on newWindow would make the birth animation fire only once per
    // window: a reopened folder reuses the same X window id, and the re-map
    // (newWindow:NO) would skip the freshly-set property.  The property is
    // deleted below, so a plain re-map such as unminimize (no fresh property)
    // still gets its own separate restore animation, not a birth.
    XCBRect startRect = XCBInvalidRect;
    NSTimeInterval duration = 0.22;
    BOOL suppressAnimation = NO;
    BOOL foundBirthAtom = NO;

    if (clientId != XCB_NONE)
    {
        XCBAtomService *atomSvc = [XCBAtomService sharedInstanceWithConnection:self];
        xcb_atom_t birthAtom = [atomSvc cacheAtom: @"_WINDOW_BIRTH_ANIMATION"];
        if (birthAtom != XCB_NONE)
        {
            xcb_get_property_cookie_t cookie = xcb_get_property([self connection], 0, clientId,
                                                                  birthAtom, XCB_ATOM_CARDINAL, 0,
                                                                  WINDOW_BIRTH_NUM_INTS);
            xcb_generic_error_t *birthError = NULL;
            xcb_get_property_reply_t *reply = xcb_get_property_reply([self connection], cookie, &birthError);
            if (birthError) { free(birthError); reply = NULL; }

            if (reply)
            {
                int len = xcb_get_property_value_length(reply);
                if (len == WINDOW_BIRTH_BYTE_LEN)
                {
                    foundBirthAtom = YES;
                    int32_t *data = (int32_t *)xcb_get_property_value(reply);
                    int32_t animType = data[WINDOW_BIRTH_IDX_ANIM_TYPE];

                    if (animType == 1)
                    {
                        suppressAnimation = YES;
                    }
                    else
                    {
                        startRect.position.x = data[WINDOW_BIRTH_IDX_SRC_X];
                        startRect.position.y = data[WINDOW_BIRTH_IDX_SRC_Y];
                        startRect.size.width = data[WINDOW_BIRTH_IDX_SRC_W];
                        startRect.size.height = data[WINDOW_BIRTH_IDX_SRC_H];
                        // Expanding from a source rect is a more deliberate
                        // effect than the default 90% grow.
                        duration = 0.2;
                    }
                }
                // Delete the property so it doesn't persist past birth.
                xcb_delete_property([self connection], clientId, birthAtom);
                free(reply);
            }
        }
    }

    if (suppressAnimation)
    {
        return;
    }

    // Workspace is the producer of the birth-atom protocol.  Every Workspace
    // window that is mapped should carry a _WINDOW_BIRTH_ANIMATION property
    // describing where it should grow from.  If a Workspace window is missing
    // it, the producer side is broken (e.g. the atom was only written for
    // icon-driven folder opens, or not written at all on non-Linux builds) -
    // warn so it can be fixed.
    if (!foundBirthAtom)
    {
        XCBWindow *frame = [self windowForXCBId:frameId];
        XCBWindow *client = nil;
        if (frame && [frame isKindOfClass:[XCBFrame class]]) {
            client = [(XCBFrame *)frame childWindowForKey:ClientWindow];
        }
        if (client && [[client windowClass] count] >= 2)
        {
            NSString *cls = [[client windowClass] objectAtIndex:0];
            if ([cls isEqualToString:@"Workspace"])
            {
                NSLog(@"WARNING: Workspace window 0x%x (\"%@\") mapped without "
                      @"_WINDOW_BIRTH_ANIMATION atom - birth animation "
                      @"source rect missing",
                      clientId,
                      [[client windowClass] objectAtIndex:1]);
            }
        }
    }

    // If no valid birth source rect, grow from 90% of the final size,
    // anchored at the same center, while fading in from transparent.
    if (!FnCheckXCBRectIsValid(startRect) ||
        startRect.size.width <= 0 || startRect.size.height <= 0)
    {
        double w = fmax(1.0, (double)windowRect.size.width);
        double h = fmax(1.0, (double)windowRect.size.height);
        double cx = windowRect.position.x + w * 0.5;
        double cy = windowRect.position.y + h * 0.5;
        double startW = w * 0.9;
        double startH = h * 0.9;
        startRect = XCBMakeRect(
            XCBMakePoint((int16_t)(cx - startW * 0.5),
                         (int16_t)(cy - startH * 0.5)),
            XCBMakeSize((uint16_t)startW, (uint16_t)startH));
        duration = 0.11;
    }


    [compositor animateWindowTransition:frameId
                               fromRect:startRect
                                 toRect:windowRect
                               duration:duration
                                   fade:YES];
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

    //NSLog(@"[%@] Map request for window %u", NSStringFromClass([self class]), anEvent->window);

    /** if already managed map it **/

    if (window != nil)
    {
        //NSLog(@"Window %u already managed by the window manager.", [window window]);
        isManaged = YES;

        // Check if this window has a frame parent (meaning it was decorated)
        if ([[window parentWindow] isKindOfClass:[XCBFrame class]])
        {
            XCBFrame *frame = (XCBFrame *)[window parentWindow];
            XCBTitleBar *titleBar = (XCBTitleBar *)[frame childWindowForKey:TitleBar];

            //NSLog(@"[MapRequest] Window has frame parent %u", [frame window]);

            // If the frame is minimized, this is a restoration request
            if ([frame isMinimized] || [window isMinimized])
            {
                //NSLog(@"[MapRequest] Restoring minimized window from GNUstep");

                // Check if this window belongs to a group (has a leader)
                XCBWindow *leader = [window leaderWindow];

                if (leader && [leader window] != XCB_NONE)
                {
                    //NSLog(@"[MapRequest] Window %u has leader %u, restoring all grouped windows",
                    //      [window window], [leader window]);

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
                        //NSLog(@"[MapRequest] Restoring grouped window %u", [groupedWindow window]);

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
                            [self restackDockWindowsAbove];
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
                    //NSLog(@"[MapRequest] No window group, restoring single window");

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
                    [self restackDockWindowsAbove];

                    if (titleBar)
                    {
                        [titleBar setIsAbove:YES];
                        [titleBar drawTitleBarComponents];
                        [self drawAllTitleBarsExcept:titleBar];
                    }

                    [window focus];
                }

                //NSLog(@"[MapRequest] Restoration complete");
            }
            else
            {
                // Normal map for non-minimized window
                
                // Map the window
                [self mapWindow:frame];

                if (titleBar)
                {
                    [self mapWindow:titleBar];
                }

                [self mapWindow:window];

                // Fade in + grow slightly whenever a window is (re)shown.
                // This is a re-map (e.g. unminimize/unmaximize), so no birth rect.
                [self animateMappedWindow:[frame window]
                                 clientId:[window window]
                               windowRect:[frame windowRect]
                                newWindow:NO];
            }
        }
        else
        {
            //NSLog(@"[MapRequest] Window has no frame parent, mapping directly");
            // No frame, reposition unless the application set the window's
            // screen coordinates itself (WM_NORMAL_HINTS USPosition /
            // PPosition) — those are mapped directly at the requested
            // location.
            XCBRect winRect = [window windowRect];
            uint16_t reqW = winRect.size.width;
            uint16_t reqH = winRect.size.height;

            XCBScreen *screenObj = nil;
            xcb_screen_t *screen = NULL;
            if ([[self screens] count] > 0) {
                screenObj = [[self screens] objectAtIndex:0];
                screen = [screenObj screen];
            }

            if (screen) {
                int16_t screenHeight = [screenObj height];
                int16_t screenWidth = [screenObj width];
                BOOL isFullWidth = (reqW >= screenWidth);

                BOOL appPositioned = [icccmService windowSpecifiesPosition:window];
                if (appPositioned) {
                    /* A requested position that hugs the screen's bottom-left
                       corner (its bottom-left corner at (0,0) in the app's
                       bottom-left-origin coordinate system) is what apps pass
                       when they have no real position — cascade instead,
                       unless the window spans the full width or height. */
                    BOOL fullSpan = (reqW >= (uint16_t)screenWidth) ||
                                    (reqH >= (uint16_t)screenHeight);
                    if (winRect.position.x <= 0 &&
                        ((int32_t)winRect.position.y + (int32_t)winRect.size.height) >= screenHeight &&
                        !fullSpan) {
                        appPositioned = NO;
                    }
                }

                if (!appPositioned && !isFullWidth) {
                    BOOL isDialog = NO;
                    if ([window windowType] != nil && ewmhService != nil) {
                        isDialog = [[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDialog]];
                    }

                    int16_t xPos, yPos;
                    if (isDialog) {
                        xPos = (screenWidth - reqW) / 2;
                        yPos = (screenHeight - reqH) * 0.381966;
                    } else {
                        XCBSize winSize = {reqW, reqH};
                        XCBPoint pos = [self nextCascadePositionForSize:winSize
                                                              screenX:0
                                                              screenY:0
                                                         screenWidth:screenWidth
                                                        screenHeight:screenHeight];
                        xPos = pos.x;
                        yPos = pos.y;
                    }
                    XCBRect newRect = winRect;
                    newRect.position.x = xPos;
                    newRect.position.y = yPos;
                    [window setWindowRect:newRect];
                }
            }

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
        //NSLog(@"Window with id %u already decorated", [window window]);

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
        [window checkNetWMAllowedActions];


        //NSLog(@"Window Type %@ and window: %u", [ewmhService EWMHWMWindowType], [window window]);
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
            //NSLog(@"Name: %@", name);

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDock]])
            {
                //NSLog(@"Dock window %u to be registered", [window window]);
                
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
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                // Only skip drop shadow for the Dock panel (identified by _NET_WM_NAME "Dock"),
                // not all DOCK-type windows (some may be opaque panels that need shadows)
                {
                    xcb_atom_t utf8Atom = [atomService atomFromCachedAtomsWithKey:[ewmhService UTF8_STRING]];
                    void *nameReply = [ewmhService getProperty:[ewmhService EWMHWMName]
                                                  propertyType:utf8Atom
                                                     forWindow:window
                                                        delete:NO
                                                        length:256];
                    if (nameReply)
                    {
                        char *name = (char *)xcb_get_property_value(nameReply);
                        if (name && strcmp(name, "Dock") == 0)
                        {
                            Class compositorClass = NSClassFromString(@"URSCompositingManager");
                            id<URSCompositingManaging> compositor = nil;
                            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                                compositor = [compositorClass performSelector:@selector(sharedManager)];
                            }
                            if (compositor) {
                                [compositor setSkipShadowForWindow:[window window]];
                            }
                        }
                        free(nameReply);
                    }
                }

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeMenu]])
            {
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window updatePid];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeMenu]];
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypePopupMenu]])
            {
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window updatePid];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypePopupMenu]];
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDropdownMenu]])
            {
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window updatePid];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDropdownMenu]];
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeTooltip]])
            {
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window updatePid];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeTooltip]];
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDesktop]])
            {
                //NSLog(@"Desktop window %u to be registered", [window window]);
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                if (!self.adoptingExistingWindows)
                    [window stackBelow];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDesktop]];
                [window setSkipTaskBar:YES];
                [window setSkipPager:YES];
                [ewmhService updateNetWmState:window];
                
                // Grab button on desktop window so we can track focus changes
                // This ensures _NET_ACTIVE_WINDOW is updated when clicking on desktop
                [window grabButton];
                //NSLog(@"[MapRequest] Grabbed button on desktop window %u for focus tracking", [window window]);

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeTooltip]] ||
                *atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeNotification]] ||
                *atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeSplash]])
            {
                [self registerWindow:window];
                [self mapWindow:window];
                [window setDecorated:NO];
                [window updatePid];
                XCBWindow *parentWindow = [[XCBWindow alloc] initWithXCBWindow:anEvent->parent andConnection:self];
                [window setParentWindow:parentWindow];
                [icccmService wmClassForWindow:window];
                [window setWindowType:[ewmhService EWMHWMWindowTypeDialog]];
                if (!self.adoptingExistingWindows)
                    [window stackAbove];

                window = nil;
                ewmhService = nil;
                name = nil;
                parentWindow = nil;
                free(windowTypeReply);
                return;
            }

            /* Dialogs (e.g. confirmation panels) are real windows and must be
               decorated with a title bar like any normal window.  Only the
               main menu bar (DOCK), dropdown menus (MENU) and the transient
               windows handled above stay undecorated. */

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
                //NSLog(@"Motif undecorated window: %d", [window window]);
                free(motifHints);
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
                //NSLog(@"[MapRequest] Grabbed button on undecorated window %u for focus tracking", [window window]);

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
            
            [window onScreen];
            [window updateAttributes];
        }

        [window updateRectsFromGeometries];
        [window setFirstRun:YES];
        [window setWindowType:name];
        // Record _NET_WM_PID so z-order/restack logic can tell which windows
        // belong to the focused application (see restackDockWindowsAbove).
        [window updatePid];
        // windowTypeReply already freed above if it was non-NULL
        name = nil;
    }

    [window onScreen]; // TODO: Just called in the else before this? really necessary?
    XCBScreen *screen = [window screen];
    if (screen == nil && [screens count] > 0) {
        screen = [screens objectAtIndex:0];
    }
    
    // Check if compositor is active for ARGB alpha transparency support
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    BOOL compositorActive = NO;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
        id manager = [compositorClass sharedManager];
        if ([manager respondsToSelector:@selector(compositingActive)]) {
            compositorActive = [manager compositingActive];
        }
    }

    // Query border color from theme (e.g. Eau's controlStrokeColor), with fallback
    uint32_t borderPixel = 0xC0C0C0;
    GSTheme *theme = [GSTheme theme];
    if ([theme respondsToSelector:@selector(windowFrameBorderColor)]) {
        NSColor *borderColor = [(id)theme performSelector:@selector(windowFrameBorderColor)];
        if (borderColor) {
            borderColor = [borderColor colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
            CGFloat r, g, b, a;
            [borderColor getRed:&r green:&g blue:&b alpha:&a];
            borderPixel = ((uint8_t)(r * 255) << 16) | ((uint8_t)(g * 255) << 8) | (uint8_t)(b * 255);
        }
    }

    // Without a compositor the only window outline is the frame background
    // showing through the clientBorder strips around the client.  Theme stroke
    // colors are tuned for composited drop shadows and can be near-invisible
    // here, so pin the strips to a fixed mid grey that separates windows on
    // any background.  With compositing on, drop shadows separate windows and
    // the theme color applies.
    if (!compositorActive) {
        borderPixel = 0x808080;
    }

    XCBVisual *visual = nil;
    uint32_t values[4];  // May need up to 4 values for ARGB (back_pixel, border_pixel, colormap, event_mask)
    uint32_t valueMask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint8_t depth = 0;  // 0 = use root_depth
    xcb_colormap_t argbColormap = XCB_NONE;
    xcb_visualid_t argbVisualId = 0;

    if (screen) {
        visual = [[XCBVisual alloc] initWithVisualId:[screen screen]->root_visual];
        [visual setVisualTypeForScreen:screen];
        depth = [screen screen]->root_depth;

        // If compositor is active, try to use 32-bit ARGB visual for alpha transparency
        if (compositorActive) {
            xcb_visualtype_t *argbVisualType = NULL;
            argbVisualId = findARGBVisual([screen screen], &argbVisualType);

            if (argbVisualId != 0 && argbVisualType != NULL) {
                //NSLog(@"[XCBConnection] Creating frame with 32-bit ARGB visual (0x%x) for compositor alpha", argbVisualId);

                // Create colormap for ARGB visual (required for 32-bit windows)
                argbColormap = xcb_generate_id(connection);
                xcb_create_colormap(connection,
                                   XCB_COLORMAP_ALLOC_NONE,
                                   argbColormap,
                                   [screen screen]->root,
                                   argbVisualId);

                // Set up ARGB visual
                visual = [[XCBVisual alloc] initWithVisualId:argbVisualId];
                [visual setVisualType:argbVisualType];
                depth = 32;

                // For 32-bit windows: back_pixel, border_pixel, event_mask, colormap
                // XCB_CW values must be in ascending bit order: 2, 8, 2048, 8192
                valueMask = XCB_CW_BACK_PIXEL | XCB_CW_BORDER_PIXEL | XCB_CW_EVENT_MASK | XCB_CW_COLORMAP;
                values[0] = (0xFF << 24) | borderPixel;  // back_pixel = border color (opaque)
                values[1] = 0;  // border_pixel = transparent
                values[2] = FRAMEMASK;  // event_mask
                values[3] = argbColormap;  // colormap
            } else {
                //NSLog(@"[XCBConnection] No ARGB visual found, using standard 24-bit frame");
                values[0] = borderPixel;  // border color
                values[1] = FRAMEMASK;
            }
        } else {
            // Non-compositor mode: use border color background
            values[0] = borderPixel;  // border color
            values[1] = FRAMEMASK;
        }
    } else {
        values[0] = borderPixel;  // border color
        values[1] = FRAMEMASK;
    }

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHeight = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    int16_t reqX = [window windowRect].position.x;
    int16_t reqY = [window windowRect].position.y;
    uint16_t reqW = [window windowRect].size.width;
    uint16_t reqH = [window windowRect].size.height;

    // In compositor mode (drop shadows), the client sits flush inside the frame
    // with no pixel-wide border strips, so cb=0.  Non-compositor uses cb=1.
    // Scale cb by GSScaleFactor for HiDPI displays.
    CGFloat cbScaleFactor = [[TitleBarSettingsService sharedInstance] scaleFactor];
    int cb = compositorActive ? 0 : (int)cbScaleFactor;

    // Determine if we should reposition the window.
    // When adopting pre-existing windows at startup, never reposition them.
    // Otherwise, reposition unless the application set the window's screen
    // coordinates itself (WM_NORMAL_HINTS USPosition / PPosition) — those
    // are mapped directly at the requested location.  Dialogs get centered
    // (golden ratio) placement; other windows get cascading.
    BOOL shouldReposition = NO;
    BOOL isDialog = NO;

    if (!self.adoptingExistingWindows) {
        // The WM is the authority on window placement.  Cascade all
        // newly mapped non-dialog, non-desktop, non-fullscreen windows
        // whose position the application did not set itself.
        BOOL isFullWidth = NO;
        if (screen && reqW >= [screen width]) {
            isFullWidth = YES;
        }

        BOOL appPositioned = [icccmService windowSpecifiesPosition:window];
        if (appPositioned && screen) {
            /* A requested position whose window — frame included — would
               hug the screen's bottom-left corner (its bottom-left corner
               at (0,0) in the app's bottom-left-origin coordinate system)
               is what apps pass when they have no real position.  Ignore
               it and cascade instead, unless the window spans the full
               width or height (docks, panels). */
            int32_t screenW = [screen width];
            int32_t screenH = [screen height];
            int32_t frameHeight = (int32_t)reqH + titleHeight + cb;
            int32_t frameBottom = (int32_t)reqY + frameHeight;
            BOOL fullSpan = ((int32_t)reqW >= screenW) || (frameHeight >= screenH);
            if (reqX <= 0 && frameBottom >= screenH && !fullSpan) {
                appPositioned = NO;
            }
        }

        if (!appPositioned && !isFullWidth) {
            shouldReposition = YES;
        }
    } else {
        //NSLog(@"[MapRequest] Skipping WM placement override for adopted window %u", [window window]);
    }

    // Determine if this window is a dialog via _NET_WM_WINDOW_TYPE.
    if (shouldReposition && [window windowType] != nil && ewmhService != nil) {
        isDialog = [[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDialog]];
    }

    // GNUstep's DPSplacewindow uses _XFrameToXHints which places the CLIENT at the
    // desired FRAME top-left position (not the content area position). So reqX/reqY
    // are already the frame coordinates — do NOT subtract cb or titleHeight.
    int16_t xPos = reqX;
    int16_t yPos = reqY;
    uint16_t winWidth = reqW + 2 * (uint16_t)cb;
    uint16_t winHeight = reqH + titleHeight + (uint16_t)cb;

    //NSLog(@"[MapRequest] Requested position for window %u: %d, %d (size %ux%u)", [window window], xPos, yPos, winWidth, winHeight);

    if (shouldReposition && screen) {
        uint16_t screenWidth = [screen width];
        uint16_t screenHeight = [screen height];

        if (isDialog) {
            // Dialogs: centered horizontally, golden ratio vertically within raw screen
            xPos = (screenWidth - winWidth) / 2;
            yPos = (screenHeight - winHeight) * 0.381966;
        } else {
            // Classic HIG: step diagonally by window count.
            XCBSize winSize = {winWidth, winHeight};
            XCBPoint pos = [self nextCascadePositionForSize:winSize
                                                  screenX:0
                                                  screenY:0
                                             screenWidth:screenWidth
                                            screenHeight:screenHeight];
            xPos = pos.x;
            yPos = pos.y;
        }

        // Keep the client rect in root coordinates while frame uses xPos/yPos.
        XCBRect newRect = [window windowRect];
        newRect.position.x = xPos + cb;
        newRect.position.y = yPos + titleHeight;
        [window setWindowRect:newRect];
    }

    XCBCreateWindowTypeRequest *request = [[XCBCreateWindowTypeRequest alloc] initForWindowType:XCBFrameRequest];
    [request setDepth:(depth > 0 ? depth : 24)];
    [request setParentWindow:(screen ? [screen rootWindow] : 0)];
    [request setXPosition:xPos];
    [request setYPosition:yPos];
    [request setWidth:winWidth];
    [request setHeight:winHeight];
    [request setBorderWidth:0];
    [request setXcbClass:XCB_WINDOW_CLASS_INPUT_OUTPUT];
    [request setVisual:visual];
    [request setValueMask:valueMask];
    [request setValueList:values];
    [request setClientWindow:window];

    XCBWindowTypeResponse *response = [self createWindowForRequest:request registerWindow:YES];

    XCBFrame *frame = [response frame];

    // Prevent X server from clearing the frame to background_pixel (white) on
    // every resize.  Default ForgetGravity discards all pixels; NorthWestGravity
    // preserves existing content and only exposes truly new areas.
    uint32_t gravity = XCB_GRAVITY_NORTH_WEST;
    xcb_change_window_attributes(connection, [frame window], XCB_CW_BIT_GRAVITY, &gravity);

    // If using ARGB visual, configure frame for 32-bit rendering
    if (depth == 32 && argbColormap != XCB_NONE) {
        [frame setUse32BitDepth:YES];
        [frame setArgbVisualId:argbVisualId];
        //NSLog(@"[XCBConnection] Configured frame for 32-bit ARGB rendering");
    }

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

    // EWMH spec: _NET_FRAME_EXTENTS must be set on the CLIENT window.
    {
        uint32_t extents[] = { (uint32_t)cb, (uint32_t)cb, (uint32_t)titleHeight, (uint32_t)cb };
        [ewmhService updateNetFrameExtentsForWindow:window andExtents:extents];
    }
    /*[self mapWindow:frame];
    [self registerWindow:window];*/

    //NSLog(@"Client window decorated with id %u at %d,%d", [window window], xPos, yPos);
    [frame initCursor];  // Must init cursor BEFORE decorateClientWindow - resize zones need it
    // Map the frame BEFORE decorating so that a pre-existing mapped client is reparented into
    // an already-mapped parent. Reparenting a mapped window into an *unmapped* frame causes the
    // X server to enqueue an XCB_UNMAP_NOTIFY for the client (frame has SubstructureNotify);
    // when the event loop later processes that event it would call handleUnMapNotify and destroy
    // the very frame we just created.  Mapping first prevents the UnmapNotify entirely.
    [self mapWindow:frame];
    [frame decorateClientWindow];
    [self registerWindow:window];
    [window setParentWindow:frame];
    [window updateAttributes];
    [frame setScreen:[window screen]];
    [window setNormalState];
    [frame setNormalState];

    if ([[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]]) {
        [window setSkipTaskBar:YES];
        [window setSkipPager:YES];
        [ewmhService updateNetWmState:window];
        if (!self.adoptingExistingWindows)
            [frame stackBelow];
    } else if ([[window windowType] isEqualToString:[ewmhService EWMHWMWindowTypeUtility]]) {
        [window setSkipTaskBar:YES];
        [window setSkipPager:YES];
        [window setIsAbove:YES];
        [ewmhService updateNetWmState:window];
        if (!self.adoptingExistingWindows) {
            [frame stackAbove];
            [frame raiseResizeHandle];
            [self restackDockWindowsAbove];
        }
    } else {
        if (!self.adoptingExistingWindows) {
            [frame stackAbove];
            [frame raiseResizeHandle];
            [self restackDockWindowsAbove];
        }
    }
    [[frame childWindowForKey:TitleBar] setIsAbove:YES];
    [self drawAllTitleBarsExcept:(XCBTitleBar*)[frame childWindowForKey:TitleBar]];
    [icccmService wmClassForWindow:window];
    [frame configureClient];

    // Fade in + grow slightly for the newly created window.
    // Brand-new window: the birth rect may apply.
    [self animateMappedWindow:[frame window]
                     clientId:[window window]
                   windowRect:[frame windowRect]
                    newWindow:YES];

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
    //NSLog(@"[%@] Unmap request for window %u", NSStringFromClass([self class]), [window window]);
    [self unmapWindow:window];
    [self setNeedFlush:YES];
    window = nil;
}

/* Finder-style close animation protocol.  The Workspace app sends a
 * _WINDOW_CLOSE_ANIMATION client message from windowWillClose: while the
 * window is still mapped.  data32: [0]=animationType, [1..4]=target x,y,w,h
 * (X11 root coords).  This only PREPARES the animation (captures a snapshot of
 * the still-mapped window and stores the target rect on the frame); the app's
 * subsequent orderOut / UnmapNotify triggers the actual shrink+fade.  The
 * message name is vendor-neutral (like the _WINDOW_BIRTH_ANIMATION atoms) so
 * the protocol could be standardized. */
- (void)prepareCloseAnimationForClient:(xcb_window_t)clientId
                          animationType:(int32_t)animationType
                             targetRect:(XCBRect)targetRect
{
    XCBWindow *window = [self windowForXCBId:clientId];
    if (window == nil) {
        return;
    }
    XCBWindow *frame = nil;
    if ([[window parentWindow] isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)[window parentWindow];
    } else {
        return;
    }

    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    id<URSCompositingManaging> compositor = nil;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
        compositor = [compositorClass performSelector:@selector(sharedManager)];
    }
    if (!compositor || ![compositor compositingActive]) {
        // No compositor: nothing to animate; the app's own orderOut closes it.
        return;
    }

    XCBWindow *target = (XCBWindow *)frame;
    /* The animation runs on the FRAME (the compositor only paints top-level
     * windows), so the snapshot and closeAnimating flag must target the frame,
     * not the client - the client is unmapped before the animation starts and
     * its picture would be empty anyway. */

    /* Store the parameters and mark the frame so the client's UnmapNotify
     * (the close event) starts the animation. */
    [(XCBFrame *)frame setCloseAnimationType: animationType];
    [(XCBFrame *)frame setCloseAnimationTargetRect: targetRect];
    [(XCBFrame *)frame setCloseAnimationPrepared: YES];

    /* Capture a snapshot of the still-mapped window NOW (the client has not
     * been ordered out yet) and keep the frame's picture alive across the
     * client's unmap.  The frame itself is never unmapped by the app - only
     * the client child is - so the frame stays in the paint list and viewable
     * while closeAnimating. */
    if ([compositor respondsToSelector:@selector(captureCloseSnapshotNowForWindow:)]) {
        [compositor captureCloseSnapshotNowForWindow:[target window]];
    }
}

/* Trigger the shrink/fade close animation for a frame whose close message was
 * prepared.  Called from handleUnMapNotify: when the client's UnmapNotify
 * arrives - that event IS the window close.  The animation completion performs
 * the frame teardown (reparent the already-unmapped client to root, undecorate,
 * unregister, destroy the frame). */
- (void)startCloseAnimationForFrame:(XCBFrame *)frame
{
    if (frame == nil) {
        return;
    }
    XCBRect targetRect = [frame closeAnimationTargetRect];
    int32_t animationType = [frame closeAnimationType];

    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    id<URSCompositingManaging> compositor = nil;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
        compositor = [compositorClass performSelector:@selector(sharedManager)];
    }
    if (!compositor || ![compositor compositingActive]) {
        return;
    }

    XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
    XCBWindow *titleBar = [frame childWindowForKey:TitleBar];
    /* Animate the frame, not the client: the compositor only paints top-level
     * windows (children of root), so animating the client's composite window
     * would never advance (no paintWindow calls, no finishAnimation).  Birth
     * and minimize animate the frame for the same reason. */
    XCBWindow *target = (XCBWindow *)frame;
    XCBRect startRect = [frame windowRect];

    [frame setCloseAnimating: YES];
    /* The frame itself is never unmapped by the app - only the client child
     * is - so it stays in the paint list and viewable while closeAnimating. */
    if ([compositor respondsToSelector:@selector(setCloseAnimating:forWindow:)]) {
        [compositor setCloseAnimating:YES forWindow:[target window]];
    }

    void (^hideWindows)(void) = ^{
        /* Full close teardown, mirroring handleUnMapNotify: - reparent the
         * already-unmapped client to the root, undecorate, unregister, and
         * destroy the frame. */
        if (frame != nil) {
            [frame setCloseAnimating: NO];
        }
        if (clientWindow != nil) {
            XCBWindow *rootWin = [[clientWindow queryTree] rootWindow];
            [self reparentWindow:clientWindow toWindow:rootWin position:[frame windowRect].position];
            [clientWindow setDecorated:NO];
        }
        if (frame != nil) {
            [self unregisterWindow:frame];
            [[frame getChildren] removeAllObjects];
            [frame destroy];
        }
        if (titleBar != nil) {
            [self unregisterWindow:titleBar];
        }
        if (clientWindow != nil) {
            [self unregisterWindow:clientWindow];
        }
    };

    if (animationType == WindowCloseAnimationShrinkToIcon
        && FnCheckXCBRectIsValid(targetRect)
        && targetRect.size.width > 0 && targetRect.size.height > 0) {
        // Shrink+fade toward the folder icon's current position.
        if ([compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:completion:)]) {
            [compositor animateWindowTransition:[target window]
                                        fromRect:startRect
                                          toRect:targetRect
                                        duration:0.20
                                            fade:YES
                                      completion:hideWindows];
            return;
        }
    } else {
        // Plain fade when no valid target is available.
        XCBRect centerRect = startRect;
        centerRect.position.x += centerRect.size.width / 4;
        centerRect.position.y += centerRect.size.height / 4;
        centerRect.size.width /= 2;
        centerRect.size.height /= 2;
        if ([compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:completion:)]) {
            [compositor animateWindowTransition:[target window]
                                        fromRect:startRect
                                          toRect:centerRect
                                        duration:0.20
                                            fade:YES
                                      completion:hideWindows];
            return;
        }
    }

    // No usable compositor transition method - clear the flag so the normal
    // unmap teardown proceeds.
    [frame setCloseAnimating: NO];
}

- (void)handleConfigureWindowRequest:(xcb_configure_request_event_t *)anEvent
{
    uint16_t config_win_mask = 0;
    uint32_t config_win_vals[7];
    unsigned short i = 0;
    XCBWindow *window = [self windowForXCBId:anEvent->window];
    __block BOOL restackDocksAfterConfigure = NO;

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
                if (anEvent->stack_mode == XCB_STACK_MODE_ABOVE) {
                    restackDocksAfterConfigure = YES;
                }
            }
            config_win_mask |= XCB_CONFIG_WINDOW_STACK_MODE;
            ewmhService = nil;
        }

        xcb_configure_window(connection, anEvent->window, config_win_mask, config_win_vals);

        if (restackDocksAfterConfigure) {
            [self restackDockWindowsAbove];
        }

        /* Do NOT send a synthetic ConfigureNotify here.  The
           xcb_configure_window pass-through above is sufficient — the X
           server will generate a real ConfigureNotify when the position
           actually changes.

           Sending a synthetic ConfigureNotify with the raw hint
           coordinates (frame-level position, content-level size) causes
           GNUstep to overwrite its xframe with values that lack the
           styleoffset adjustment.  Because DPSplacewindow optimistically
           pre-sets xframe to {hint.x+l, hint.y+t, w, h}, a synthetic
           event carrying {hint.x, hint.y, w, h} looks like a position
           change, fires GSAppKitWindowMoved, and corrupts NSWindow's
           _frame — leading to cumulative drift on every open/close
           cycle. */

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
        // Safety: verify mouse button 1 is actually pressed.
        // If dragState leaked from a prior interaction, cancel the drag.
        if (!(anEvent->state & XCB_KEY_BUT_MASK_BUTTON_1)) {
            //NSLog(@"DRAG SAFETY: dragState was YES but button 1 not pressed — cancelling phantom drag");
            dragState = NO;
            [window ungrabPointer];
            return;
        }

        frame = (XCBFrame *) [window parentWindow];
        // Only grab if not already grabbed (avoid redundant grabs every motion event)
        if (!window.pointerGrabbed) {
            [window grabPointer];
        }

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

        // Edge and corner snap detection - check if mouse is near screen edges/corners
        if (self.workareaValid) {
            SnapZone detectedZone = SnapZoneNone;

            // Calculate edge proximity (within SNAP_EDGE_THRESHOLD of edge)
            BOOL nearTop = mouseY <= _cachedWorkareaY + SNAP_EDGE_THRESHOLD;
            BOOL nearBottom = mouseY >= _cachedWorkareaY + (int32_t)_cachedWorkareaHeight - SNAP_EDGE_THRESHOLD;
            BOOL nearLeft = mouseX <= _cachedWorkareaX + SNAP_EDGE_THRESHOLD;
            BOOL nearRight = mouseX >= _cachedWorkareaX + (int32_t)_cachedWorkareaWidth - SNAP_EDGE_THRESHOLD;

            // Corner zones: within SNAP_CORNER_THRESHOLD of the corner
            // These define rectangular areas in each corner where quarter-snap triggers
            BOOL inLeftCornerZone = mouseX <= _cachedWorkareaX + SNAP_CORNER_THRESHOLD;
            BOOL inRightCornerZone = mouseX >= _cachedWorkareaX + (int32_t)_cachedWorkareaWidth - SNAP_CORNER_THRESHOLD;
            BOOL inTopCornerZone = mouseY <= _cachedWorkareaY + SNAP_CORNER_THRESHOLD;
            BOOL inBottomCornerZone = mouseY >= _cachedWorkareaY + (int32_t)_cachedWorkareaHeight - SNAP_CORNER_THRESHOLD;

            // Corners: must be near an edge AND in the corner zone of the perpendicular edge
            // e.g., TopLeft = near top edge AND in the left corner zone (not just near left edge)
            if (nearTop && inLeftCornerZone && inTopCornerZone) {
                detectedZone = SnapZoneTopLeft;
            } else if (nearTop && inRightCornerZone && inTopCornerZone) {
                detectedZone = SnapZoneTopRight;
            } else if (nearBottom && inLeftCornerZone && inBottomCornerZone) {
                detectedZone = SnapZoneBottomLeft;
            } else if (nearBottom && inRightCornerZone && inBottomCornerZone) {
                detectedZone = SnapZoneBottomRight;
            } else if (nearLeft && inTopCornerZone && inLeftCornerZone) {
                detectedZone = SnapZoneTopLeft;
            } else if (nearLeft && inBottomCornerZone && inLeftCornerZone) {
                detectedZone = SnapZoneBottomLeft;
            } else if (nearRight && inTopCornerZone && inRightCornerZone) {
                detectedZone = SnapZoneTopRight;
            } else if (nearRight && inBottomCornerZone && inRightCornerZone) {
                detectedZone = SnapZoneBottomRight;
            }
            // Edges: must be near edge but NOT in a corner zone
            else if (nearTop && !inLeftCornerZone && !inRightCornerZone) {
                detectedZone = SnapZoneTop;
            } else if (nearLeft && !inTopCornerZone && !inBottomCornerZone) {
                detectedZone = SnapZoneLeft;
            } else if (nearRight && !inTopCornerZone && !inBottomCornerZone) {
                detectedZone = SnapZoneRight;
            }

            // State machine: track zone entry time, show preview after linger
            if (detectedZone != self.pendingSnapZone) {
                // Entered a new zone (or left all zones)
                if (detectedZone != SnapZoneNone) {
                    //NSLog(@"[Snap] Entered zone %ld (was %ld)", (long)detectedZone, (long)self.pendingSnapZone);
                }
                self.pendingSnapZone = detectedZone;
                self.snapZoneEntryTime = anEvent->time;
                if (self.snapPreviewShown) {
                    [self hideSnapPreview];
                    self.snapPreviewShown = NO;
                }
            } else if (detectedZone != SnapZoneNone) {
                // Still in the same zone - check if linger time has elapsed
                xcb_timestamp_t elapsed = anEvent->time - self.snapZoneEntryTime;
                if (elapsed >= SNAP_LINGER_TIME && !self.snapPreviewShown) {
                    //NSLog(@"[Snap] Linger time elapsed, showing preview for zone %ld", (long)detectedZone);
                    [self showSnapPreviewForZone:detectedZone frame:frame];
                    self.snapPreviewShown = YES;
                }
            }
        }

        window = nil;
        frame = nil;
        needFlush = YES;

        return;
    }

    if ([window isKindOfClass:[XCBFrame class]] && !dragState)
    {
        frame = (XCBFrame *)window;
        if ([frame shaded])
        {
            // Vertical resize is disabled while shaded, so never show a
            // resize cursor - the normal pointer is correct.
            [frame showLeftPointerCursor];
        }
        else
        {
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
            case TopLeftCorner:
                if (![[frame cursor] resizeTopLeftCornerSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case TopRightCorner:
                if (![[frame cursor] resizeTopRightCornerSelected])
                {
                    [frame showResizeCursorForPosition:position];
                }
                break;
            case BottomLeftCorner:
                if (![[frame cursor] resizeBottomLeftCornerSelected])
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
    }
    else if (!dragState)
    {
        // Find the frame from window's parent chain
        XCBWindow *parent = [window parentWindow];
        if ([parent isKindOfClass:[XCBFrame class]])
        {
            frame = (XCBFrame *)parent;
        }

        if (frame)
        {
            // Don't reset cursor for resize zone children - they have
            // their own static cursors set at creation time
            BOOL isResizeChild = NO;
            childrenMask zoneKeys[] = {
                ResizeHandle, ResizeZoneNW, ResizeZoneN, ResizeZoneNE,
                ResizeZoneE, ResizeZoneSE, ResizeZoneS, ResizeZoneSW,
                ResizeZoneW, ResizeZoneGrowBox
            };
            xcb_window_t eventWindow = [window window];
            for (int i = 0; i < 10; i++)
            {
                XCBWindow *zone = [frame childWindowForKey:zoneKeys[i]];
                if (zone && [zone window] == eventWindow)
                {
                    isResizeChild = YES;
                    break;
                }
            }

            if (!isResizeChild && ![[frame cursor] leftPointerSelected])
            {
                [frame showLeftPointerCursor];
            }
        }
    }


    if (resizeState)
    {
        if ([window isKindOfClass:[XCBFrame class]])
            frame = (XCBFrame *) window;

        [frame resize:anEvent xcbConnection:connection];

        // Keep rounded corners visible during interactive resize in non-composited mode.
        // applyRoundedCornersShapeMask() uses cached geometry, so this avoids release-only updates.
        [frame applyRoundedCornersShapeMask];
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

            // Animate the shrink from the current (maximized) rect to the
            // restored rect while the window is still at its old position,
            // then actually move/resize the real window when the animation
            // finishes.  Resizing first would capture the picture at the new
            // (restored) size and the animation would scale the wrong content.
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }

            if (compositor && [compositor compositingActive] &&
                [compositor respondsToSelector:@selector(animateWindowShrink:fromRect:toRect:duration:completion:)]) {
                [compositor animateWindowShrink:[frame window]
                                       fromRect:startRect
                                         toRect:restoredRect
                                       duration:0.22
                                     completion:^{
                    [frame programmaticResizeToRect:restoredRect];
                    [frame setFullScreen:NO];
                    [titleBar setFullScreen:NO];
                    [clientWindow setFullScreen:NO];
                    [frame setIsMaximized:NO];
                    [frame updateAllResizeZonePositions];
                    [frame applyRoundedCornersShapeMask];
                    if (compositor && [compositor respondsToSelector:@selector(invalidateWindowPixmap:)]) {
                        [compositor invalidateWindowPixmap:[frame window]];
                    }
                }];
            } else {
                // Use programmatic resize that follows the same code path as manual resize
                [frame programmaticResizeToRect:restoredRect];
                [frame setFullScreen:NO];
                [titleBar setFullScreen:NO];
                [clientWindow setFullScreen:NO];
                [frame setIsMaximized:NO];
                [frame updateAllResizeZonePositions];
                [frame applyRoundedCornersShapeMask];
                if (compositor && [compositor compositingActive] &&
                    [compositor respondsToSelector:@selector(invalidateWindowPixmap:)]) {
                    [compositor invalidateWindowPixmap:[frame window]];
                }
            }

            clientWindow = nil;
            titleBar = nil;
            frame = nil;
            return;
        }

        XCBScreen *screen = [frame onScreen];

        // Read workarea from root window to respect struts (e.g., menu bar)
        EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
        int32_t workareaX = 0, workareaY = 0;
        uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
        
        XCBWindow *rootWindow = [screen rootWindow];
        if ([ewmhService readWorkareaForRootWindow:rootWindow x:&workareaX y:&workareaY width:&workareaWidth height:&workareaHeight]) {
            //NSLog(@"[Maximize] Using workarea: x=%d, y=%d, width=%u, height=%u", 
            //      workareaX, workareaY, workareaWidth, workareaHeight);
        } else {
            //NSLog(@"[Maximize] No workarea set, using full screen: %u x %u", workareaWidth, workareaHeight);
        }

        XCBRect startRect = [frame windowRect];
        /*** Save pre-maximize rect for restore ***/
        [frame setOldRect:startRect];
        [titleBar setOldRect:[titleBar windowRect]];
        [clientWindow setOldRect:[clientWindow windowRect]];

        /*** Use programmatic resize that follows the same code path as manual resize ***/
        XCBRect targetRect = XCBMakeRect(XCBMakePoint(workareaX, workareaY),
                                          XCBMakeSize(workareaWidth, workareaHeight));

        // Animate the grow from the current rect to the maximized rect while
        // the window is still at its old position, then actually move/resize
        // the real window when the animation finishes.
        Class compositorClass = NSClassFromString(@"URSCompositingManager");
        id<URSCompositingManaging> compositor = nil;
        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
            compositor = [compositorClass performSelector:@selector(sharedManager)];
        }

        if (compositor && [compositor compositingActive] &&
            [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:completion:)]) {
            [compositor animateWindowTransition:[frame window]
                                       fromRect:startRect
                                         toRect:targetRect
                                       duration:0.22
                                           fade:NO
                                     completion:^{
                [frame programmaticResizeToRect:targetRect];
                [frame setFullScreen:YES];
                [frame setIsMaximized:YES];
                [titleBar setFullScreen:YES];
                [clientWindow setFullScreen:YES];
                [titleBar drawTitleBarComponents];
                [frame updateAllResizeZonePositions];
                [frame applyRoundedCornersShapeMask];
                if (compositor && [compositor respondsToSelector:@selector(invalidateWindowPixmap:)]) {
                    [compositor invalidateWindowPixmap:[frame window]];
                }
            }];
        } else if (compositor && [compositor compositingActive] &&
                   [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
            // Fallback without a completion hook: animate, then resize shortly
            // after so the picture is captured at the old rect.
            [compositor animateWindowTransition:[frame window]
                                       fromRect:startRect
                                         toRect:targetRect
                                       duration:0.22
                                           fade:NO];
            // Delay the maximize finish to let the compositor capture the old rect.
            // Store captured state in a dictionary for the timer callback.
            NSMutableDictionary *maximizeInfo = [NSMutableDictionary dictionaryWithDictionary:@{
                @"frame": frame,
                @"posX": @(targetRect.position.x),
                @"posY": @(targetRect.position.y),
                @"width": @(targetRect.size.width),
                @"height": @(targetRect.size.height),
                @"titleBar": titleBar,
                @"clientWindow": clientWindow,
            }];
            if (compositor) {
                maximizeInfo[@"compositor"] = compositor;
            }
            [NSTimer scheduledTimerWithTimeInterval:0.22
                                             target:self
                                           selector:@selector(_performDelayedMaximize:)
                                           userInfo:maximizeInfo
                                            repeats:NO];
        } else {
            [frame programmaticResizeToRect:targetRect];
            [frame setFullScreen:YES];
            [frame setIsMaximized:YES];
            [titleBar setFullScreen:YES];
            [clientWindow setFullScreen:YES];
            [titleBar drawTitleBarComponents];
            [frame updateAllResizeZonePositions];
            [frame applyRoundedCornersShapeMask];
            if (compositor && [compositor compositingActive] &&
                [compositor respondsToSelector:@selector(invalidateWindowPixmap:)]) {
                [compositor invalidateWindowPixmap:[frame window]];
            }
        }
        
        /*** Update resize zone positions if they exist ***/
        [frame updateAllResizeZonePositions];

        // Log geometry right before flushing and applying shape masks
        //NSLog(@"[Maximize] pre-flush geometry frameRect=(%d,%d %u x %u) titleRect=(%d,%d %u x %u) clientRect=(%d,%d %u x %u)",
        //      (int)[frame windowRect].position.x, (int)[frame windowRect].position.y, (unsigned)[frame windowRect].size.width, (unsigned)[frame windowRect].size.height,
        //      (int)[titleBar windowRect].position.x, (int)[titleBar windowRect].position.y, (unsigned)[titleBar windowRect].size.width, (unsigned)[titleBar windowRect].size.height,
        //      (int)[clientWindow windowRect].position.x, (int)[clientWindow windowRect].position.y, (unsigned)[clientWindow windowRect].size.width, (unsigned)[clientWindow windowRect].size.height);

        /*** Flush to ensure X server has processed configure requests ***/
        xcb_flush([self connection]);

        /*** Update shape mask for new dimensions ***/
        [frame applyRoundedCornersShapeMask];
        //NSLog(@"[Maximize] applied rounded corners for frame %u", [frame window]);

        ewmhService = nil;
        rootWindow = nil;
        screen = nil;
        window = nil;
        frame = nil;
        clientWindow = nil;
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
    }

    // Always update _NET_ACTIVE_WINDOW to the client window, regardless of which
    // discovery block ran above (frame click, titlebar click, or frame-child click).
    // Apps without WM_TAKE_FOCUS (e.g. Chrome) rely entirely on this update
    // because focus() alone does not reach updateNetActiveWindow for those apps.
    if (clientWindow) {
        self.expectedFocusWindow = [clientWindow window];
        self.expectedFocusTimestamp = anEvent->time;
        EWMHService *ewmhActiveService = [EWMHService sharedInstanceWithConnection:self];
        //NSLog(@"[handleButtonPress] Setting _NET_ACTIVE_WINDOW to client 0x%x (clicked 0x%x)",
        //      [clientWindow window], [window window]);
        [ewmhActiveService updateNetActiveWindow:clientWindow];
        ewmhActiveService = nil;
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
        [clientWindow focus];
        // Don't raise desktop windows - they should always stay at the bottom
        if (!isDesktopWindow) {
            // Check if this window is already the topmost — if so, skip raising.
            BOOL alreadyTopmost = NO;
            xcb_window_t rootWin = [[[[self screens] firstObject] rootWindow] window];
            xcb_query_tree_cookie_t qtC = xcb_query_tree(connection, rootWin);
            xcb_query_tree_reply_t *qtR = xcb_query_tree_reply(connection, qtC, NULL);
            if (qtR) {
                int n = xcb_query_tree_children_length(qtR);
                xcb_window_t *kids = xcb_query_tree_children(qtR);
                if (n > 0 && kids[n - 1] == [frame window])
                    alreadyTopmost = YES;
                free(qtR);
            }

            if (!alreadyTopmost) {
                [frame stackAbove];
                [frame raiseResizeHandle];
                [self restackDockWindowsAbove];
                // Re-raise all undecorated windows of the same PID
                // (menus, dialogs, popups, etc.) above the parent frame.
                uint32_t winPid = [clientWindow pid];
                if (winPid > 0) {
                    for (XCBWindow *w in [windowsMap allValues]) {
                        if ([w pid] != winPid) continue;
                        if ([w isKindOfClass:[XCBFrame class]]) continue;
                        if (![w decorated]) {
                            [w stackAbove];
                        }
                    }
                }
            }
        }
    } else if (window && [window isKindOfClass:[XCBWindow class]]) {
        // Fallback: If we couldn't find client/frame but have a window, focus it directly
        // Don't focus or raise desktop windows — they must stay at the bottom.
        // Focusing the desktop sends _NET_ACTIVE_WINDOW which prompts the workspace
        // application to reconfigure itself above other windows.
        if (!isDesktopWindow) {
            [window focus];
        }
        if (!isDesktopWindow) {
            BOOL alreadyTopmost = NO;
            xcb_window_t rootWin2 = [[[[self screens] firstObject] rootWindow] window];
            xcb_query_tree_cookie_t qtC = xcb_query_tree(connection, rootWin2);
            xcb_query_tree_reply_t *qtR = xcb_query_tree_reply(connection, qtC, NULL);
            if (qtR) {
                int n = xcb_query_tree_children_length(qtR);
                xcb_window_t *kids = xcb_query_tree_children(qtR);
                if (n > 0 && kids[n - 1] == [window window])
                    alreadyTopmost = YES;
                free(qtR);
            }
            if (alreadyTopmost) { [self flush]; }
            else {
                uint32_t values[] = { XCB_STACK_MODE_ABOVE };
                xcb_configure_window(connection, [window window], XCB_CONFIG_WINDOW_STACK_MODE, values);
                [self flush];
                [self restackDockWindowsAbove];
            }
            uint32_t winPid = [window pid];
            if (winPid > 0) {
                for (XCBWindow *w in [windowsMap allValues]) {
                    if ([w pid] != winPid) continue;
                    if ([w isKindOfClass:[XCBFrame class]]) continue;
                    if (![w decorated]) {
                        [w stackAbove];
                    }
                }
            }
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
    if (![titleBar isGSThemeActive]) {
        [titleBar drawTitleBarComponents];
        [self drawAllTitleBarsExcept:titleBar];
    }

    XCBRect frameRect = [frame windowRect];
    XCBPoint relativeOffset = XCBMakePoint(anEvent->root_x - frameRect.position.x, anEvent->root_y - frameRect.position.y);
    [frame setOffset:relativeOffset];

    if ([frame window] != anEvent->root && [[frame childWindowForKey:ClientWindow] canMove])
    {
        dragState = YES;

        // Keep rounded corners stable during move in non-composited mode.
        // This is a cheap one-time call per drag and repairs any stale mask state.
        [frame applyRoundedCornersShapeMask];
        
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
            // Re-apply rounded corner shape masks now that resize is final.
            // Doing this during the resize motion would block on xcb_get_geometry
            // on every pixel of movement, causing wild size jumps.
            [frame applyRoundedCornersShapeMask];
            [frame updateAllResizeZonePositions];
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

    // Execute snap if preview was shown and we're in a snap zone
    if (self.snapPreviewShown && self.pendingSnapZone != SnapZoneNone) {
        // Get the frame from the titlebar if we were dragging it
        XCBFrame *snapFrame = nil;
        if ([window isKindOfClass:[XCBTitleBar class]]) {
            snapFrame = (XCBFrame *)[window parentWindow];
        } else if ([window isKindOfClass:[XCBFrame class]]) {
            snapFrame = (XCBFrame *)window;
        }

        if (snapFrame) {
            [self executeSnapForZone:self.pendingSnapZone frame:snapFrame];
        }
    }

    // Always clean up snap state
    [self hideSnapPreview];
    self.pendingSnapZone = SnapZoneNone;
    self.snapPreviewShown = NO;

    // Always ungrab pointer directly — the release may arrive on a different window
    // than the one that was grabbed (e.g., frame vs titlebar), so we can't rely on
    // the per-window pointerGrabbed flag.
    xcb_ungrab_pointer(connection, XCB_CURRENT_TIME);
    [self flush];
    dragState = NO;
    self.workareaValid = NO;  // Clear cached workarea
    resizeState = NO;
    window = nil;
    frame = nil;
}

- (void)handleFocusOut:(xcb_focus_out_event_t *)anEvent
{
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
            // If this is a titlebar or child of a frame, use the frame's client window
            else if ([window isKindOfClass:[XCBTitleBar class]] ||
                     ([window parentWindow] && [[window parentWindow] isKindOfClass:[XCBFrame class]])) {
                XCBFrame *frame = [window isKindOfClass:[XCBTitleBar class]] ?
                                (XCBFrame *)[window parentWindow] :
                                (XCBFrame *)[window parentWindow];
                if (frame) {
                    XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
                    if (clientWindow) {
                        targetWindowId = [clientWindow window];
                        targetWindow = clientWindow;
                    }
                }
            }
            // For undecorated client windows or direct focus targets, use the window itself
            else {
                targetWindowId = [window window];
                targetWindow = window;
            }

            if (targetWindow != nil && targetWindowId != 0) {
                // Check if this FocusIn is from our own focus call
                if (targetWindowId == self.expectedFocusWindow) {
                    // Skip - this FocusIn is from our own explicit focus call
                    // The updateNetActiveWindow was already called in the focus method
                } else {
                    // External focus change - do the update
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

    XCBWindow *window = [self windowForXCBId:anEvent->window];

    if (!window)
    {
        atomService = nil;
        name = nil;
        return;
    }

    if ([name isEqualToString:@"_NET_WM_BYPASS_COMPOSITOR"])
    {
        // The client may set this only after the window is mapped, so re-apply
        // the compositor's redirect state when it changes.  See
        // -updateBypassCompositorForWindow: in URSCompositingManager.
        Class compositorClass = NSClassFromString(@"URSCompositingManager");
        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)])
        {
            id<URSCompositingManaging> compositor = [compositorClass performSelector:@selector(sharedManager)];
            [compositor updateBypassCompositorForWindow:anEvent->window];
        }
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
                //NSLog(@"PropertyNotify: Window %u identified as desktop type - stacking below", anEvent->window);
                [window setWindowType:[ewmhService EWMHWMWindowTypeDesktop]];
                [window stackBelow];
                [window setSkipTaskBar:YES];
                [window setSkipPager:YES];
                [ewmhService updateNetWmState:window];
            }
            else if (*atom == [[ewmhService atomService] atomFromCachedAtomsWithKey:[ewmhService EWMHWMWindowTypeDock]])
            {
                //NSLog(@"PropertyNotify: Window %u identified as dock type - stacking above", anEvent->window);
                [window setWindowType:[ewmhService EWMHWMWindowTypeDock]];
                [window stackAbove];

                // Only skip drop shadow for the Dock panel (identified by _NET_WM_NAME "Dock"),
                // not all DOCK-type windows (some may be opaque panels that need shadows)
                {
                    xcb_atom_t utf8Atom = [atomService atomFromCachedAtomsWithKey:[ewmhService UTF8_STRING]];
                    void *nameReply = [ewmhService getProperty:[ewmhService EWMHWMName]
                                                  propertyType:utf8Atom
                                                     forWindow:window
                                                        delete:NO
                                                        length:256];
                    if (nameReply)
                    {
                        char *name = (char *)xcb_get_property_value(nameReply);
                        if (name && strcmp(name, "Dock") == 0)
                        {
                            Class compositorClass = NSClassFromString(@"URSCompositingManager");
                            id<URSCompositingManaging> compositor = nil;
                            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                                compositor = [compositorClass performSelector:@selector(sharedManager)];
                            }
                            if (compositor) {
                                [compositor setSkipShadowForWindow:[window window]];
                            }
                        }
                        free(nameReply);
                    }
                }
            }
            free(windowTypeReply);
        }
    }

    // Handle _NET_WORKAREA changes on root window to update cached workarea
    XCBScreen *screen = [[self screens] objectAtIndex:0];
    XCBWindow *rootWindow = [screen rootWindow];
    if ([name isEqualToString:[ewmhService EWMHWorkarea]] && anEvent->window == [rootWindow window])
    {
        //NSLog(@"PropertyNotify: _NET_WORKAREA changed on root window - updating cached workarea");
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

    // Handle Gershwin-specific window commands
    if ([atomMessageName isEqualToString:@"_GERSHWIN_CENTER_WINDOW"]) {
        //NSLog(@"[ClientMessage] Center Window requested");
        [self centerActiveWindow];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_LEFT"]) {
        //NSLog(@"[ClientMessage] Tile Left requested");
        [self tileActiveWindowLeft];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_RIGHT"]) {
        //NSLog(@"[ClientMessage] Tile Right requested");
        [self tileActiveWindowRight];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_TOP_LEFT"]) {
        //NSLog(@"[ClientMessage] Tile Top Left requested");
        [self tileActiveWindowToZone:SnapZoneTopLeft];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_TOP_RIGHT"]) {
        //NSLog(@"[ClientMessage] Tile Top Right requested");
        [self tileActiveWindowToZone:SnapZoneTopRight];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_BOTTOM_LEFT"]) {
        //NSLog(@"[ClientMessage] Tile Bottom Left requested");
        [self tileActiveWindowToZone:SnapZoneBottomLeft];
        return;
    }
    if ([atomMessageName isEqualToString:@"_GERSHWIN_TILE_BOTTOM_RIGHT"]) {
        //NSLog(@"[ClientMessage] Tile Bottom Right requested");
        [self tileActiveWindowToZone:SnapZoneBottomRight];
        return;
    }
    if ([atomMessageName isEqualToString:@"_WINDOW_CLOSE_ANIMATION"]) {
        // data32: [0]=animationType, [1..4]=target x,y,w,h (X11 root coords).
        int32_t animType = (anEvent->format == 32 && anEvent->type != XCB_NONE)
                           ? (int32_t)anEvent->data.data32[0] : WindowCloseAnimationFade;
        XCBRect targetRect = XCBInvalidRect;
        if (anEvent->format == 32) {
            targetRect = XCBMakeRect(XCBMakePoint(anEvent->data.data32[1],
                                                   anEvent->data.data32[2]),
                                      XCBMakeSize(anEvent->data.data32[3],
                                                   anEvent->data.data32[4]));
        }
        [self prepareCloseAnimationForClient:anEvent->window
                               animationType:animType
                                  targetRect:targetRect];
        return;
    }

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
                titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar]; //TODO: Can i put all this in a single method?
                if (![titleBar isGSThemeActive]) {
                    [titleBar drawTitleBarComponents];
                    [self drawAllTitleBarsExcept:titleBar];
                }
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
        //NSLog(@"[WM_CHANGE_STATE] Minimizing window %u", anEvent->window);

        XCBWindow *targetWindow = frame ? (XCBWindow *)frame : window;
        if (targetWindow) {
            Class compositorClass = NSClassFromString(@"URSCompositingManager");
            id<URSCompositingManaging> compositor = nil;
            if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
                compositor = [compositorClass performSelector:@selector(sharedManager)];
            }

            XCBWindow *iconWindow = clientWindow ? clientWindow : targetWindow;
            XCBRect iconRect = XCBInvalidRect;
            [self resolveIconGeometryForWindow:iconWindow outRect:&iconRect];
            XCBRect startRect = [targetWindow windowRect];

            if (compositor && [compositor compositingActive]) {
                // Defer unmap until the compositor finishes the minimize
                // animation, so the window stays in the X server tree and
                // the compositor's stacking order cache can find it.
    void (^hideWindows)(void) = ^{
                    if (frame != nil) {
                        [frame setIconicState];
                        [frame setIsMinimized:YES];
                        [self unmapWindow:frame];
                    }
                    if (titleBar != nil) {
                        [self unmapWindow:titleBar];
                    }
                    if (clientWindow) {
                        [clientWindow setIconicState];
                        [clientWindow setIsMinimized:YES];
                        [self unmapWindow:clientWindow];
                    }
                };
                [compositor animateWindowMinimize:[targetWindow window]
                                        fromRect:startRect
                                          toRect:iconRect
                                      completion:hideWindows];
            } else {
                // No compositor — hide immediately
                if (frame != nil) {
                    [frame setIconicState];
                    [frame setIsMinimized:YES];
                    [self unmapWindow:frame];
                }
                if (titleBar != nil) {
                    [self unmapWindow:titleBar];
                }
                if (clientWindow) {
                    [clientWindow setIconicState];
                    [clientWindow setIsMinimized:YES];
                    [self unmapWindow:clientWindow];
                }
            }
        }

        //NSLog(@"[WM_CHANGE_STATE] Window minimized (hidden)");
    }
    else if ([frame isMinimized] &&
             anEvent->type == [atomService atomFromCachedAtomsWithKey:[icccmService WMChangeState]] &&
             anEvent->format == 32 &&
             anEvent->data.data32[0] != ICCCM_WM_STATE_ICONIC)
    {
        //NSLog(@"[WM_CHANGE_STATE] Restoring window %u", anEvent->window);

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
        [self restackDockWindowsAbove];
        [clientWindow focus];
        [self drawAllTitleBarsExcept:titleBar];

        //NSLog(@"[WM_CHANGE_STATE] Window restored");
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
        // Resize is disabled while shaded, so never advertise a resize cursor.
        if (![frameWindow shaded])
        {
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
        }

        // Hover-peek: rolling a shaded window down at reduced opacity while
        // the pointer rests on its titlebar (or a titlebar subwindow).
        XCBTitleBar *titlebar = (XCBTitleBar *)[frameWindow childWindowForKey:TitleBar];
        BOOL isTitlebar = titlebar &&
            (anEvent->event == [titlebar window] ||
             [[window parentWindow] isKindOfClass:[XCBTitleBar class]]);
        // Ignore moves between the titlebar and its own subwindows (buttons):
        // detail INFERIOR means the pointer went to a child, still on the
        // titlebar decoration, so the peek must not start/stop.
        if (isTitlebar && [frameWindow shaded] &&
            anEvent->detail != XCB_NOTIFY_DETAIL_INFERIOR)
            [frameWindow beginHoverPeek];

        frameWindow = nil;
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
    // so we can track focus changes for _NET_ACTIVE_WINDOW.
    // Skip menu-type windows: GNUstep handles its own menu mouse tracking,
    // and a synchronous button grab would freeze the pointer, preventing
    // the menu from receiving button-release events.
    if (window && [window isKindOfClass:[XCBWindow class]] && ![window decorated])
    {
        NSString *wType = [window windowType];
        EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:self];
        BOOL isMenu = [wType isEqualToString:[ewmh EWMHWMWindowTypePopupMenu]] ||
                      [wType isEqualToString:[ewmh EWMHWMWindowTypeDropdownMenu]] ||
                      [wType isEqualToString:[ewmh EWMHWMWindowTypeMenu]];
        ewmh = nil;

        if (!isMenu)
        {
            XCBWindow *parent = [window parentWindow];
            if (!parent || ![parent isKindOfClass:[XCBFrame class]])
            {
                [window grabButton];
                //NSLog(@"[EnterNotify] Grabbed button on undecorated window %u", [window window]);
            }
        }
    }

    window = nil;
}

 - (void)handleLeaveNotify:(xcb_leave_notify_event_t *)anEvent
 {
     XCBWindow *window = [self windowForXCBId:anEvent->event];

     // Pointer left the whole window.  If a peek is still active (its titlebar
     // LeaveNotify can be coalesced/lost during a frantic in-out), end it here
     // so the window always rolls back up.  Otherwise re-arm hover-peek so a
     // later hover (after a peek collapsed) can fire again.
     if ([window isKindOfClass:[XCBFrame class]]) {
         XCBFrame *frameWindow = (XCBFrame *)window;
         if (frameWindow.peeking)
             [frameWindow endHoverPeek];
         else
             frameWindow.hoverPeekArmed = YES;
         window = nil;
         return;
     }

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

        // Hover-peek ends when the pointer leaves the titlebar decoration.
        XCBTitleBar *titlebar = (XCBTitleBar *)[frameWindow childWindowForKey:TitleBar];
        BOOL isTitlebar = titlebar &&
            (anEvent->event == [titlebar window] ||
             [[window parentWindow] isKindOfClass:[XCBTitleBar class]]);
        // Only roll up when the pointer truly leaves the titlebar decoration
        // (to the window body or off-window), not when it moves onto a
        // titlebar button (detail INFERIOR = went to a child subwindow).
        if (isTitlebar && frameWindow.peeking &&
            anEvent->detail != XCB_NOTIFY_DETAIL_INFERIOR)
            [frameWindow endHoverPeek];

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
        //NSLog(@"EXPOSE EVENT FOR WINDOW: %u of kind: %@", [window window], NSStringFromClass([window class]));
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

    // Cancel any pending force-quit timer on the client window
    [clientWindow cancelCloseTimer];

    if (frameWindow != nil &&
        [frameWindow needDestroy]) /*evaluete if the check on destroy window is necessary or not */
    {
        titleBarWindow = (XCBTitleBar *) [frameWindow childWindowForKey:TitleBar];
        [self unregisterWindow:[titleBarWindow hideWindowButton]];
        [self unregisterWindow:[titleBarWindow minimizeWindowButton]];
        [self unregisterWindow:[titleBarWindow maximizeWindowButton]];
        [self unregisterWindow:titleBarWindow];
        // Client is going away for good: remove it from the save-set so the
        // X server no longer reparents it if this WM later dies.
        if (clientWindow != nil) {
            xcb_change_save_set([self connection], XCB_SET_MODE_DELETE, [clientWindow window]);
        }
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
    // When GSTheme is active, titlebars are rendered exclusively through
    // focus events (handleFocusChange:), so stacking order must NOT repaint
    // them here.  We still must reset isAbove on every other titlebar so the
    // active-decoration and spinner state stays consistent with focus, but we
    // skip drawTitleBarComponents: that would overwrite the GSTheme pixmaps
    // with the non-GSTheme look.
    BOOL gsTheme = [aTitileBar isGSThemeActive];

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
                    //NSLog(@"Always on top");
                    windows = nil;
                    tmp = nil;
                    frame = nil;
                    clientWindow = nil;
                    titleBar = nil;
                    continue;
                }

                [titleBar setIsAbove:NO];
                [titleBar setButtonsAbove:NO];
                if (!gsTheme) {
                    [titleBar drawTitleBarComponents];
                }
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
                NSLog(@"[WM] Failed to acquire WM selection; killing stale WM and retrying");
                killOtherInstances();
                [self flush];
                usleep(500000);
                acquired = [selector aquireWithWindow:selectionWindow replace:YES];
            }

            if (acquired)
            {
                // Wait for the old WM to handle SelectionClear and release
                // SubstructRedirect (up to 2s total, polling every 100ms)
                for (int i = 0; i < 20; i++)
                {
                    [self flush];
                    usleep(100000);
                    attributesChanged = [rootWindow changeAttributes:values withMask:XCB_CW_EVENT_MASK checked:YES];
                    if (attributesChanged)
                        break;
                }
            }

            if (!attributesChanged)
            {
                NSLog(@"[WM] Replacement attempt failed; killing stale WM instance");
                killOtherInstances();
                [self flush];
                usleep(500000);
                attributesChanged = [rootWindow changeAttributes:values withMask:XCB_CW_EVENT_MASK checked:YES];
            }

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

        //NSLog(@"Subtructure redirect was set to the root window");

        rootWindow = nil;
        screen = nil;
        ewmhService = nil;
        killOtherInstances();
        return YES;
    }

    //NSLog(@"Replacing window manager");

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

    //NSLog(@"Registered as window manager");

    screen = nil;
    rootWindow = nil;
    selector = nil;
    atomName = nil;
    ewmhService = nil;

    killOtherInstances();
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
    // Create notify is sent when a window is created.
    // We typically don't need to take action here as we handle windows on MapRequest.
    // This method is kept for future tracking/debugging, but by default it stays silent.

    XCBWindow *parentWindow = [self windowForXCBId:anEvent->parent];
    if (parentWindow) {
        // New child window under a tracked parent - compositor will pick it up on MapNotify
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

    // End of key combination sequences can be handled here
    // For example, completing Alt+Tab window switching
}

- (void) handleCirculateRequest: (xcb_circulate_request_event_t*)anEvent
{
    // Handle window circulation requests (bring to front/send to back)
    //NSLog(@"[%@] Circulate request for window %u, place: %s",
    //      NSStringFromClass([self class]),
    //      anEvent->window,
    //      anEvent->place == XCB_CIRCULATE_RAISE_LOWEST ? "raise" : "lower");

    XCBWindow *window = [self windowForXCBId:anEvent->window];
    if (!window) {
        //NSLog(@"Window %u not found for circulate request", anEvent->window);
        return;
    }

    // Handle the circulation request
    if (anEvent->place == XCB_CIRCULATE_RAISE_LOWEST) {
        // Raise the lowest window to the top
        [window stackAbove];
        [self restackDockWindowsAbove];
        //NSLog(@"Raised window %u to top", anEvent->window);
    } else if (anEvent->place == XCB_CIRCULATE_LOWER_HIGHEST) {
        // Lower the highest window to the bottom
        [window stackBelow];
        //NSLog(@"Lowered window %u to bottom", anEvent->window);
    }

    // If this is a frame window, also handle its children
    if ([window isKindOfClass:[XCBFrame class]]) {
        XCBFrame *frame = (XCBFrame *)window;
        XCBTitleBar *titleBar = (XCBTitleBar *)[frame childWindowForKey:TitleBar];
        if (titleBar) {
            [titleBar setIsAbove:(anEvent->place == XCB_CIRCULATE_RAISE_LOWEST)];
            if (![titleBar isGSThemeActive]) {
                [titleBar drawTitleBarComponents];
            }
        }
    }

    [self setNeedFlush:YES];
}

#pragma mark - Directional Maximize

- (void)ensureWorkareaCache:(XCBFrame*)frame {
    // Ensure workarea is cached if not already valid
    if (!self.workareaValid) {
        XCBScreen *screen = [frame screen];
        if (!screen) {
            // Fallback: use first screen if frame doesn't have one
            screen = [screens firstObject];
            //NSLog(@"[Snap] ensureWorkareaCache: frame has no screen, using first screen");
        }
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

#pragma mark - Window Snap/Tiling

- (void)executeSnapForZone:(SnapZone)zone frame:(XCBFrame *)frame {
    if (!frame || zone == SnapZoneNone) {
        //NSLog(@"[Snap] executeSnapForZone: no frame or zone is None");
        return;
    }

    [self ensureWorkareaCache:frame];
    //NSLog(@"[Snap] executeSnapForZone: zone=%ld workarea=(%d,%d,%u,%u) valid=%d",
    //      (long)zone, _cachedWorkareaX, _cachedWorkareaY,
    //      _cachedWorkareaWidth, _cachedWorkareaHeight, self.workareaValid);

    // Save current rect for restore
    [frame setOldRect:[frame windowRect]];

    XCBRect targetRect;
    switch (zone) {
        case SnapZoneTop:
            // Full maximize
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX, _cachedWorkareaY),
                XCBMakeSize(_cachedWorkareaWidth, _cachedWorkareaHeight));
            [frame setIsMaximized:YES];
            //NSLog(@"[Snap] Maximizing window to workarea");
            break;

        case SnapZoneLeft:
            // Left half of screen
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX, _cachedWorkareaY),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight));
            //NSLog(@"[Snap] Tiling window to left half");
            break;

        case SnapZoneRight:
            // Right half of screen
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX + _cachedWorkareaWidth / 2, _cachedWorkareaY),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight));
            //NSLog(@"[Snap] Tiling window to right half");
            break;

        case SnapZoneTopLeft:
            // Top-left quarter
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX, _cachedWorkareaY),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight / 2));
            //NSLog(@"[Snap] Tiling window to top-left quarter");
            break;

        case SnapZoneTopRight:
            // Top-right quarter
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX + _cachedWorkareaWidth / 2, _cachedWorkareaY),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight / 2));
            //NSLog(@"[Snap] Tiling window to top-right quarter");
            break;

        case SnapZoneBottomLeft:
            // Bottom-left quarter
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX, _cachedWorkareaY + _cachedWorkareaHeight / 2),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight / 2));
            //NSLog(@"[Snap] Tiling window to bottom-left quarter");
            break;

        case SnapZoneBottomRight:
            // Bottom-right quarter
            targetRect = XCBMakeRect(
                XCBMakePoint(_cachedWorkareaX + _cachedWorkareaWidth / 2, _cachedWorkareaY + _cachedWorkareaHeight / 2),
                XCBMakeSize(_cachedWorkareaWidth / 2, _cachedWorkareaHeight / 2));
            //NSLog(@"[Snap] Tiling window to bottom-right quarter");
            break;

        default:
            return;
    }

    // Animate if compositor is active
    {
        Class compositorClass = NSClassFromString(@"URSCompositingManager");
        id<URSCompositingManaging> compositor = nil;
        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
            compositor = [compositorClass performSelector:@selector(sharedManager)];
        }
        if (compositor && [compositor compositingActive] &&
            [compositor respondsToSelector:@selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
            XCBRect startRect = [frame windowRect];
            [frame programmaticResizeToRect:targetRect];
            XCBRect endRect = [frame windowRect];
            [compositor animateWindowTransition:[frame window]
                                       fromRect:startRect
                                         toRect:endRect
                                       duration:0.2
                                           fade:NO];
        } else {
            [frame programmaticResizeToRect:targetRect];
        }
    }

    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];

    // Redraw title bar
    XCBTitleBar *titleBar = (XCBTitleBar *)[frame childWindowForKey:TitleBar];
    if (titleBar) {
        [titleBar drawTitleBarComponents];
    }

    [self flush];
}

- (void)showSnapPreviewForZone:(SnapZone)zone frame:(XCBFrame *)frame {
    //NSLog(@"[Snap] showSnapPreviewForZone called with zone=%ld", (long)zone);

    if (zone == SnapZoneNone) {
        [self hideSnapPreview];
        return;
    }

    // Use URSSnapPreviewOverlay if available (loaded from WindowManager app)
    Class overlayClass = NSClassFromString(@"URSSnapPreviewOverlay");
    if (overlayClass && [overlayClass respondsToSelector:@selector(sharedOverlay)]) {
        id overlay = [overlayClass performSelector:@selector(sharedOverlay)];

        // Calculate preview rect based on snap zone
        [self ensureWorkareaCache:frame];

        // Get screen height for X11 to GNUstep coordinate conversion
        // X11: Y=0 at top, GNUstep/NSWindow: Y=0 at bottom
        XCBScreen *xcbScreen = [screens firstObject];
        CGFloat screenHeight = [xcbScreen height];

        CGFloat previewX = 0, previewWidth = 0, previewHeight = 0;
        NSRect previewRect = NSZeroRect;

        switch (zone) {
            case SnapZoneTop:
                previewWidth = _cachedWorkareaWidth;
                previewHeight = _cachedWorkareaHeight;
                previewX = _cachedWorkareaX;
                previewRect = NSMakeRect(previewX,
                                         screenHeight - _cachedWorkareaY - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneLeft:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight;
                previewX = _cachedWorkareaX;
                previewRect = NSMakeRect(previewX,
                                         screenHeight - _cachedWorkareaY - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneRight:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight;
                previewX = _cachedWorkareaX + _cachedWorkareaWidth / 2;
                previewRect = NSMakeRect(previewX,
                                         screenHeight - _cachedWorkareaY - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneTopLeft:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight / 2;
                previewX = _cachedWorkareaX;
                // Top quarter: X11 Y is at workarea top
                previewRect = NSMakeRect(previewX,
                                         screenHeight - _cachedWorkareaY - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneTopRight:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight / 2;
                previewX = _cachedWorkareaX + _cachedWorkareaWidth / 2;
                // Top quarter: X11 Y is at workarea top
                previewRect = NSMakeRect(previewX,
                                         screenHeight - _cachedWorkareaY - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneBottomLeft:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight / 2;
                previewX = _cachedWorkareaX;
                // Bottom quarter: X11 Y is at workarea midpoint
                previewRect = NSMakeRect(previewX,
                                         screenHeight - (_cachedWorkareaY + _cachedWorkareaHeight / 2) - previewHeight,
                                         previewWidth, previewHeight);
                break;
            case SnapZoneBottomRight:
                previewWidth = _cachedWorkareaWidth / 2;
                previewHeight = _cachedWorkareaHeight / 2;
                previewX = _cachedWorkareaX + _cachedWorkareaWidth / 2;
                // Bottom quarter: X11 Y is at workarea midpoint
                previewRect = NSMakeRect(previewX,
                                         screenHeight - (_cachedWorkareaY + _cachedWorkareaHeight / 2) - previewHeight,
                                         previewWidth, previewHeight);
                break;
            default:
                NSLog(@"[Snap] WARNING: Unknown zone %ld in showSnapPreviewForZone", (long)zone);
                return;
        }

        //NSLog(@"[Snap] Showing preview for zone=%ld rect=(%.0f,%.0f,%.0f,%.0f)",
        //      (long)zone, previewRect.origin.x, previewRect.origin.y,
        //      previewRect.size.width, previewRect.size.height);

        if ([overlay respondsToSelector:@selector(showPreviewForRect:)]) {
            // Defer out of the XCB event processing loop so that orderFront:nil
            // inside showPreviewForRect: does not interfere with the active pointer
            // grab, which would prevent further motion events from reaching the drag.
            [overlay performSelector:@selector(showPreviewForRect:)
                          withObject:[NSValue valueWithRect:previewRect]
                          afterDelay:0.0];
        }
    }
}

- (void)hideSnapPreview {
    Class overlayClass = NSClassFromString(@"URSSnapPreviewOverlay");
    if (overlayClass && [overlayClass respondsToSelector:@selector(sharedOverlay)]) {
        id overlay = [overlayClass performSelector:@selector(sharedOverlay)];
        if ([overlay respondsToSelector:@selector(hide)]) {
            [overlay performSelector:@selector(hide)];
        }
    }
}

- (XCBFrame *)getActiveFrame {
    // Read _NET_ACTIVE_WINDOW from root window to find the active window
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self];
    XCBScreen *screen = [screens firstObject];
    if (!screen) {
        return nil;
    }

    XCBWindow *rootWindow = [screen rootWindow];
    if (!rootWindow) {
        return nil;
    }

    // Query _NET_ACTIVE_WINDOW property
    xcb_get_property_reply_t *reply = (xcb_get_property_reply_t *)[ewmhService getProperty:[ewmhService EWMHActiveWindow]
                                                                              propertyType:XCB_ATOM_WINDOW
                                                                                 forWindow:rootWindow
                                                                                    delete:NO
                                                                                    length:1];
    if (!reply || reply->type == XCB_ATOM_NONE || xcb_get_property_value_length(reply) == 0) {
        if (reply) free(reply);
        return nil;
    }

    xcb_window_t *activeWindowId = (xcb_window_t *)xcb_get_property_value(reply);
    xcb_window_t windowId = *activeWindowId;
    free(reply);

    if (windowId == XCB_WINDOW_NONE) {
        return nil;
    }

    // Find the window in our map
    XCBWindow *activeWindow = [self windowForXCBId:windowId];
    if (!activeWindow) {
        return nil;
    }

    // Get the frame
    XCBFrame *frame = nil;
    if ([activeWindow isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)activeWindow;
    } else if ([[activeWindow parentWindow] isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)[activeWindow parentWindow];
    }

    return frame;
}

- (void)tileActiveWindowLeft {
    XCBFrame *frame = [self getActiveFrame];

    if (!frame) {
        //NSLog(@"[Tile] No active window to tile");
        return;
    }

    [self executeSnapForZone:SnapZoneLeft frame:frame];
}

- (void)tileActiveWindowRight {
    XCBFrame *frame = [self getActiveFrame];

    if (!frame) {
        //NSLog(@"[Tile] No active window to tile");
        return;
    }

    [self executeSnapForZone:SnapZoneRight frame:frame];
}

- (void)tileActiveWindowToZone:(SnapZone)zone {
    XCBFrame *frame = [self getActiveFrame];

    if (!frame) {
        //NSLog(@"[Tile] No active window to tile");
        return;
    }

    [self executeSnapForZone:zone frame:frame];
}

- (void)centerActiveWindow {
    XCBFrame *frame = [self getActiveFrame];

    if (!frame) {
        //NSLog(@"[Center] No active window to center");
        return;
    }

    [self ensureWorkareaCache:frame];

    // Get current window size
    XCBRect currentRect = [frame windowRect];
    uint32_t windowWidth = currentRect.size.width;
    uint32_t windowHeight = currentRect.size.height;

    // Calculate centered position
    int32_t centerX = _cachedWorkareaX + (_cachedWorkareaWidth - windowWidth) / 2;
    int32_t centerY = _cachedWorkareaY + (_cachedWorkareaHeight - windowHeight) / 2;

    // Ensure window stays within workarea
    if (centerX < _cachedWorkareaX) centerX = _cachedWorkareaX;
    if (centerY < _cachedWorkareaY) centerY = _cachedWorkareaY;

    XCBRect targetRect = XCBMakeRect(
        XCBMakePoint(centerX, centerY),
        XCBMakeSize(windowWidth, windowHeight));

    //NSLog(@"[Center] Centering window to (%d, %d)", centerX, centerY);

    // Save current rect for restore
    [frame setOldRect:currentRect];

    [frame programmaticResizeToRect:targetRect];
    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];

    [self flush];
}

- (void)centerFrame:(XCBFrame *)frame {
    if (!frame) {
        //NSLog(@"[Center] No frame to center");
        return;
    }

    [self ensureWorkareaCache:frame];

    XCBRect currentRect = [frame windowRect];
    uint32_t windowWidth = currentRect.size.width;
    uint32_t windowHeight = currentRect.size.height;

    int32_t centerX = _cachedWorkareaX + (_cachedWorkareaWidth - windowWidth) / 2;
    int32_t centerY = _cachedWorkareaY + (_cachedWorkareaHeight - windowHeight) / 2;

    if (centerX < _cachedWorkareaX) centerX = _cachedWorkareaX;
    if (centerY < _cachedWorkareaY) centerY = _cachedWorkareaY;

    XCBRect targetRect = XCBMakeRect(
        XCBMakePoint(centerX, centerY),
        XCBMakeSize(windowWidth, windowHeight));

    //NSLog(@"[Center] Centering frame to (%d, %d)", centerX, centerY);

    [frame setOldRect:currentRect];

    [frame programmaticResizeToRect:targetRect];
    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];

    [self flush];
}

#pragma mark - Timer callbacks (replaces libdispatch usage)

- (void)_performDelayedMaximize:(NSTimer *)timer
{
    NSDictionary *info = timer.userInfo;
    XCBFrame *frame = info[@"frame"];
    XCBTitleBar *titleBar = info[@"titleBar"];
    XCBWindow *clientWindow = info[@"clientWindow"];
    id<URSCompositingManaging> compositor = info[@"compositor"];
    double px = [info[@"posX"] doubleValue];
    double py = [info[@"posY"] doubleValue];
    double w  = [info[@"width"] doubleValue];
    double h  = [info[@"height"] doubleValue];
    XCBPoint pt = {px, py};
    XCBSize sz = {(uint16_t)w, (uint16_t)h};
    XCBRect targetRect = XCBMakeRect(pt, sz);

    [frame programmaticResizeToRect:targetRect];
    [frame setFullScreen:YES];
    [frame setIsMaximized:YES];
    [titleBar setFullScreen:YES];
    [clientWindow setFullScreen:YES];
    [titleBar drawTitleBarComponents];
    [frame updateAllResizeZonePositions];
    [frame applyRoundedCornersShapeMask];
    if (compositor && [compositor respondsToSelector:@selector(invalidateWindowPixmap:)]) {
        [compositor invalidateWindowPixmap:[frame window]];
    }
}

@end
