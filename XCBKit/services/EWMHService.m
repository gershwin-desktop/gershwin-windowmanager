//
//  EWMH.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 07/01/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import "EWMHService.h"
#import "../functions/Transformers.h"
#import "../enums/EEwmh.h"
#import "../services/TitleBarSettingsService.h"
#import "../utils/XCBShape.h"
#import <unistd.h>

@protocol URSCompositingManaging <NSObject>
+ (instancetype)sharedManager;
- (BOOL)compositingActive;
- (void)animateWindowRestore:(xcb_window_t)windowId
                                        fromRect:(XCBRect)startRect
                                            toRect:(XCBRect)endRect;
+ (void)animateZoomRectsFromRect:(XCBRect)startRect
                          toRect:(XCBRect)endRect
                      connection:(XCBConnection *)connection
                          screen:(xcb_screen_t *)screen
                        duration:(NSTimeInterval)duration;
@end

@implementation EWMHService

@synthesize atoms;
@synthesize connection;
@synthesize atomService;


// Root window properties (some are also messages too)
@synthesize EWMHSupported;
@synthesize EWMHClientList;
@synthesize EWMHClientListStacking;
@synthesize EWMHNumberOfDesktops;
@synthesize EWMHDesktopGeometry;
@synthesize EWMHDesktopViewport;
@synthesize EWMHCurrentDesktop;
@synthesize EWMHDesktopNames;
@synthesize EWMHActiveWindow;
@synthesize EWMHWorkarea;
@synthesize EWMHSupportingWMCheck;
@synthesize EWMHVirtualRoots;
@synthesize EWMHDesktopLayout;
@synthesize EWMHShowingDesktop;

// Root Window Messages
@synthesize EWMHCloseWindow;
@synthesize EWMHMoveresizeWindow;
@synthesize EWMHWMMoveresize;
@synthesize EWMHRestackWindow;
@synthesize EWMHRequestFrameExtents;

// Application window properties
@synthesize EWMHWMName;
@synthesize EWMHWMVisibleName;
@synthesize EWMHWMIconName;
@synthesize EWMHWMVisibleIconName;
@synthesize EWMHWMDesktop;
@synthesize EWMHWMWindowType;
@synthesize EWMHWMState;
@synthesize EWMHWMAllowedActions;
@synthesize EWMHWMStrut;
@synthesize EWMHWMStrutPartial;
@synthesize EWMHWMIconGeometry;
@synthesize EWMHWMIcon;
@synthesize EWMHWMPid;
@synthesize EWMHWMHandledIcons;
@synthesize EWMHWMUserTime;
@synthesize EWMHWMUserTimeWindow;
@synthesize EWMHWMFrameExtents;

// The window types (used with EWMH_WMWindowType)
@synthesize EWMHWMWindowTypeDesktop;
@synthesize EWMHWMWindowTypeDock;
@synthesize EWMHWMWindowTypeToolbar;
@synthesize EWMHWMWindowTypeMenu;
@synthesize EWMHWMWindowTypeUtility;
@synthesize EWMHWMWindowTypeSplash;
@synthesize EWMHWMWindowTypeDialog;
@synthesize EWMHWMWindowTypeDropdownMenu;
@synthesize EWMHWMWindowTypePopupMenu;

@synthesize EWMHWMWindowTypeTooltip;
@synthesize EWMHWMWindowTypeNotification;
@synthesize EWMHWMWindowTypeCombo;
@synthesize EWMHWMWindowTypeDnd;

@synthesize EWMHWMWindowTypeNormal;

// The application window states (used with EWMH_WMWindowState)
@synthesize EWMHWMStateModal;
@synthesize EWMHWMStateSticky;
@synthesize EWMHWMStateMaximizedVert;
@synthesize EWMHWMStateMaximizedHorz;
@synthesize EWMHWMStateShaded;
@synthesize EWMHWMStateSkipTaskbar;
@synthesize EWMHWMStateSkipPager;
@synthesize EWMHWMStateHidden ;
@synthesize EWMHWMStateFullscreen;
@synthesize EWMHWMStateAbove;
@synthesize EWMHWMStateBelow;
@synthesize EWMHWMStateDemandsAttention;

// The application window allowed actions (used with EWMH_WMAllowedActions)
@synthesize EWMHWMActionMove;
@synthesize EWMHWMActionResize;
@synthesize EWMHWMActionMinimize;
@synthesize EWMHWMActionShade;
@synthesize EWMHWMActionStick;
@synthesize EWMHWMActionMaximizeHorz;
@synthesize EWMHWMActionMaximizeVert;
@synthesize EWMHWMActionFullscreen;
@synthesize EWMHWMActionChangeDesktop;
@synthesize EWMHWMActionClose;
@synthesize EWMHWMActionAbove;
@synthesize EWMHWMActionBelow;

// Window Manager Protocols
@synthesize EWMHWMPing;
@synthesize EWMHWMSyncRequest;
@synthesize EWMHWMFullscreenMonitors;

// Other properties
@synthesize EWMHWMFullPlacement;
@synthesize UTF8_STRING;
@synthesize MANAGER;
@synthesize KdeNetWFrameStrut;
@synthesize MotifWMHints;

//GNUstep properties
@synthesize GNUStepMiniaturizeWindow;
@synthesize GNUStepHideApp;
@synthesize GNUStepWmAttr;
@synthesize GNUStepTitleBarState;
@synthesize GNUStepFrameOffset;

//Added EWMH properties

@synthesize EWMHStartupId;
@synthesize EWMHFrameExtents;
@synthesize EWMHStrutPartial;
@synthesize EWMHVisibleIconName;

- (id) initWithConnection:(XCBConnection*)aConnection
{
    self = [super init];

    if (self == nil)
    {
        NSLog(@"Unable to init!");
        return nil;
    }

    connection = aConnection;

    // Root window properties (some are also messages too)

    EWMHSupported = @"_NET_SUPPORTED";
    EWMHClientList = @"_NET_CLIENT_LIST";
    EWMHClientListStacking = @"_NET_CLIENT_LIST_STACKING";
    EWMHNumberOfDesktops = @"_NET_NUMBER_OF_DESKTOPS";
    EWMHDesktopGeometry = @"_NET_DESKTOP_GEOMETRY";
    EWMHDesktopViewport = @"_NET_DESKTOP_VIEWPORT";
    EWMHCurrentDesktop = @"_NET_CURRENT_DESKTOP";
    EWMHDesktopNames = @"_NET_DESKTOP_NAMES";
    EWMHActiveWindow = @"_NET_ACTIVE_WINDOW";
    EWMHWorkarea = @"_NET_WORKAREA";
    EWMHSupportingWMCheck = @"_NET_SUPPORTING_WM_CHECK";
    EWMHVirtualRoots = @"_NET_VIRTUAL_ROOTS";
    EWMHDesktopLayout = @"_NET_DESKTOP_LAYOUT";
    EWMHShowingDesktop = @"_NET_SHOWING_DESKTOP";

    // Root Window Messages
    EWMHCloseWindow = @"_NET_CLOSE_WINDOW";
    EWMHMoveresizeWindow = @"_NET_MOVERESIZE_WINDOW";
    EWMHWMMoveresize = @"_NET_WM_MOVERESIZE";
    EWMHRestackWindow = @"_NET_RESTACK_WINDOW";
    EWMHRequestFrameExtents = @"_NET_REQUEST_FRAME_EXTENTS";

    // Application window properties
    EWMHWMName = @"_NET_WM_NAME";
    EWMHWMVisibleName = @"_NET_WM_VISIBLE_NAME";
    EWMHWMIconName = @"_NET_WM_ICON_NAME";
    EWMHWMVisibleIconName = @"_NET_WM_VISIBLE_ICON_NAME";
    EWMHWMDesktop = @"_NET_WM_DESKTOP";
    EWMHWMWindowType = @"_NET_WM_WINDOW_TYPE";
    EWMHWMState = @"_NET_WM_STATE";
    EWMHWMAllowedActions = @"_NET_WM_ALLOWED_ACTIONS";
    EWMHWMStrut = @"_NET_WM_STRUT";
    EWMHWMStrutPartial = @"_NET_WM_STRUT_PARTIAL";
    EWMHWMIconGeometry = @"_NET_WM_ICON_GEOMETRY";
    EWMHWMIcon = @"_NET_WM_ICON";
    EWMHWMPid = @"_NET_WM_PID";
    EWMHWMHandledIcons = @"_NET_WM_HANDLED_ICONS";
    EWMHWMUserTime = @"_NET_WM_USER_TIME";
    EWMHWMUserTimeWindow = @"_NET_WM_USER_TIME_WINDOW";
    EWMHWMFrameExtents = @"_NET_FRAME_EXTENTS";

    // The window types (used with EWMH_WMWindowType)
    EWMHWMWindowTypeDesktop = @"_NET_WM_WINDOW_TYPE_DESKTOP";
    EWMHWMWindowTypeDock = @"_NET_WM_WINDOW_TYPE_DOCK";
    EWMHWMWindowTypeToolbar = @"_NET_WM_WINDOW_TYPE_TOOLBAR";
    EWMHWMWindowTypeMenu = @"_NET_WM_WINDOW_TYPE_MENU";
    EWMHWMWindowTypeUtility = @"_NET_WM_WINDOW_TYPE_UTILITY";
    EWMHWMWindowTypeSplash = @"_NET_WM_WINDOW_TYPE_SPLASH";
    EWMHWMWindowTypeDialog = @"_NET_WM_WINDOW_TYPE_DIALOG";
    EWMHWMWindowTypeDropdownMenu = @"_NET_WM_WINDOW_TYPE_DROPDOWN_MENU";
    EWMHWMWindowTypePopupMenu = @"_NET_WM_WINDOW_TYPE_POPUP_MENU";

    EWMHWMWindowTypeTooltip = @"_NET_WM_WINDOW_TYPE_TOOLTIP";
    EWMHWMWindowTypeNotification = @"_NET_WM_WINDOW_TYPE_NOTIFICATION";
    EWMHWMWindowTypeCombo = @"_NET_WM_WINDOW_TYPE_COMBO";
    EWMHWMWindowTypeDnd = @"_NET_WM_WINDOW_TYPE_DND";

    EWMHWMWindowTypeNormal = @"_NET_WM_WINDOW_TYPE_NORMAL";

    // The application window states (used with EWMH_WMWindowState)
    EWMHWMStateModal = @"_NET_WM_STATE_MODAL";
    EWMHWMStateSticky = @"_NET_WM_STATE_STICKY";
    EWMHWMStateMaximizedVert = @"_NET_WM_STATE_MAXIMIZED_VERT";
    EWMHWMStateMaximizedHorz = @"_NET_WM_STATE_MAXIMIZED_HORZ";
    EWMHWMStateShaded = @"_NET_WM_STATE_SHADED";
    EWMHWMStateSkipTaskbar = @"_NET_WM_STATE_SKIP_TASKBAR";
    EWMHWMStateSkipPager = @"_NET_WM_STATE_SKIP_PAGER";
    EWMHWMStateHidden = @"_NET_WM_STATE_HIDDEN";
    EWMHWMStateFullscreen = @"_NET_WM_STATE_FULLSCREEN";
    EWMHWMStateAbove = @"_NET_WM_STATE_ABOVE";
    EWMHWMStateBelow = @"_NET_WM_STATE_BELOW";
    EWMHWMStateDemandsAttention = @"_NET_WM_STATE_DEMANDS_ATTENTION";

    // The application window allowed actions (used with EWMH_WMAllowedActions)
    EWMHWMActionMove = @"_NET_WM_ACTION_MOVE";
    EWMHWMActionResize = @"_NET_WM_ACTION_RESIZE";
    EWMHWMActionMinimize = @"_NET_WM_ACTION_MINIMIZE";
    EWMHWMActionShade = @"_NET_WM_ACTION_SHADE";
    EWMHWMActionStick = @"_NET_WM_ACTION_STICK";
    EWMHWMActionMaximizeHorz = @"_NET_WM_ACTION_MAXIMIZE_HORZ";
    EWMHWMActionMaximizeVert = @"_NET_WM_ACTION_MAXIMIZE_VERT";
    EWMHWMActionFullscreen = @"_NET_WM_ACTION_FULLSCREEN";
    EWMHWMActionChangeDesktop = @"_NET_WM_ACTION_CHANGE_DESKTOP";
    EWMHWMActionClose = @"_NET_WM_ACTION_CLOSE";
    EWMHWMActionAbove = @"_NET_WM_ACTION_ABOVE";
    EWMHWMActionBelow = @"_NET_WM_ACTION_BELOW";

    // Window Manager Protocols
    EWMHWMPing = @"_NET_WM_PING";
    EWMHWMSyncRequest = @"_NET_WM_SYNC_REQUEST";
    EWMHWMFullscreenMonitors = @"_NET_WM_FULLSCREEN_MONITORS";

    // Other properties
    EWMHWMFullPlacement = @"_NET_WM_FULL_PLACEMENT";
    UTF8_STRING = @"UTF8_STRING";
    MANAGER = @"MANAGER";
    KdeNetWFrameStrut = @"_KDE_NET_WM_FRAME_STRUT";
    MotifWMHints = @"_MOTIF_WM_HINTS";

    //GNUStep properties

    GNUStepMiniaturizeWindow = @"_GNUSTEP_WM_MINIATURIZE_WINDOW";
    GNUStepHideApp = @"_GNUSTEP_WM_HIDE_APP";
    GNUStepFrameOffset = @"_GNUSTEP_FRAME_OFFSETS";
    GNUStepWmAttr = @"_GNUSTEP_WM_ATTR";
    GNUStepTitleBarState = @"_GNUSTEP_TITLEBAR_STATE";

    // Added EWMH properties

    EWMHStartupId = @"_NET_STARTUP_ID";
    EWMHFrameExtents = @"_NET_FRAME_EXTENTS";
    EWMHStrutPartial = @"_NET_WM_STRUT_PARTIAL";
    EWMHVisibleIconName = @"_NET_WM_VISIBLE_ICON_NAME";

    //Array iitialization
    NSString* atomStrings[] =
    {
        EWMHSupported,
        EWMHClientList,
        EWMHClientListStacking,
        EWMHNumberOfDesktops,
        EWMHDesktopGeometry,
        EWMHDesktopViewport,
        EWMHCurrentDesktop,
        EWMHDesktopNames,
        EWMHActiveWindow,
        EWMHWorkarea,
        EWMHSupportingWMCheck,
        EWMHVirtualRoots,
        EWMHDesktopLayout,
        EWMHShowingDesktop,
        EWMHCloseWindow,
        EWMHMoveresizeWindow,
        EWMHWMMoveresize,
        EWMHRestackWindow,
        //EWMHRequestFrameExtents,
        EWMHWMName,
        EWMHWMVisibleName,
        EWMHWMIconName,
        EWMHWMVisibleIconName,
        EWMHWMDesktop,
        EWMHWMWindowType,
        EWMHWMState,
        EWMHWMAllowedActions,
        EWMHWMStrut,
        EWMHWMStrutPartial,
        EWMHWMIconGeometry,
        EWMHWMIcon,
        EWMHWMPid,
        EWMHWMHandledIcons,
        EWMHWMUserTime,
        EWMHWMUserTimeWindow,
        EWMHWMFrameExtents,
        EWMHWMWindowTypeDesktop,
        EWMHWMWindowTypeDock,
        EWMHWMWindowTypeToolbar,
        EWMHWMWindowTypeMenu,
        EWMHWMWindowTypeUtility,
        EWMHWMWindowTypeSplash,
        EWMHWMWindowTypeDialog,
        EWMHWMWindowTypeDropdownMenu,
        EWMHWMWindowTypePopupMenu,
        EWMHWMWindowTypeTooltip,
        EWMHWMWindowTypeNotification,
        EWMHWMWindowTypeCombo,
        EWMHWMWindowTypeDnd,
        EWMHWMWindowTypeNormal,
        EWMHWMStateModal,
        EWMHWMStateSticky,
        EWMHWMStateMaximizedVert,
        EWMHWMStateMaximizedHorz,
        EWMHWMStateShaded,
        EWMHWMStateSkipTaskbar,
        EWMHWMStateSkipPager,
        EWMHWMStateHidden,
        EWMHWMStateFullscreen,
        EWMHWMStateAbove,
        EWMHWMStateBelow,
        EWMHWMStateDemandsAttention,
        EWMHWMActionMove,
        EWMHWMActionResize,
        EWMHWMActionMinimize,
        EWMHWMActionShade,
        EWMHWMActionStick,
        EWMHWMActionMaximizeHorz,
        EWMHWMActionMaximizeVert,
        EWMHWMActionFullscreen,
        EWMHWMActionChangeDesktop,
        EWMHWMActionClose,
        EWMHWMActionAbove,
        EWMHWMActionBelow,
        EWMHWMPing,
        EWMHWMSyncRequest,
        EWMHWMFullscreenMonitors,
        EWMHWMFullPlacement,
        GNUStepMiniaturizeWindow,
        GNUStepHideApp,
        GNUStepWmAttr,
        GNUStepTitleBarState,
        GNUStepFrameOffset,
        EWMHStartupId,
        EWMHFrameExtents,
        EWMHStrutPartial,
        EWMHVisibleIconName,
        UTF8_STRING,
        MANAGER,
        KdeNetWFrameStrut,
        MotifWMHints
    };

    atoms = [NSArray arrayWithObjects:atomStrings count:sizeof(atomStrings)/sizeof(NSString*)];
    atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    [atomService cacheAtoms:atoms];

    return self;
}

+ (id) sharedInstanceWithConnection:(XCBConnection *)aConnection
{
    static EWMHService *sharedInstance = nil;

    // this is not thread safe, switch to libdispatch some day.
    if (sharedInstance == nil)
    {
        sharedInstance = [[self alloc] initWithConnection:aConnection];
    }

    return sharedInstance;
}

- (void) putPropertiesForRootWindow:(XCBWindow *)rootWindow andWmWindow:(XCBWindow *)wmWindow
{
    NSString *rootProperties[] =
    {
        EWMHSupported,
        EWMHSupportingWMCheck,
        EWMHStartupId,
        EWMHClientList,
        EWMHClientListStacking,
        EWMHNumberOfDesktops,
        EWMHCurrentDesktop,
        EWMHDesktopNames,
        EWMHActiveWindow,
        EWMHCloseWindow,
        EWMHFrameExtents,
        EWMHWMName,
        EWMHStrutPartial,
        EWMHWMIconName,
        EWMHVisibleIconName,
        EWMHWMDesktop,
        EWMHWMWindowType,
        EWMHWMWindowTypeDesktop,
        EWMHWMWindowTypeDock,
        EWMHWMWindowTypeToolbar,
        EWMHWMWindowTypeMenu,
        EWMHWMWindowTypeUtility,
        EWMHWMWindowTypeSplash,
        EWMHWMWindowTypeDialog,
        EWMHWMWindowTypeDropdownMenu,
        EWMHWMWindowTypePopupMenu,
        EWMHWMWindowTypeTooltip,
        EWMHWMWindowTypeNotification,
        EWMHWMWindowTypeCombo,
        EWMHWMWindowTypeDnd,
        EWMHWMWindowTypeNormal,
        EWMHWMIcon,
        EWMHWMPid,
        EWMHWMState,
        EWMHWMStateSticky,
        EWMHWMStateSkipTaskbar,
        EWMHWMStateFullscreen,
        EWMHWMStateMaximizedHorz,
        EWMHWMStateMaximizedVert,
        EWMHWMStateAbove,
        EWMHWMStateBelow,
        EWMHWMStateModal,
        EWMHWMStateHidden,
        EWMHWMStateDemandsAttention,
        //EWMHRequestFrameExtents,
        UTF8_STRING,
        GNUStepFrameOffset,
        GNUStepHideApp,
        GNUStepWmAttr,
        GNUStepMiniaturizeWindow,
        GNUStepTitleBarState,
        KdeNetWFrameStrut
    };

    NSArray *rootAtoms = [NSArray arrayWithObjects:rootProperties count:sizeof(rootProperties)/sizeof(NSString*)];

    xcb_atom_t atomsTransformed[[rootAtoms count]];
    FnFromNSArrayAtomsToXcbAtomTArray(rootAtoms, atomsTransformed, atomService);

    xcb_change_property([connection connection],
                        XCB_PROP_MODE_REPLACE,
                        [rootWindow window],
                        [[[atomService cachedAtoms] objectForKey:EWMHSupported] unsignedIntValue],
                        XCB_ATOM_ATOM,
                        32,
                        (uint32_t)[rootAtoms count],
                        &atomsTransformed);

    xcb_window_t wmXcbWindow = [wmWindow window];

    xcb_change_property([connection connection],
                        XCB_PROP_MODE_REPLACE,
                        [rootWindow window],
                        [[[atomService cachedAtoms] objectForKey:EWMHSupportingWMCheck] unsignedIntValue],
                        XCB_ATOM_WINDOW,
                        32,
                        1,
                        &wmXcbWindow);

    xcb_change_property([connection connection],
                        XCB_PROP_MODE_REPLACE,
                        wmXcbWindow,
                        [[[atomService cachedAtoms] objectForKey:EWMHSupportingWMCheck] unsignedIntValue],
                        XCB_ATOM_WINDOW,
                        32,
                        1,
                        &wmXcbWindow);

    xcb_change_property([connection connection],
                        XCB_PROP_MODE_REPLACE,
                        wmXcbWindow,
                        [[[atomService cachedAtoms] objectForKey:EWMHWMName] unsignedIntValue],
                        [[[atomService cachedAtoms] objectForKey:UTF8_STRING] unsignedIntValue],
                        8,
                        6,
                        "uroswm");


    int pid = getpid();

    xcb_change_property([connection connection],
                        XCB_PROP_MODE_REPLACE,
                        wmXcbWindow,
                        [[[atomService cachedAtoms] objectForKey:EWMHWMPid] unsignedIntValue],
                        XCB_ATOM_CARDINAL,
                        32,
                        1,
                        &pid);

    [self updateNetSupported:[[atomService cachedAtoms] allValues] forRootWindow:rootWindow];

    //TODO: wm-specs says that if the _NET_WM_PID is set the ICCCM WM_CLIENT_MACHINE atom must be set.

    rootAtoms = nil;

}

- (void) changePropertiesForWindow:(XCBWindow *)aWindow
                          withMode:(uint8_t)mode
                      withProperty:(NSString*)propertyKey
                          withType:(xcb_atom_t)type
                        withFormat:(uint8_t)format
                    withDataLength:(uint32_t)dataLength
                          withData:(const void *) data
{
    xcb_atom_t property = [atomService atomFromCachedAtomsWithKey:propertyKey];

    xcb_change_property([connection connection],
                        mode,
                        [aWindow window],
                        property,
                        type,
                        format,
                        dataLength,
                        data);
}


- (void*) getProperty:(NSString *)aPropertyName
         propertyType:(xcb_atom_t)propertyType
            forWindow:(XCBWindow *)aWindow
               delete:(BOOL)deleteProperty
               length:(uint32_t)len
{
    xcb_atom_t property = [atomService atomFromCachedAtomsWithKey:aPropertyName];

    xcb_get_property_cookie_t cookie = xcb_get_property([connection connection],
                                                        deleteProperty,
                                                        [aWindow window],
                                                        property,
                                                        propertyType,
                                                        0,
                                                        len);

    xcb_generic_error_t *error;
    xcb_get_property_reply_t *reply = xcb_get_property_reply([connection connection],
                                                             cookie,
                                                             &error);

    if (error)
    {
        NSLog(@"Error: %d for window: %u", error->error_code, [aWindow window]);
        free(error);
        return NULL;
    }

    if (reply->length == 0 && reply->format == 0 && reply->type == 0)
    {
        // Property not present - this is normal for many windows
        free(error);
        return NULL;
    }

    free(error);
    return reply;
}

- (void) updateNetFrameExtentsForWindow:(XCBWindow *)aWindow
{
    XCBGeometryReply *geometry = [aWindow geometries];
    uint32_t extents[4];
    uint32_t border = [geometry borderWidth];
    NSLog(@"Border: %d", border);


    extents[0] = border;
    extents[1] = border;
    extents[2] = 21;
    extents[3] = border;

    [self changePropertiesForWindow:aWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHWMFrameExtents
                           withType:XCB_ATOM_CARDINAL
                         withFormat:32
                     withDataLength:4
                           withData:extents];

    geometry = nil;
}

- (void) updateNetFrameExtentsForWindow:(XCBWindow*)aWindow andExtents:(uint32_t[]) extents
{
    [self changePropertiesForWindow:aWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHWMFrameExtents
                           withType:XCB_ATOM_CARDINAL
                         withFormat:32
                     withDataLength:4
                           withData:extents];
}

- (void)updateNetWmWindowTypeDockForWindow:(XCBWindow *)aWindow
{
    xcb_atom_t atom = [atomService atomFromCachedAtomsWithKey:EWMHWMWindowTypeDock];
    
    [self changePropertiesForWindow:aWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHWMWindowType
                           withType:XCB_ATOM_ATOM
                         withFormat:32
                     withDataLength:1
                           withData:&atom];
}

- (BOOL) ewmhClientMessage:(NSString *)anAtomMessageName
{
    NSString *net = @"NET";
    BOOL ewmh = NO;

    NSString *sub = [anAtomMessageName componentsSeparatedByString:@"_"][1];

    if ([net isEqualToString:sub])
        ewmh = YES;
    else
        ewmh = NO;

    net = nil;
    sub = nil;

    return ewmh;
}

- (void) handleClientMessage:(NSString*)anAtomMessageName forWindow:(XCBWindow*)aWindow data:(xcb_client_message_data_t)someData
{
    if ([anAtomMessageName isEqualToString:EWMHRequestFrameExtents])
    {
        uint32_t extents[] = {3,3,21,3};
        [self updateNetFrameExtentsForWindow:aWindow andExtents:extents];

        return;
    }

    /*** if it is _NET_ACTIVE_WINDOW, focus the window that updates the property too. ***/

    if ([anAtomMessageName isEqualToString:EWMHActiveWindow])
    {
        BOOL wasMinimized = NO;
        XCBFrame *frame = nil;
        XCBTitleBar *titleBar = nil;
        XCBWindow *clientWindow = aWindow;

        if ([[aWindow parentWindow] isKindOfClass:[XCBFrame class]])
        {
            frame = (XCBFrame *) [aWindow parentWindow];
            titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar];
            clientWindow = [frame childWindowForKey:ClientWindow];
            wasMinimized = [frame isMinimized] || [aWindow isMinimized];
        }
        else
        {
            wasMinimized = [aWindow isMinimized];
        }

        if (wasMinimized)
        {
            if (frame)
            {
                [connection mapWindow:frame];
                [frame setIsMinimized:NO];
                [frame setNormalState];
            }

            if (titleBar)
            {
                [connection mapWindow:titleBar];
                [titleBar drawTitleBarComponents];
            }

            if (clientWindow)
            {
                [connection mapWindow:clientWindow];
                [clientWindow setIsMinimized:NO];
                [clientWindow setNormalState];
            }

            XCBWindow *restoreTarget = frame ? (XCBWindow *)frame : aWindow;
            if (restoreTarget)
            {
                xcb_get_property_reply_t *reply = [self getProperty:EWMHWMIconGeometry
                                                      propertyType:XCB_ATOM_CARDINAL
                                                         forWindow:aWindow
                                                            delete:NO
                                                            length:4];
                XCBRect iconRect = XCBInvalidRect;
                if (reply)
                {
                    int len = xcb_get_property_value_length(reply);
                    if (len >= (int)(sizeof(uint32_t) * 4))
                    {
                        uint32_t *values = (uint32_t *)xcb_get_property_value(reply);
                        XCBPoint pos = XCBMakePoint(values[0], values[1]);
                        XCBSize size = XCBMakeSize((uint16_t)values[2], (uint16_t)values[3]);
                        if (size.width > 0 && size.height > 0)
                        {
                            iconRect = XCBMakeRect(pos, size);
                        }
                    }
                    free(reply);
                }

                if (!FnCheckXCBRectIsValid(iconRect))
                {
                    XCBScreen *screen = [aWindow screen];
                    if (screen)
                    {
                        uint16_t iconSize = 48;
                        double x = ((double)[screen width] - iconSize) * 0.5;
                        double y = (double)[screen height] - iconSize;
                        iconRect = XCBMakeRect(XCBMakePoint(x, y), XCBMakeSize(iconSize, iconSize));
                    }
                }

                Class compositorClass = NSClassFromString(@"URSCompositingManager");
                if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)])
                {
                    id<URSCompositingManaging> compositor = [compositorClass performSelector:@selector(sharedManager)];
                    if (compositor && [compositor respondsToSelector:@selector(compositingActive)] &&
                        [compositor compositingActive])
                    {
                        XCBRect endRect = [restoreTarget windowRect];
                        if ([compositor respondsToSelector:@selector(animateWindowRestore:fromRect:toRect:)])
                        {
                            [compositor animateWindowRestore:[restoreTarget window]
                                                  fromRect:iconRect
                                                    toRect:endRect];
                        }
                    }
                }
            }
        }

        [aWindow focus];

        if ([[aWindow parentWindow] isKindOfClass:[XCBFrame class]])
        {
            frame = (XCBFrame *) [aWindow parentWindow];
            titleBar = (XCBTitleBar *) [frame childWindowForKey:TitleBar];
            [frame stackAbove];
            [titleBar drawTitleBarComponents];
            [connection drawAllTitleBarsExcept:titleBar];
            frame = nil;
            titleBar = nil;
        }

        return;
    }

    if ([anAtomMessageName isEqualToString:EWMHWMState])
    {
        Action action = someData.data32[0];
        xcb_atom_t firstProp = someData.data32[1];
        xcb_atom_t secondProp = someData.data32[2];

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipTaskbar] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipTaskbar])
        {
            BOOL skipTaskBar = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow skipTaskBar]);
            [aWindow setSkipTaskBar:skipTaskBar];
            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipPager] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipPager])
        {
            BOOL skipPager = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow skipTaskBar]);
            [aWindow setSkipPager:skipPager];
            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateAbove] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateAbove])
        {
            BOOL above = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow isAbove]);

            if (above)
                [aWindow stackAbove];

            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateBelow] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateBelow])
        {
            BOOL below = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow isBelow]);

            if (below)
                [aWindow stackBelow];

            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedHorz] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedHorz])
        {
            BOOL maxHorz = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow maximizedHorizontally]);
            XCBScreen *screen = [aWindow screen];
            XCBSize size;
            XCBPoint position;
            XCBFrame *frame;
            XCBTitleBar *titleBar;

            // Read workarea to respect struts
            int32_t workareaX = 0, workareaY = 0;
            uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
            XCBWindow *rootWindow = [screen rootWindow];
            [self readWorkareaForRootWindow:rootWindow x:&workareaX y:&workareaY width:&workareaWidth height:&workareaHeight];

            if (maxHorz)
            {
                if ([aWindow isMinimized])
                    [aWindow restoreFromIconified];

                if ([aWindow decorated])
                {
                    frame = (XCBFrame*)[aWindow parentWindow];
                    titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];

                    // Save pre-maximize rect for restore
                    [frame setOldRect:[frame windowRect]];

                    // Respect client resizability: do nothing if the client is non-resizable
                    XCBWindow *clientWin = (XCBWindow*)[frame childWindowForKey:ClientWindow];
                    if (clientWin && ![clientWin canResize]) {
                        NSLog(@"[EWMH] Skipping horizontal maximize for non-resizable client %u", [clientWin window]);
                    } else {
                        /*** Use programmaticResizeToRect - keeps width, expands to workarea width ***/
                        XCBRect targetRect = XCBMakeRect(
                            XCBMakePoint(workareaX, [frame windowRect].position.y),
                            XCBMakeSize(workareaWidth, [frame windowRect].size.height));
                        [frame programmaticResizeToRect:targetRect];

                        // Update resize zones and shape mask
                        [frame updateAllResizeZonePositions];
                        [frame applyRoundedCornersShapeMask];

                        [titleBar drawTitleBarComponents];
                    }

                    frame = nil;
                    titleBar = nil;
                }
                else
                {
                    if (![aWindow canResize]) {
                        NSLog(@"[EWMH] Skipping horizontal maximize for non-resizable undecorated client %u", [aWindow window]);
                    } else {
                        size = XCBMakeSize(workareaWidth, [aWindow windowRect].size.height);
                        position = XCBMakePoint(workareaX, [aWindow windowRect].position.y);
                        [aWindow maximizeToSize:size andPosition:position];
                    }
                }

                [aWindow setMaximizedHorizontally:maxHorz];
                screen = nil;
            }

            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedVert] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedVert])
        {
            BOOL maxVert = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow maximizedVertically]);
            XCBScreen *screen = [aWindow screen];
            XCBSize size;
            XCBPoint position;
            XCBFrame *frame;
            XCBTitleBar *titleBar;

            // Read workarea to respect struts
            int32_t workareaX = 0, workareaY = 0;
            uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
            XCBWindow *rootWindow = [screen rootWindow];
            [self readWorkareaForRootWindow:rootWindow x:&workareaX y:&workareaY width:&workareaWidth height:&workareaHeight];

            if (maxVert)
            {
                if ([aWindow isMinimized])
                    [aWindow restoreFromIconified];

                if ([aWindow decorated])
                {
                    frame = (XCBFrame*)[aWindow parentWindow];
                    titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];

                    // Save pre-maximize rect for restore
                    [frame setOldRect:[frame windowRect]];

                    // Respect client resizability: do nothing if the client is non-resizable
                    XCBWindow *clientWin = (XCBWindow*)[frame childWindowForKey:ClientWindow];
                    if (clientWin && ![clientWin canResize]) {
                        NSLog(@"[EWMH] Skipping vertical maximize for non-resizable client %u", [clientWin window]);
                    } else {
                        /*** Use programmaticResizeToRect - keeps width, expands to workarea height ***/
                        XCBRect targetRect = XCBMakeRect(
                            XCBMakePoint([frame windowRect].position.x, workareaY),
                            XCBMakeSize([frame windowRect].size.width, workareaHeight));
                        [frame programmaticResizeToRect:targetRect];

                        // Update resize zones and shape mask
                        [frame updateAllResizeZonePositions];
                        [frame applyRoundedCornersShapeMask];

                        [titleBar drawTitleBarComponents];
                    }

                    frame = nil;
                    titleBar = nil;
                }
                else
                {
                    if (![aWindow canResize]) {
                        NSLog(@"[EWMH] Skipping vertical maximize for non-resizable undecorated client %u", [aWindow window]);
                    } else {
                        size = XCBMakeSize([aWindow windowRect].size.width, workareaHeight);
                        position = XCBMakePoint([aWindow windowRect].position.x, workareaY);
                        [aWindow maximizeToSize:size andPosition:position];
                    }
                }

                [aWindow setMaximizedVertically:maxVert];
                screen = nil;
            }

            [self updateNetWmState:aWindow];
        }

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateFullscreen] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateFullscreen])
        {
            BOOL fullscr = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow isMaximized]);
            XCBScreen *screen = [aWindow screen];
            XCBFrame *frame;
            XCBTitleBar *titleBar;
            XCBSize size;
            XCBPoint position;

            // Read workarea to respect struts (fullscreen should also respect workarea)
            int32_t workareaX = 0, workareaY = 0;
            uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
            XCBWindow *rootWindow = [screen rootWindow];
            [self readWorkareaForRootWindow:rootWindow x:&workareaX y:&workareaY width:&workareaWidth height:&workareaHeight];

            if (fullscr)
            {
                if ([aWindow isMinimized])
                    [aWindow restoreFromIconified];

                if ([aWindow decorated])
                {
                    frame = (XCBFrame*)[aWindow parentWindow];
                    titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];

                    // Save pre-maximize rect for restore
                    [frame setOldRect:[frame windowRect]];

                    // Respect client resizability: do nothing if the client is non-resizable
                    XCBWindow *clientWin = (XCBWindow*)[frame childWindowForKey:ClientWindow];
                    if (clientWin && ![clientWin canResize]) {
                        NSLog(@"[EWMH] Skipping fullscreen/maximize for non-resizable client %u", [clientWin window]);
                    } else {
                        /*** Use programmaticResizeToRect - fullscreen to workarea ***/
                        XCBRect targetRect = XCBMakeRect(
                            XCBMakePoint(workareaX, workareaY),
                            XCBMakeSize(workareaWidth, workareaHeight));
                        [frame programmaticResizeToRect:targetRect];
                        [frame setIsMaximized:YES];
                        [frame setMaximizedHorizontally:YES];
                        [frame setMaximizedVertically:YES];

                        // Update resize zones and shape mask
                        [frame updateAllResizeZonePositions];
                        [frame applyRoundedCornersShapeMask];

                        [titleBar drawTitleBarComponents];
                    }

                    frame = nil;
                    titleBar = nil;
                }
                else
                {
                    if (![aWindow canResize]) {
                        NSLog(@"[EWMH] Skipping fullscreen for non-resizable undecorated client %u", [aWindow window]);
                    } else {
                        size = XCBMakeSize(workareaWidth, workareaHeight);
                        position = XCBMakePoint(workareaX, workareaY);
                        [aWindow maximizeToSize:size andPosition:position];
                    }
                }

                [aWindow setFullScreen:fullscr];
                screen = nil;
            }

            [self updateNetWmState:aWindow];
        }

        /*** TODO: test and complete it, but shading support has really low priority ***/

        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateShaded] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateShaded])
        {
            BOOL shaded = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow shaded]);

            if (shaded)
            {
                if ([aWindow isMinimized])
                    return;

                [aWindow shade];
                [aWindow setShaded:shaded];
            }

            [self updateNetWmState:aWindow];
        }

        /*** TODO: test ***/
        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateHidden] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateHidden])
        {
            BOOL minimize = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow isMinimized]);

            if (minimize)
            {
                [aWindow minimize];
                [aWindow setIsMinimized:minimize];
            }

            [self updateNetWmState:aWindow];
        }

        /*** TODO: test it. for now just focus the window and set it active ***/
        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateDemandsAttention] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateDemandsAttention])
        {
            BOOL attention = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow gotAttention]);

            if (attention)
            {
                [aWindow focus];
                [aWindow setGotAttention:attention];
            }

            [self updateNetWmState:aWindow];
        }

/* 
 * This caused the Desktop window to have the "Above" atom set, which is not desired.
        if (firstProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSticky] ||
            secondProp == [atomService atomFromCachedAtomsWithKey:EWMHWMStateSticky])
        {
            BOOL always = (action == _NET_WM_STATE_ADD) || (action == _NET_WM_STATE_TOGGLE && ![aWindow alwaysOnTop]);

            if (always)
            {
                [aWindow stackAbove];
                [aWindow setAlwaysOnTop:always];
            }

            [self updateNetWmState:aWindow];
        }
*/
    }

}

- (void) updateNetWmState:(XCBWindow*)aWindow
{
    int i = 0;
    xcb_atom_t props[12];

    if ([aWindow skipTaskBar])
    {
        NSLog(@"Skip taskbar for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipTaskbar];
    }

    if ([aWindow skipPager])
    {
        NSLog(@"Skip Pager for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateSkipPager];
    }

    if ([aWindow isAbove])
    {
        NSLog(@"Above for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateAbove];
    }

    if ([aWindow isBelow])
    {
        NSLog(@"Below for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateBelow];
    }

    if ([aWindow maximizedHorizontally])
    {
        NSLog(@"Maximize horizotally for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedHorz];
    }

    if ([aWindow maximizedVertically])
    {
        NSLog(@"Maximize vertically for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateMaximizedVert];
    }

    if ([aWindow shaded])
    {
        NSLog(@"Shaded for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateShaded];
    }

    if ([aWindow isMinimized])
    {
        NSLog(@"Hidden for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateHidden];
    }

    if ([aWindow fullScreen])
    {
        NSLog(@"Full screen for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateFullscreen];
    }

    if ([aWindow gotAttention])
    {
        NSLog(@"Demands attention for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateDemandsAttention];
    }

    if ([aWindow alwaysOnTop])
    {
        NSLog(@"Sticky for window %u", [aWindow window]);
        props[i++] = [atomService atomFromCachedAtomsWithKey:EWMHWMStateSticky];
    }

    [self changePropertiesForWindow:aWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHWMState
                           withType:XCB_ATOM_ATOM
                         withFormat:32
                     withDataLength:i
                           withData:props];
}

- (uint32_t)netWMPidForWindow:(XCBWindow *)aWindow
{
    void *reply = [self getProperty:EWMHWMPid propertyType:XCB_ATOM_CARDINAL
                          forWindow:aWindow
                             delete:NO
                             length:1];
    
    if (!reply)
        return -1;
    
    uint32_t *net = xcb_get_property_value(reply);
    
    uint32_t pid = *net;
    
    free(reply);
    net = NULL;
    
    return pid;
    
}


- (xcb_get_property_reply_t*) netWmIconFromWindow:(XCBWindow*)aWindow
{
    xcb_get_property_cookie_t cookie = xcb_get_property_unchecked([connection connection],
                                                                  false,
                                                                  [aWindow window],
                                                                  [atomService atomFromCachedAtomsWithKey:EWMHWMIcon],
                                                                  XCB_ATOM_CARDINAL,
                                                                  0,
                                                                  UINT32_MAX);

    xcb_get_property_reply_t *reply = xcb_get_property_reply([connection connection], cookie, NULL);
    return reply;
}

- (void) updateNetClientList
{
    uint32_t size = [connection clientListIndex];

    //TODO: with more screens this need to be looped ?
    XCBWindow *rootWindow = [connection rootWindowForScreenNumber:0];

    [self changePropertiesForWindow:rootWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHClientList
                           withType:XCB_ATOM_WINDOW
                         withFormat:32
                     withDataLength:size
                           withData:[connection clientList]];

    // _NET_CLIENT_LIST_STACKING must reflect actual stacking order (bottom-to-top)
    if (size > 0) {
        xcb_connection_t *conn = [connection connection];
        xcb_query_tree_cookie_t tree_cookie = xcb_query_tree(conn, [rootWindow window]);
        xcb_query_tree_reply_t *tree_reply = xcb_query_tree_reply(conn, tree_cookie, NULL);

        xcb_window_t stackingList[size];
        uint32_t stackingCount = 0;

        if (tree_reply) {
            xcb_window_t *children = xcb_query_tree_children(tree_reply);
            int num_children = xcb_query_tree_children_length(tree_reply);

            NSMutableSet *clientSet = [NSMutableSet setWithCapacity:size];
            for (uint32_t i = 0; i < size; i++) {
                [clientSet addObject:@([connection clientList][i])];
            }

            for (int i = 0; i < num_children; i++) {
                NSNumber *childNumber = @(children[i]);
                if ([clientSet containsObject:childNumber]) {
                    stackingList[stackingCount++] = children[i];
                }
            }

            // Append any clients not present in the query tree (e.g., unmapped)
            if (stackingCount < size) {
                NSMutableSet *addedSet = [NSMutableSet setWithCapacity:stackingCount];
                for (uint32_t i = 0; i < stackingCount; i++) {
                    [addedSet addObject:@(stackingList[i])];
                }
                for (uint32_t i = 0; i < size; i++) {
                    NSNumber *clientNumber = @([connection clientList][i]);
                    if (![addedSet containsObject:clientNumber]) {
                        stackingList[stackingCount++] = [clientNumber unsignedIntValue];
                    }
                }
            }

            free(tree_reply);
        } else {
            // Fallback to client registration order if stacking can't be queried
            for (uint32_t i = 0; i < size; i++) {
                stackingList[stackingCount++] = [connection clientList][i];
            }
        }

        [self changePropertiesForWindow:rootWindow
                               withMode:XCB_PROP_MODE_REPLACE
                           withProperty:EWMHClientListStacking
                               withType:XCB_ATOM_WINDOW
                             withFormat:32
                         withDataLength:stackingCount
                               withData:stackingList];
    } else {
        [self changePropertiesForWindow:rootWindow
                               withMode:XCB_PROP_MODE_REPLACE
                           withProperty:EWMHClientListStacking
                               withType:XCB_ATOM_WINDOW
                             withFormat:32
                         withDataLength:0
                               withData:NULL];
    }

    rootWindow = nil;
}

- (void) updateNetActiveWindow:(XCBWindow*)aWindow
{
    XCBWindow *rootWindow = [[aWindow onScreen] rootWindow];
    xcb_window_t win = [aWindow window];

    [self changePropertiesForWindow:rootWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHActiveWindow
                           withType:XCB_ATOM_WINDOW
                         withFormat:32
                     withDataLength:1
                           withData:&win];

    NSLog(@"Active window updated %u", win);
    rootWindow = nil;
}

- (void) updateNetSupported:(NSArray*)atomsArray forRootWindow:(XCBWindow*)aRootWindow
{
    NSUInteger size = [atomsArray count];
    xcb_atom_t atomList[size];

    for (int i = 0; i < size; ++i)
        atomList[i] = [[atomsArray objectAtIndex:i] unsignedIntValue];

    [self changePropertiesForWindow:aRootWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHSupported
                           withType:XCB_ATOM_ATOM
                         withFormat:32 withDataLength:size
                           withData:atomList];
}

#pragma mark - ICCCM/EWMH Strut and Workarea Support

- (BOOL) readStrutForWindow:(XCBWindow*)aWindow strut:(uint32_t[4])outStrut
{
    if (!aWindow) {
        return NO;
    }
    
    // Read _NET_WM_STRUT property (4 cardinals: left, right, top, bottom)
    void *reply = [self getProperty:EWMHWMStrut
                       propertyType:XCB_ATOM_CARDINAL
                          forWindow:aWindow
                             delete:NO
                             length:4];
    
    if (!reply) {
        return NO;
    }
    
    xcb_get_property_reply_t *propReply = (xcb_get_property_reply_t *)reply;
    
    if (propReply->type == XCB_ATOM_NONE || propReply->length < 4) {
        free(reply);
        return NO;
    }
    
    uint32_t *values = (uint32_t *)xcb_get_property_value(propReply);
    outStrut[0] = values[0]; // left
    outStrut[1] = values[1]; // right
    outStrut[2] = values[2]; // top
    outStrut[3] = values[3]; // bottom
    
    free(reply);
    return YES;
}

- (BOOL) readStrutPartialForWindow:(XCBWindow*)aWindow strut:(uint32_t[12])outStrut
{
    if (!aWindow) {
        return NO;
    }
    
    // Read _NET_WM_STRUT_PARTIAL property (12 cardinals)
    // left, right, top, bottom, 
    // left_start_y, left_end_y, right_start_y, right_end_y,
    // top_start_x, top_end_x, bottom_start_x, bottom_end_x
    void *reply = [self getProperty:EWMHWMStrutPartial
                       propertyType:XCB_ATOM_CARDINAL
                          forWindow:aWindow
                             delete:NO
                             length:12];
    
    if (!reply) {
        return NO;
    }
    
    xcb_get_property_reply_t *propReply = (xcb_get_property_reply_t *)reply;
    
    if (propReply->type == XCB_ATOM_NONE || propReply->length < 12) {
        free(reply);
        return NO;
    }
    
    uint32_t *values = (uint32_t *)xcb_get_property_value(propReply);
    for (int i = 0; i < 12; i++) {
        outStrut[i] = values[i];
    }
    
    free(reply);
    return YES;
}

- (void) updateWorkareaForRootWindow:(XCBWindow*)rootWindow 
                                   x:(int32_t)x 
                                   y:(int32_t)y 
                               width:(uint32_t)width 
                              height:(uint32_t)height
{
    if (!rootWindow) {
        NSLog(@"[EWMH] Cannot update workarea: no root window");
        return;
    }
    
    // _NET_WORKAREA is an array of 4 CARDINALs per desktop: x, y, width, height
    // For now we support a single desktop
    uint32_t workarea[4] = { (uint32_t)x, (uint32_t)y, width, height };
    
    NSLog(@"[EWMH] Setting _NET_WORKAREA: x=%d, y=%d, width=%u, height=%u", x, y, width, height);
    
    [self changePropertiesForWindow:rootWindow
                           withMode:XCB_PROP_MODE_REPLACE
                       withProperty:EWMHWorkarea
                           withType:XCB_ATOM_CARDINAL
                         withFormat:32
                     withDataLength:4
                           withData:workarea];
}

- (BOOL) isWindowTypeDock:(XCBWindow*)aWindow
{
    if (!aWindow) {
        return NO;
    }
    
    void *reply = [self getProperty:EWMHWMWindowType
                       propertyType:XCB_ATOM_ATOM
                          forWindow:aWindow
                             delete:NO
                             length:UINT32_MAX];
    
    if (!reply) {
        return NO;
    }
    
    xcb_get_property_reply_t *propReply = (xcb_get_property_reply_t *)reply;
    
    if (propReply->type == XCB_ATOM_NONE || propReply->length == 0) {
        free(reply);
        return NO;
    }
    
    xcb_atom_t *typeAtoms = (xcb_atom_t *)xcb_get_property_value(propReply);
    xcb_atom_t dockAtom = [atomService atomFromCachedAtomsWithKey:EWMHWMWindowTypeDock];
    
    BOOL isDock = NO;
    for (uint32_t i = 0; i < propReply->length; i++) {
        if (typeAtoms[i] == dockAtom) {
            isDock = YES;
            break;
        }
    }
    
    free(reply);
    return isDock;
}

- (BOOL) readWorkareaForRootWindow:(XCBWindow*)rootWindow x:(int32_t*)outX y:(int32_t*)outY width:(uint32_t*)outWidth height:(uint32_t*)outHeight
{
    if (!rootWindow) {
        return NO;
    }
    
    // Read _NET_WORKAREA property (4 cardinals per desktop: x, y, width, height)
    void *reply = [self getProperty:EWMHWorkarea
                       propertyType:XCB_ATOM_CARDINAL
                          forWindow:rootWindow
                             delete:NO
                             length:4];
    
    if (!reply) {
        return NO;
    }
    
    xcb_get_property_reply_t *propReply = (xcb_get_property_reply_t *)reply;
    
    if (propReply->type == XCB_ATOM_NONE || propReply->length < 4) {
        free(reply);
        return NO;
    }
    
    uint32_t *values = (uint32_t *)xcb_get_property_value(propReply);
    if (outX) *outX = (int32_t)values[0];
    if (outY) *outY = (int32_t)values[1];
    if (outWidth) *outWidth = values[2];
    if (outHeight) *outHeight = values[3];
    
    NSLog(@"[EWMH] Read _NET_WORKAREA: x=%d, y=%d, width=%u, height=%u", 
          values[0], values[1], values[2], values[3]);
    
    free(reply);
    return YES;
}


-(void)dealloc
{
    EWMHSupported = nil;
    EWMHClientList = nil;
    EWMHClientListStacking = nil;
    EWMHNumberOfDesktops = nil;
    EWMHDesktopGeometry = nil;
    EWMHDesktopViewport = nil;
    EWMHCurrentDesktop = nil;
    EWMHDesktopNames = nil;
    EWMHActiveWindow = nil;
    EWMHWorkarea = nil;
    EWMHSupportingWMCheck = nil;
    EWMHVirtualRoots = nil;
    EWMHDesktopLayout = nil;
    EWMHShowingDesktop = nil;

    // Root Window Messages
    EWMHCloseWindow = nil;
    EWMHMoveresizeWindow = nil;
    EWMHWMMoveresize = nil;
    EWMHRestackWindow = nil;
    EWMHRequestFrameExtents = nil;

    // Application window properties
    EWMHWMName = nil;
    EWMHWMVisibleName = nil;
    EWMHWMIconName = nil;
    EWMHWMVisibleIconName = nil;
    EWMHWMDesktop = nil;
    EWMHWMWindowType = nil;
    EWMHWMState = nil;
    EWMHWMAllowedActions = nil;
    EWMHWMStrut = nil;
    EWMHWMStrutPartial = nil;
    EWMHWMIconGeometry = nil;
    EWMHWMIcon = nil;
    EWMHWMPid = nil;
    EWMHWMHandledIcons = nil;
    EWMHWMUserTime = nil;
    EWMHWMUserTimeWindow = nil;
    EWMHWMFrameExtents = nil;

    // The window types (used with EWMH_WMWindowType)
    EWMHWMWindowTypeDesktop = nil;
    EWMHWMWindowTypeDock = nil;
    EWMHWMWindowTypeToolbar = nil;
    EWMHWMWindowTypeMenu = nil;
    EWMHWMWindowTypeUtility = nil;
    EWMHWMWindowTypeSplash = nil;
    EWMHWMWindowTypeDialog = nil;
    EWMHWMWindowTypeDropdownMenu = nil;
    EWMHWMWindowTypePopupMenu = nil;

    EWMHWMWindowTypeTooltip = nil;
    EWMHWMWindowTypeNotification = nil;
    EWMHWMWindowTypeCombo = nil;
    EWMHWMWindowTypeDnd = nil;

    EWMHWMWindowTypeNormal = nil;

    // The application window states (used with EWMH_WMWindowState)
    EWMHWMStateModal = nil;
    EWMHWMStateSticky = nil;
    EWMHWMStateMaximizedVert = nil;
    EWMHWMStateMaximizedHorz = nil;
    EWMHWMStateShaded = nil;
    EWMHWMStateSkipTaskbar = nil;
    EWMHWMStateSkipPager = nil;
    EWMHWMStateHidden = nil;
    EWMHWMStateFullscreen = nil;
    EWMHWMStateAbove = nil;
    EWMHWMStateBelow = nil;
    EWMHWMStateDemandsAttention = nil;

    // The application window allowed actions (used with EWMH_WMAllowedActions)
    EWMHWMActionMove = nil;
    EWMHWMActionResize = nil;
    EWMHWMActionMinimize = nil;
    EWMHWMActionShade = nil;
    EWMHWMActionStick = nil;
    EWMHWMActionMaximizeHorz = nil;
    EWMHWMActionMaximizeVert = nil;
    EWMHWMActionFullscreen = nil;
    EWMHWMActionChangeDesktop = nil;
    EWMHWMActionClose = nil;
    EWMHWMActionAbove = nil;
    EWMHWMActionBelow = nil;

    // Window Manager Protocols
    EWMHWMPing = nil;
    EWMHWMSyncRequest = nil;
    EWMHWMFullscreenMonitors = nil;

    // Other properties
    EWMHWMFullPlacement = nil;
    UTF8_STRING = nil;
    MANAGER = nil;
    KdeNetWFrameStrut = nil;
    MotifWMHints = nil;

    //GNUStep properties

    GNUStepMiniaturizeWindow = nil;
    GNUStepHideApp = nil;
    GNUStepFrameOffset = nil;
    GNUStepWmAttr = nil;
    GNUStepTitleBarState = nil;

    // added properties

    EWMHStartupId = nil;
    EWMHFrameExtents = nil;
    EWMHStrutPartial = nil;
    EWMHVisibleIconName = nil;

    atoms = nil;
    connection = nil;
    atomService = nil;
}

@end
