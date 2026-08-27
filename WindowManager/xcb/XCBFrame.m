//
//  XCBFrame.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 05/08/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBFrame.h"
#import "Transformers.h"
#import "ICCCMService.h"
#import "TitleBarSettingsService.h"
#import "EWMHService.h"
#import "XCBTypes.h"

// Loose typing for the compositor, mirroring the NSClassFromString lookup
// the xcb layer uses everywhere; keeps URSCompositingManager.h out of here.
// Call sites are guarded by respondsToSelector.
@protocol URSCompositorShadeAPI <NSObject>
- (void)invalidateWindowPixmap:(xcb_window_t)windowId;
- (void)performRepairNow;
- (void)setWindowOpacity:(CGFloat)opacity forWindow:(xcb_window_t)windowId;
@end


#import <AppKit/NSScroller.h>
#import <GNUstepGUI/GSTheme.h>

// Protocol for compositor manager to check if compositing is active
@protocol URSCompositingManaging <NSObject>
+ (instancetype)sharedManager;
- (BOOL)compositingActive;
@end

// Informal protocol for theme-driven resize zones
// Themes implementing these methods enable the resize zone protocol
@interface NSObject (GSThemeResizeZones)
- (CGFloat)resizeZoneCornerSize;
- (CGFloat)resizeZoneEdgeThickness;
- (BOOL)resizeZoneEnabled:(NSInteger)direction;
- (BOOL)themeRendersResizeVisual;
// Grow box zone (optional overlay in bottom-right)
- (BOOL)resizeZoneHasGrowBox;
- (CGFloat)resizeZoneGrowBoxSize;
// Titlebar corner radius for rounded top corners (0 = square corners)
- (CGFloat)titlebarCornerRadius;
// Window bottom corner radius for rounded bottom corners (0 = square corners)
- (CGFloat)windowBottomCornerRadius;
@end

// Helper function to send synthetic ConfigureNotify to client during resize
// Per ICCCM 4.1.5, reparented windows need synthetic ConfigureNotify events.
// The x/y coordinates in ConfigureNotify are relative to the window's parent,
// so child windows must receive parent-relative positions, not root coordinates.
static void sendSyntheticConfigureNotify(xcb_connection_t *conn,
                                          XCBWindow *clientWindow,
                                          int16_t relX,
                                          int16_t relY,
                                          uint16_t width,
                                          uint16_t height)
{
    xcb_configure_notify_event_t event;
    memset(&event, 0, sizeof(event));
    event.response_type = XCB_CONFIGURE_NOTIFY;
    event.event = [clientWindow window];
    event.window = [clientWindow window];
    event.x = relX;
    event.y = relY;
    event.width = width;
    event.height = height;
    event.border_width = 0;
    event.above_sibling = XCB_NONE;
    event.override_redirect = 0;

    xcb_send_event(conn, 0, [clientWindow window],
                   XCB_EVENT_MASK_STRUCTURE_NOTIFY, (const char *)&event);
}

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

@implementation XCBFrame

@synthesize minWidthHint;
@synthesize minHeightHint;
@synthesize connection;
@synthesize rightBorderClicked;
@synthesize bottomBorderClicked;
@synthesize offset;
@synthesize leftBorderClicked;
@synthesize topBorderClicked;
@synthesize titleHeight;

- (id) initWithClientWindow:(XCBWindow *)aClientWindow withConnection:(XCBConnection *)aConnection
{
    return [self initWithClientWindow:aClientWindow
                       withConnection:aConnection
                        withXcbWindow:0
                             withRect:XCBInvalidRect];
}

- (id) initWithClientWindow:(XCBWindow *)aClientWindow
             withConnection:(XCBConnection *)aConnection
              withXcbWindow:(xcb_window_t)xcbWindow
                   withRect:(XCBRect)aRect
{
    self = [super initWithXCBWindow: xcbWindow andConnection:aConnection];
    [self setWindowRect:aRect];
    [self setOriginalRect:aRect];
    // Hover-peek is armed from creation; it is temporarily disarmed while a
    // peek collapses so the window doesn't immediately re-peek.
    self.hoverPeekArmed = YES;
    /*** checks normal hints for client window **/
    [connection setIsWindowsMapUpdated:NO];
    
    ICCCMService* icccmService = [ICCCMService sharedInstanceWithConnection:connection];
    xcb_size_hints_t *sizeHints = [icccmService wmNormalHintsForWindow:aClientWindow];

    [self setMinHeightHint:sizeHints->min_height];
    [self setMinWidthHint:sizeHints->min_width];

    // Enforce an absolute minimum client area so windows can never collapse
    // to just the titlebar height. Clients that don't set WM_NORMAL_HINTS
    // get minHeightHint=0 which previously caused uint32_t underflows
    // in the resize functions and allowed 0-height client areas.
    if (minHeightHint < WM_MIN_CLIENT_HEIGHT)
        minHeightHint = WM_MIN_CLIENT_HEIGHT;
    if (minWidthHint < WM_MIN_CLIENT_WIDTH)
        minWidthHint = WM_MIN_CLIENT_WIDTH;

    // Respect ICCCM WM_NORMAL_HINTS: if min == max for both dimensions, treat as non-resizable
    if ((sizeHints->flags & XCB_ICCCM_SIZE_HINT_P_MIN_SIZE) &&
        (sizeHints->flags & XCB_ICCCM_SIZE_HINT_P_MAX_SIZE) &&
        sizeHints->min_width == sizeHints->max_width &&
        sizeHints->min_height == sizeHints->max_height)
    {
        //NSLog(@"[XCBFrame] Detected fixed-size (non-resizable) client window %u (min==max)", [aClientWindow window]);
        // Disable resizing for the client window so WM won't offer resize handles etc.
        [aClientWindow setCanResize:NO];
    }

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    titleHeight = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // Determine client border: 0 in compositor mode (drop shadow handles visual separation),
    // 1 (scaled by GSScaleFactor) in non-compositor mode (thin strip of frame background as border).
    // Stored on self for use in resize functions and queried again in decorateClientWindow.
    {
        Class compositorClass = NSClassFromString(@"URSCompositingManager");
        CGFloat sf = [[TitleBarSettingsService sharedInstance] scaleFactor];
        int cb = (int)sf;
        if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
            id manager = [compositorClass sharedManager];
            if ([manager respondsToSelector:@selector(compositingActive)])
                cb = [manager compositingActive] ? 0 : (int)sf;
        }
        self.clientBorder = cb;
    }

    if (minWidthHint > [aClientWindow windowRect].size.width)
    {
        XCBRect rect = XCBMakeRect(XCBMakePoint(0,0), XCBMakeSize(minWidthHint, [aClientWindow windowRect].size.height));
        [aClientWindow setWindowRect:rect];
        [aClientWindow setOriginalRect:rect];
        rect.size.width = rect.size.width + 2 * self.clientBorder;
        [self setWindowRect: rect];
        [self setOriginalRect:rect];
        uint32_t values[] = {rect.size.width};
        xcb_configure_window([aConnection connection], window, XCB_CONFIG_WINDOW_WIDTH, values);
        values[0] = minWidthHint;
        xcb_configure_window([aConnection connection], [aClientWindow window], XCB_CONFIG_WINDOW_WIDTH, values);
    }

    if (minHeightHint > [aClientWindow windowRect].size.height)
    {
        XCBRect rect = XCBMakeRect(XCBMakePoint(0,0), XCBMakeSize([aClientWindow windowRect].size.width, minHeightHint));
        [aClientWindow setWindowRect:rect];
        [aClientWindow setOriginalRect:rect];
        rect.size.height = rect.size.height + titleHeight + self.clientBorder;
        [self setWindowRect:rect];
        [self setOriginalRect:rect];
        uint32_t values[] = {rect.size.height};
        xcb_configure_window([aConnection connection], window, XCB_CONFIG_WINDOW_HEIGHT, values);
        values[0] = minHeightHint;
        xcb_configure_window([aConnection connection], [aClientWindow window], XCB_CONFIG_WINDOW_HEIGHT, values);
    }

    connection = aConnection;
    children = [[NSMutableDictionary alloc] init];
    NSNumber *key = [NSNumber numberWithInteger:ClientWindow];
    [children setObject:aClientWindow forKey: key];
    [connection registerWindow:self];

    [super setIsAbove:YES];
    free(sizeHints);
    icccmService = nil;
    key= nil;
    settings = nil;

    return self;
}

- (void) addChildWindow:(XCBWindow *)aChild withKey:(childrenMask) keyMask
{
    NSNumber* key = [NSNumber numberWithInteger:keyMask];
    [children setObject:aChild forKey: key];
    key = nil;
}

- (XCBWindow*) childWindowForKey:(childrenMask)key
{
    NSNumber* keyNumber = [NSNumber numberWithInteger:key];
    XCBWindow* child = [children objectForKey:keyNumber];
    keyNumber = nil;
    return child;
}

-(void)removeChild:(childrenMask)frameChild
{
    NSNumber* key = [NSNumber numberWithInteger:frameChild];
    [children removeObjectForKey:key];
    key = nil;
}

- (void) decorateClientWindow
{
    NSNumber* key = [NSNumber numberWithInteger:ClientWindow];
    XCBWindow *clientWindow = [children objectForKey:key];
    key = nil;

    XCBScreen *scr = [parentWindow screen];
    XCBVisual *rootVisual = [[XCBVisual alloc] initWithVisualId:[scr screen]->root_visual];
    [rootVisual setVisualTypeForScreen:scr];

    // Check if compositor is active for ARGB alpha transparency support
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    BOOL compositorActive = NO;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
        id manager = [compositorClass sharedManager];
        if ([manager respondsToSelector:@selector(compositingActive)]) {
            compositorActive = [manager compositingActive];
        }
    }

    // Update clientBorder now that we have definitive compositor state.
    // 0 = compositor mode (client flush with frame; drop shadow separates visually)
    // scaled (1 * scaleFactor) = non-compositor mode (border on left, right, bottom)
    {
        CGFloat sf = [[TitleBarSettingsService sharedInstance] scaleFactor];
        self.clientBorder = compositorActive ? 0 : (int)sf;
    }

    uint32_t values[4];  // May need up to 4 values for ARGB (back_pixel, colormap, border_pixel, event_mask)
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint8_t depth = XCB_COPY_FROM_PARENT;
    XCBVisual *titlebarVisual = rootVisual;
    xcb_colormap_t argbColormap = XCB_NONE;

    values[0] = [scr screen]->white_pixel;
    values[1] = TITLE_MASK_VALUES;

    // If compositor is active, try to use 32-bit ARGB visual for alpha transparency
    if (compositorActive) {
        xcb_visualtype_t *argbVisualType = NULL;
        xcb_visualid_t argbVisualId = findARGBVisual([scr screen], &argbVisualType);

        if (argbVisualId != 0 && argbVisualType != NULL) {
            //NSLog(@"[XCBFrame] Creating titlebar with 32-bit ARGB visual (0x%x) for compositor alpha", argbVisualId);

            // Create colormap for ARGB visual (required for 32-bit windows)
            argbColormap = xcb_generate_id([connection connection]);
            xcb_create_colormap([connection connection],
                               XCB_COLORMAP_ALLOC_NONE,
                               argbColormap,
                               [scr screen]->root,
                               argbVisualId);

            // Set up ARGB visual
            titlebarVisual = [[XCBVisual alloc] initWithVisualId:argbVisualId];
            [titlebarVisual setVisualType:argbVisualType];
            depth = 32;

            // For 32-bit windows: back_pixel, border_pixel, event_mask, colormap
            // XCB_CW values must be in ascending bit order: 2, 8, 2048, 8192
            mask = XCB_CW_BACK_PIXEL | XCB_CW_BORDER_PIXEL | XCB_CW_EVENT_MASK | XCB_CW_COLORMAP;
            values[0] = 0;  // back_pixel = transparent black
            values[1] = 0;  // border_pixel = transparent
            values[2] = TITLE_MASK_VALUES;  // event_mask
            values[3] = argbColormap;  // colormap
        }
    }

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];

    uint16_t height = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    XCBCreateWindowTypeRequest* request = [[XCBCreateWindowTypeRequest alloc] initForWindowType:XCBTitleBarRequest];
    [request setDepth:depth];
    [request setParentWindow:self];
    [request setXPosition:0];
    [request setYPosition:0];
    [request setWidth:[self windowRect].size.width];
    [request setHeight:height];
    [request setBorderWidth:0];
    [request setXcbClass:XCB_WINDOW_CLASS_INPUT_OUTPUT];
    [request setVisual:titlebarVisual];
    [request setValueMask:mask];
    [request setValueList:values];

    XCBWindowTypeResponse* response = [[super connection] createWindowForRequest:request registerWindow:YES];
    XCBTitleBar *titleBar = [response titleBar];

    // If using ARGB visual, configure titlebar for 32-bit pixmaps
    if (depth == 32 && argbColormap != XCB_NONE) {
        [titleBar setUse32BitDepth:YES];
        [titleBar setArgbVisualId:[titlebarVisual visualId]];
        //NSLog(@"[XCBFrame] Configured titlebar for 32-bit ARGB pixmaps");
    }

    [self addChildWindow:titleBar withKey:TitleBar];

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];

    xcb_get_property_reply_t* reply = [ewmhService getProperty:[ewmhService EWMHWMName]
                              propertyType:XCB_GET_PROPERTY_TYPE_ANY
                                 forWindow:clientWindow
                                    delete:NO
                                    length:UINT32_MAX];

    NSString* windowTitle;
    if (reply)
    {
        char *value = xcb_get_property_value(reply);
        int len = xcb_get_property_value_length(reply);
            //NSLog(@"Window title: %s, len: %d", value, len);
        windowTitle = [NSString stringWithCString:value length:len];
    }

    // for now if it is nil just set an empty string

    if (windowTitle == nil)
    {
        ICCCMService* icccmService = [ICCCMService sharedInstanceWithConnection:connection];

        windowTitle = [icccmService getWmNameForWindow:clientWindow];

        if (windowTitle == nil)
            windowTitle = @"";

        icccmService = nil;
    }

    [titleBar onScreen];
    [titleBar updateAttributes];
    [titleBar setIsMapped:YES];
    
    // OPTIMIZATION: Only create pixmaps - skip legacy drawing if GSTheme will override
    // GSTheme integration in URSHybridEventHandler will render the titlebar contents
    // Creating pixmaps is still needed as GSTheme renders to them
    [titleBar createPixmap];
    
    // OPTIMIZATION: Skip button generation and legacy drawing when GSTheme is active
    // These operations are expensive and get completely overwritten by GSTheme
    if (![titleBar isGSThemeActive]) {
        [titleBar generateButtons];
        [titleBar setButtonsAbove:YES];
        [titleBar drawTitleBarComponentsPixmaps];
        [titleBar putWindowBackgroundWithPixmap:[titleBar pixmap]];
        [titleBar putButtonsBackgroundPixmaps:YES];
        [titleBar setWindowTitle:windowTitle];
    }
    
    [titleBar setIsAbove:YES];
    [clientWindow setDecorated:YES];
    [clientWindow setWindowBorderWidth:0];
    [connection mapWindow:titleBar];
    
    // Store title for later GSTheme rendering
    [titleBar setInternalTitle:windowTitle];

    // Position client window below titlebar; inset by clientBorder (1px in non-compositor, 0 in compositor)
    int cb = self.clientBorder;
    XCBPoint position = XCBMakePoint(cb, height);

    // When reparenting an already-mapped client the X server automatically unmaps then remaps
    // it.  This produces exactly two synthetic UnmapNotify events:
    //   1. event=root  (root's SubstructureNotify, from the implicit unmap)
    //   2. event=client (client's own StructureNotify, selected via CLIENT_SELECT_INPUT_EVENT_MASK)
    // Pre-arm the counter so handleUnMapNotify absorbs both without destroying the frame.
    if ([[clientWindow attributes] mapState] == XCB_MAP_STATE_VIEWABLE) {
        clientWindow.ignoreUnmapCount = 2;
    }

    [connection reparentWindow:clientWindow toWindow:self position:position];

    // Add the client to the WM's save-set (ICCCM §4.1.4).  If the window
    // manager connection dies — even via SIGKILL — the X server automatically
    // reparents every save-set window back to the root (preserving stacking
    // and position) before destroying the WM-created frame windows.  Without
    // this, killing the WM destroys the frames AND the reparented clients with
    // them, losing windows.
    xcb_change_save_set([connection connection], XCB_SET_MODE_INSERT, [clientWindow window]);

    [connection mapWindow:clientWindow];
    uint32_t border[] = {0};
    // Ensure no borders on frame window
    xcb_configure_window([connection connection], window, XCB_CONFIG_WINDOW_BORDER_WIDTH, border);
    // Ensure no borders on client window
    xcb_configure_window([connection connection], [clientWindow window], XCB_CONFIG_WINDOW_BORDER_WIDTH, border);

    // Resize client to fill frame below titlebar (minus clientBorder on sides and bottom)
    uint32_t clientSize[2] = {[self windowRect].size.width - 2 * (uint32_t)cb,
                              [self windowRect].size.height - height - (uint32_t)cb};
    xcb_configure_window([connection connection], [clientWindow window],
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, clientSize);
    
    // Flush to ensure reparent and map operations complete before continuing
    [connection flush];
    
    // Create resize zones for resizable windows with decorations only
    if ([clientWindow canResize] && [clientWindow decorated]) {
        [self createResizeZonesFromTheme];
    }

    // Apply rounded top corners shape mask
    [self applyRoundedCornersShapeMask];

    titleBar = nil;
    clientWindow = nil;
    ewmhService = nil;
    windowTitle = nil;
    scr = nil;
    rootVisual = nil;
    settings = nil;

    free(reply);
}

- (void)createResizeHandle
{
    // Get scrollbar width from current theme
    CGFloat scrollerWidth = [NSScroller scrollerWidth];
    uint16_t handleSize = (uint16_t)scrollerWidth;

    // Create a square at bottom-right matching scrollbar width
    xcb_window_t resizeHandleWindow = xcb_generate_id([connection connection]);

    XCBRect frameRect = [self windowRect];
    int16_t handleX = frameRect.size.width - handleSize;
    int16_t handleY = frameRect.size.height - handleSize;

    // InputOnly window - invisible, just captures mouse events
    // Theme renders the grow box visual in the scroll view corner
    uint32_t mask = XCB_CW_EVENT_MASK | XCB_CW_CURSOR;
    uint32_t values[2];

    // Get diagonal resize cursor (bottom-right) without mutating selection state
    xcb_cursor_t resizeCursor = [[self cursor] cursorIdForPosition:BottomRightCorner];

    values[0] = XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
                XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW;
    values[1] = resizeCursor;

    xcb_create_window([connection connection],
                      XCB_COPY_FROM_PARENT,
                      resizeHandleWindow,
                      window, // Parent is the frame
                      handleX, handleY,
                      handleSize, handleSize,
                      0, // no border
                      XCB_WINDOW_CLASS_INPUT_ONLY,
                      XCB_COPY_FROM_PARENT,
                      mask,
                      values);

    // Create XCBWindow wrapper and register it
    XCBWindow *resizeHandle = [[XCBWindow alloc] initWithXCBWindow:resizeHandleWindow andConnection:connection];
    [resizeHandle setParentWindow:self];
    [self addChildWindow:resizeHandle withKey:ResizeHandle];
    [connection registerWindow:resizeHandle];

    // Map the resize handle
    xcb_map_window([connection connection], resizeHandleWindow);

    // Raise resize handle above siblings (titlebar, client window) so it captures events
    [resizeHandle stackAbove];

    [connection flush];
}

/*** performance while resizing pixel by pixel is critical so we do everything we can to improve it also if the message signature looks bad ***/

 // While shaded there is no vertical content to resize, so the resize
 // cursor must not advertise a resize that is disabled.  Flip every
 // resize-zone/handle window's cursor between its resize cursor and the
 // normal left pointer according to the shade state.
 - (void)updateResizeCursorForShadedState
 {
     BOOL shaded = [self shaded];

     XCBWindow *handle = [self childWindowForKey:ResizeHandle];
     if (handle) {
         if (shaded) [handle showLeftPointerCursor];
         else        [handle showResizeCursorForPosition:BottomRightCorner];
     }

     struct { childrenMask key; MousePosition pos; } map[] = {
         { ResizeZoneN,    TopBorder },
         { ResizeZoneS,    BottomBorder },
         { ResizeZoneE,    RightBorder },
         { ResizeZoneW,    LeftBorder },
         { ResizeZoneNE,   TopRightCorner },
         { ResizeZoneNW,   TopLeftCorner },
         { ResizeZoneSE,   BottomRightCorner },
         { ResizeZoneSW,   BottomLeftCorner },
         { ResizeZoneGrowBox, BottomRightCorner }
     };
     for (int i = 0; i < (int)(sizeof(map) / sizeof(map[0])); i++) {
         XCBWindow *zone = [self childWindowForKey:map[i].key];
         if (!zone)
             continue;
         if (shaded) [zone showLeftPointerCursor];
         else        [zone showResizeCursorForPosition:map[i].pos];
     }
 }

 - (void) resize:(xcb_motion_notify_event_t *)anEvent xcbConnection:(xcb_connection_t*)aXcbConnection
 {
    int clientBorder = self.clientBorder;

    /* Always use the current service titlebar height so interactive resizes
     * match the rendered titlebar even after a GSScaleFactor change (which
     * re-frames windows but must not leave the cached titleHeight stale). */
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    titleHeight = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    /*** width ***/

    if (rightBorderClicked && !bottomBorderClicked && !leftBorderClicked && !topBorderClicked)
    {
        resizeFromRightForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }

    if (leftBorderClicked && !bottomBorderClicked && !rightBorderClicked && !topBorderClicked)
    {
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }


    /** height - disabled while shaded (the frame is clipped to the
     *  titlebar, so there is no vertical content to resize; corners keep
     *  their horizontal component below). **/

    if (bottomBorderClicked && !rightBorderClicked && !leftBorderClicked)
    {
        if (![self shaded])
            resizeFromBottomForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight, clientBorder);
    }


    if (topBorderClicked && !rightBorderClicked && !leftBorderClicked && !bottomBorderClicked)
    {
        if (![self shaded])
            resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight, clientBorder);
    }


    /** width and height - corner resizes **/

    // SE corner (bottom-right)
    if (rightBorderClicked && bottomBorderClicked && !leftBorderClicked && !topBorderClicked)
    {
        if (![self shaded])
            resizeFromAngleForEvent(anEvent, aXcbConnection, self, minWidthHint, minHeightHint, titleHeight, clientBorder);
        else
            resizeFromRightForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }

    // NW corner (top-left) - combine top and left resizes
    if (topBorderClicked && leftBorderClicked && !rightBorderClicked && !bottomBorderClicked)
    {
        if (![self shaded])
            resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight, clientBorder);
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }

    // NE corner (top-right) - combine top and right resizes
    if (topBorderClicked && rightBorderClicked && !leftBorderClicked && !bottomBorderClicked)
    {
        if (![self shaded])
            resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight, clientBorder);
        resizeFromRightForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }

    // SW corner (bottom-left) - combine bottom and left resizes
    if (bottomBorderClicked && leftBorderClicked && !rightBorderClicked && !topBorderClicked)
    {
        if (![self shaded])
            resizeFromBottomForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight, clientBorder);
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint, clientBorder);
    }

    // Resize zones and shape mask are updated at button release (handleButtonRelease),
    // not on every motion event.  This keeps the hot path to the minimum 2-3 async
    // xcb_configure_window calls needed to move/resize the actual windows.

}

- (void)updateResizeHandlePosition
{
    XCBWindow *resizeHandle = [self childWindowForKey:ResizeHandle];
    if (resizeHandle) {
        // Get current scrollbar width from theme
        CGFloat scrollerWidth = [NSScroller scrollerWidth];
        uint16_t handleSize = (uint16_t)scrollerWidth;

        XCBRect frameRect = [self windowRect];
        int16_t handleX = frameRect.size.width - handleSize;
        int16_t handleY = frameRect.size.height - handleSize;

        // Update position and ensure handle stays above siblings in one call
        uint32_t values[3] = {handleX, handleY, XCB_STACK_MODE_ABOVE};
        xcb_configure_window([connection connection],
                           [resizeHandle window],
                           XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_STACK_MODE,
                           values);
    }
}

- (void)raiseResizeHandle
{
    // Raise legacy resize handle
    XCBWindow *resizeHandle = [self childWindowForKey:ResizeHandle];
    if (resizeHandle) {
        [resizeHandle stackAbove];
    }

    // Raise all theme-driven resize zones
    childrenMask zones[] = {ResizeZoneNW, ResizeZoneN, ResizeZoneNE, ResizeZoneE,
                           ResizeZoneSE, ResizeZoneS, ResizeZoneSW, ResizeZoneW,
                           ResizeZoneGrowBox};
    for (int i = 0; i < sizeof(zones)/sizeof(zones[0]); i++) {
        XCBWindow *zone = [self childWindowForKey:zones[i]];
        if (zone) {
            [zone stackAbove];
        }
    }
}

#pragma mark - Theme-driven Resize Zones

- (void)createResizeZonesFromTheme
{
    // Query theme for resize zone support using respondsToSelector:
    // This allows themes to implement resize zones without requiring libs-gui changes
    GSTheme *theme = [GSTheme theme];

    // Check if theme supports the resize zone protocol
    if (![theme respondsToSelector:@selector(resizeZoneCornerSize)]) {
        // Theme doesn't support resize zones - fall back to legacy single resize handle
        [self createResizeHandle];
        return;
    }

    // Get resize zone dimensions from theme
    CGFloat cornerSize = [theme resizeZoneCornerSize];
    CGFloat edgeThickness = 4.0; // Default edge thickness

    if ([theme respondsToSelector:@selector(resizeZoneEdgeThickness)]) {
        edgeThickness = [theme resizeZoneEdgeThickness];
    }

    XCBRect frameRect = [self windowRect];
    CGFloat w = frameRect.size.width;
    CGFloat h = frameRect.size.height;

    // Create resize zones for all 8 directions
    // Corners (square zones)
    [self createResizeZoneAtX:0 y:0
                        width:cornerSize height:cornerSize
                     position:TopLeftCorner
                          key:ResizeZoneNW];

    [self createResizeZoneAtX:w - cornerSize y:0
                        width:cornerSize height:cornerSize
                     position:TopRightCorner
                          key:ResizeZoneNE];

    [self createResizeZoneAtX:0 y:h - cornerSize
                        width:cornerSize height:cornerSize
                     position:BottomLeftCorner
                          key:ResizeZoneSW];

    // Only create SE corner zone if grow box is NOT enabled
    // (grow box replaces SE corner with a larger zone)
    BOOL hasGrowBox = [theme respondsToSelector:@selector(resizeZoneHasGrowBox)] &&
                      [theme resizeZoneHasGrowBox];
    if (!hasGrowBox) {
        [self createResizeZoneAtX:w - cornerSize y:h - cornerSize
                            width:cornerSize height:cornerSize
                         position:BottomRightCorner
                              key:ResizeZoneSE];
    }

    // Edges (thin zones between corners)
    [self createResizeZoneAtX:cornerSize y:0
                        width:w - 2*cornerSize height:edgeThickness
                     position:TopBorder
                          key:ResizeZoneN];

    [self createResizeZoneAtX:cornerSize y:h - edgeThickness
                        width:w - 2*cornerSize height:edgeThickness
                     position:BottomBorder
                          key:ResizeZoneS];

    [self createResizeZoneAtX:0 y:cornerSize
                        width:edgeThickness height:h - 2*cornerSize
                     position:LeftBorder
                          key:ResizeZoneW];

    [self createResizeZoneAtX:w - edgeThickness y:cornerSize
                        width:edgeThickness height:h - 2*cornerSize
                     position:RightBorder
                          key:ResizeZoneE];

    // Optionally create grow box zone (overlays SE corner with larger size)
    if ([theme respondsToSelector:@selector(resizeZoneHasGrowBox)] &&
        [theme resizeZoneHasGrowBox]) {
        CGFloat growBoxSize = cornerSize; // Default to corner size
        if ([theme respondsToSelector:@selector(resizeZoneGrowBoxSize)]) {
            growBoxSize = [theme resizeZoneGrowBoxSize];
        }
        [self createResizeZoneAtX:w - growBoxSize y:h - growBoxSize
                            width:growBoxSize height:growBoxSize
                         position:BottomRightCorner
                              key:ResizeZoneGrowBox];
    }

    [connection flush];
}

- (void)createResizeZoneAtX:(CGFloat)x y:(CGFloat)y
                      width:(CGFloat)width height:(CGFloat)height
                   position:(MousePosition)position
                        key:(childrenMask)key
{
    // Skip if zone would have invalid dimensions
    if (width <= 0 || height <= 0) {
        return;
    }

    xcb_window_t zoneWindow = xcb_generate_id([connection connection]);

    // Invisible INPUT_ONLY window - captures mouse events only
    uint32_t mask = XCB_CW_EVENT_MASK | XCB_CW_CURSOR;
    uint32_t values[2];

    // Get appropriate resize cursor for this position without mutating selection state
    xcb_cursor_t resizeCursor = [[self cursor] cursorIdForPosition:position];

    values[0] = XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
                XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW;
    values[1] = resizeCursor;

    xcb_create_window([connection connection],
                      XCB_COPY_FROM_PARENT,
                      zoneWindow,
                      window, // Parent is the frame
                      (int16_t)x, (int16_t)y,
                      (uint16_t)width, (uint16_t)height,
                      0, // no border
                      XCB_WINDOW_CLASS_INPUT_ONLY,
                      XCB_COPY_FROM_PARENT,
                      mask,
                      values);

    // Create XCBWindow wrapper and register it
    XCBWindow *resizeZone = [[XCBWindow alloc] initWithXCBWindow:zoneWindow andConnection:connection];
    [resizeZone setParentWindow:self];
    [self addChildWindow:resizeZone withKey:key];
    [connection registerWindow:resizeZone];

    // Map the resize zone
    xcb_map_window([connection connection], zoneWindow);

    // Raise above siblings
    [resizeZone stackAbove];
}

- (void)updateAllResizeZonePositions
{
    GSTheme *theme = [GSTheme theme];

    // Check if we're using theme-driven zones or legacy resize handle
    if (![theme respondsToSelector:@selector(resizeZoneCornerSize)]) {
        // Using legacy resize handle
        [self updateResizeHandlePosition];
        return;
    }

    CGFloat cornerSize = [theme resizeZoneCornerSize];
    CGFloat edgeThickness = 4.0;

    if ([theme respondsToSelector:@selector(resizeZoneEdgeThickness)]) {
        edgeThickness = [theme resizeZoneEdgeThickness];
    }

    XCBRect frameRect = [self windowRect];
    CGFloat w = frameRect.size.width;
    CGFloat h = frameRect.size.height;

    // Update corner positions
    [self updateResizeZone:ResizeZoneNW toX:0 y:0 width:cornerSize height:cornerSize];
    [self updateResizeZone:ResizeZoneNE toX:w - cornerSize y:0 width:cornerSize height:cornerSize];
    [self updateResizeZone:ResizeZoneSW toX:0 y:h - cornerSize width:cornerSize height:cornerSize];
    [self updateResizeZone:ResizeZoneSE toX:w - cornerSize y:h - cornerSize width:cornerSize height:cornerSize];

    // Update edge positions
    [self updateResizeZone:ResizeZoneN toX:cornerSize y:0 width:w - 2*cornerSize height:edgeThickness];
    [self updateResizeZone:ResizeZoneS toX:cornerSize y:h - edgeThickness width:w - 2*cornerSize height:edgeThickness];
    [self updateResizeZone:ResizeZoneW toX:0 y:cornerSize width:edgeThickness height:h - 2*cornerSize];
    [self updateResizeZone:ResizeZoneE toX:w - edgeThickness y:cornerSize width:edgeThickness height:h - 2*cornerSize];

    // Update grow box zone if present
    if ([theme respondsToSelector:@selector(resizeZoneHasGrowBox)] &&
        [theme resizeZoneHasGrowBox]) {
        CGFloat growBoxSize = cornerSize;
        if ([theme respondsToSelector:@selector(resizeZoneGrowBoxSize)]) {
            growBoxSize = [theme resizeZoneGrowBoxSize];
        }
        [self updateResizeZone:ResizeZoneGrowBox toX:w - growBoxSize y:h - growBoxSize width:growBoxSize height:growBoxSize];
    }
}

- (void)updateResizeZone:(childrenMask)key toX:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height
{
    XCBWindow *zone = [self childWindowForKey:key];
    if (zone) {
        uint32_t values[5] = {(uint32_t)x, (uint32_t)y, (uint32_t)width, (uint32_t)height, XCB_STACK_MODE_ABOVE};
        xcb_configure_window([connection connection],
                           [zone window],
                           XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                           XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT |
                           XCB_CONFIG_WINDOW_STACK_MODE,
                           values);
    }
}

- (void)destroyResizeZones
{
    // Destroy all resize zone windows
    childrenMask zones[] = {ResizeZoneNW, ResizeZoneN, ResizeZoneNE, ResizeZoneE,
                           ResizeZoneSE, ResizeZoneS, ResizeZoneSW, ResizeZoneW,
                           ResizeZoneGrowBox, ResizeHandle}; // Also handle legacy

    for (int i = 0; i < sizeof(zones)/sizeof(zones[0]); i++) {
        XCBWindow *zone = [self childWindowForKey:zones[i]];
        if (zone) {
            xcb_destroy_window([connection connection], [zone window]);
            [connection unregisterWindow:zone];
            [self removeChild:zones[i]];
        }
    }
}

- (void)clearShapeMasks
{
    // Remove any XShape bounding mask from the frame and titlebar windows so that
    // the entire rectangle is visible during live resize.  This removes the stale
    // pre-resize clip that would otherwise blank newly-painted pixels when the
    // window grows.  Rounded corners are re-applied in full at button release.
    const xcb_query_extension_reply_t *ext =
        xcb_get_extension_data([connection connection], &xcb_shape_id);
    if (!ext || !ext->present) return;

    xcb_connection_t *conn = [connection connection];
    xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING, window, 0, 0, XCB_NONE);

    XCBTitleBar *titleBar = (XCBTitleBar *)[self childWindowForKey:TitleBar];
    if (titleBar) {
        xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING,
                       [titleBar window], 0, 0, XCB_NONE);
    }
}

- (void)applyRoundedCornersShapeMask
{
    // Query theme for corner radii - default to 0 (square corners) if not provided
    GSTheme *theme = [GSTheme theme];
    CGFloat topRadius = 0;
    CGFloat bottomRadius = 0;

    if ([theme respondsToSelector:@selector(titlebarCornerRadius)]) {
        topRadius = [theme titlebarCornerRadius];
    }

    if ([theme respondsToSelector:@selector(windowBottomCornerRadius)]) {
        bottomRadius = [theme windowBottomCornerRadius];
    }

    if (topRadius <= 0 && bottomRadius <= 0)
        return;

    // Use internal windowRect rather than a blocking xcb_get_geometry round-trip.
    // The C resize functions always update windowRect via setWindowRect: before
    // returning, so this is always current.
    XCBRect frameRect = [self windowRect];
    int fw = (int)frameRect.size.width;
    int fh = (int)frameRect.size.height;
    if (fw <= 0 || fh <= 0)
        return;

    // Check if compositor is active
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    BOOL compositorActive = NO;
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)]) {
        id manager = [compositorClass sharedManager];
        if ([manager respondsToSelector:@selector(compositingActive)]) {
            compositorActive = [manager compositingActive];
        }
    }

    // Apply bounding-shape to the FRAME window (always needed in non-compositor mode)
    if (!compositorActive) {
        XCBShape *shape = [[XCBShape alloc] initWithConnection:connection withWinId:window];
        if ([shape checkSupported]) {
            shape.width = fw;
            shape.height = fh;
            shape.borderWidth = 0;
            shape.orWidth = fw;
            shape.orHeight = fh;
            [shape createPixmapsAndGCs];
            [shape createRoundedCornersWithTopRadius:(int)topRadius bottomRadius:(int)bottomRadius];
        }
        shape = nil;
    }

    // In NON-compositor mode only: apply XShape to titlebar.
    // In compositor mode, URSThemeIntegration.m handles rounded corners via ARGB alpha blending.
    // XShape in compositor mode causes the initial-map sharp-corners issue and is not needed.
    if (topRadius > 0 && !compositorActive) {
        XCBTitleBar *titleBar = (XCBTitleBar *)[self childWindowForKey:TitleBar];
        if (titleBar) {
            int th = (int)titleHeight;  // titlebar height = the band above client
            XCBShape *tbShape = [[XCBShape alloc] initWithConnection:connection
                                                             withWinId:[titleBar window]];
            if ([tbShape checkSupported]) {
                tbShape.width = fw;
                tbShape.height = th;
                tbShape.borderWidth = 0;
                tbShape.orWidth = fw;
                tbShape.orHeight = th;
                [tbShape createPixmapsAndGCs];
                [tbShape createTopArcsWithRadius:(int)topRadius];
            }
            tbShape = nil;
            titleBar = nil;
        }
    }
}

void resizeFromRightForEvent(xcb_motion_notify_event_t *anEvent,
                             xcb_connection_t *connection,
                             XCBFrame* frame,
                             int minW,
                             int cb)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    // Respect ICCCM: if client is non-resizable, ignore interactive resize
    if (clientWindow && ![clientWindow canResize]) {
        //NSDebugLog(@"Ignoring interactive right-edge resize for non-resizable client %u", [clientWindow window]);
        return;
    }
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
    //xcb_connection_t *connection = [[frame connection] connection];

    XCBRect frameRect = [frame windowRect];
    XCBRect titleBarRect = [titleBar windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    // Apply minimum visibility constraint when shrinking
    const int32_t MIN_VISIBLE_PIXELS = 16;
    XCBConnection *xcbConn = [frame connection];
    int32_t newWidth = anEvent->event_x;

    if ([xcbConn workareaValid]) {
        int32_t workareaX = [xcbConn cachedWorkareaX];
        // Ensure at least MIN_VISIBLE_PIXELS of right edge stays on screen
        // rightEdge = frameX + newWidth, must be >= workareaX + MIN_VISIBLE_PIXELS
        int32_t minWidth = workareaX + MIN_VISIBLE_PIXELS - frameRect.position.x;
        if (minWidth > minW) {
            minW = minWidth;
        }
    }

    // minW is a minimum *client* width; translate to minimum frame width
    int32_t minimumClientWidth = (minW < 1) ? 1 : minW;
    int32_t minimumFrameWidth = minimumClientWidth + 2 * cb;

    // Clamp to minimum width using signed arithmetic to prevent underflow
    if (newWidth < minimumFrameWidth)
        newWidth = minimumFrameWidth;

    int32_t newClientWidth = newWidth - 2 * cb;
    if (newClientWidth < minimumClientWidth)
        newClientWidth = minimumClientWidth;

    uint32_t values[1];

    values[0] = (uint32_t)newWidth;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH, values);
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, values);
    values[0] = (uint32_t)newClientWidth;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH, values);

    frameRect.size.width = (uint16_t)newWidth;
    [frame setWindowRect:frameRect];
    [frame setOriginalRect:frameRect];

    titleBarRect.size.width = (uint16_t)newWidth;
    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    clientRect.size.width = (uint16_t)newClientWidth;
    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client.  Coordinates must be in
    // ROOT space (ICCCM), i.e. frame origin + client offset inside the frame.
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  frameRect.position.x + cb,
                                  frameRect.position.y + [frame titleHeight],
                                  clientRect.size.width,
                                  clientRect.size.height);

    clientWindow = nil;
    titleBar = nil;
    connection = NULL;
}

void resizeFromLeftForEvent(xcb_motion_notify_event_t *anEvent,
                            xcb_connection_t *connection,
                            XCBFrame* frame,
                            int minW,
                            int cb)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    // Respect ICCCM: if client is non-resizable, ignore interactive resize
    if (clientWindow && ![clientWindow canResize]) {
        //NSDebugLog(@"Ignoring interactive left-edge resize for non-resizable client %u", [clientWindow window]);
        return;
    }
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
    //xcb_connection_t *connection = [[frame connection] connection];

    XCBRect rect = [frame windowRect];
    XCBRect titleBarRect = [titleBar windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    // Apply minimum visibility constraint
    const int32_t MIN_VISIBLE_PIXELS = 16;
    XCBConnection *xcbConn = [frame connection];
    int16_t newX = anEvent->root_x;

    if ([xcbConn workareaValid]) {
        int32_t workareaX = [xcbConn cachedWorkareaX];
        int32_t workareaWidth = [xcbConn cachedWorkareaWidth];
        int32_t newWidth = rect.position.x - newX + rect.size.width;

        // Ensure at least MIN_VISIBLE_PIXELS of right edge stays on screen
        int32_t minX = workareaX + MIN_VISIBLE_PIXELS - newWidth;
        if (newX < minX) {
            newX = minX;
        }
        // Ensure at least MIN_VISIBLE_PIXELS of left edge stays on screen
        int32_t maxX = workareaX + workareaWidth - MIN_VISIBLE_PIXELS;
        if (newX > maxX) {
            newX = maxX;
        }
    }

    int xDelta = rect.position.x - newX;
    int32_t newFrameWidth = xDelta + (int32_t)rect.size.width;

    int32_t minimumClientWidth = (minW < 1) ? 1 : minW;
    int32_t minimumFrameWidth = minimumClientWidth + 2 * cb;

    // Clamp to minimum width using client-size hints translated to frame pixels
    if (newFrameWidth < minimumFrameWidth) {
        // Keep the right edge fixed; set left to preserve minimum size
        int32_t rightEdge = rect.position.x + rect.size.width;
        newX = rightEdge - minimumFrameWidth;
        newFrameWidth = minimumFrameWidth;
    }

    int32_t newClientWidth = newFrameWidth - 2 * cb;
    if (newClientWidth < minimumClientWidth)
        newClientWidth = minimumClientWidth;

    uint32_t values[2];

    values[0] = (uint32_t)newX;
    values[1] = (uint32_t)newFrameWidth;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, values);

    rect.position.x = newX;
    rect.size.width = (uint16_t)newFrameWidth;

    values[0] = 0;
    values[1] = (uint32_t)newFrameWidth;
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, values);

    titleBarRect.position.x = 0;
    titleBarRect.size.width = (uint16_t)newFrameWidth;

    values[0] = cb;
    values[1] = (uint32_t)newClientWidth;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, values);

    clientRect.position.x = cb;
    clientRect.size.width = (uint16_t)newClientWidth;

    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x + cb,
                                  rect.position.y + [frame titleHeight],
                                  clientRect.size.width,
                                  clientRect.size.height);

    clientWindow = nil;
    titleBar = nil;
    connection = NULL;

}

void resizeFromBottomForEvent(xcb_motion_notify_event_t *anEvent,
                              xcb_connection_t *connection,
                              XCBFrame* frame,
                              int minH,
                              uint16_t titleBarHeight,
                              int cb)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    // Respect ICCCM: if client is non-resizable, ignore interactive resize
    if (clientWindow && ![clientWindow canResize]) {
        //NSDebugLog(@"Ignoring interactive bottom-edge resize for non-resizable client %u", [clientWindow window]);
        return;
    }
    //xcb_connection_t *connection = [[frame connection] connection];

    XCBRect rect = [frame windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    // Apply minimum visibility constraint when shrinking
    const int32_t MIN_VISIBLE_PIXELS = 16;
    XCBConnection *xcbConn = [frame connection];

    if ([xcbConn workareaValid]) {
        int32_t workareaY = [xcbConn cachedWorkareaY];
        // Ensure at least MIN_VISIBLE_PIXELS of bottom edge stays on screen
        // bottomEdge = frameY + newHeight, must be >= workareaY + MIN_VISIBLE_PIXELS
        int32_t minHeight = workareaY + MIN_VISIBLE_PIXELS - rect.position.y;
        if (minHeight > minH + titleBarHeight) {
            minH = minHeight - titleBarHeight;
        }
    }

    // Use signed arithmetic to prevent underflow when event_y is smaller than titlebar
    int32_t newFrameHeight = (int32_t)anEvent->event_y;
    int32_t minFrameHeight = minH + titleBarHeight + cb;

    // Clamp to minimum
    if (newFrameHeight < minFrameHeight)
        newFrameHeight = minFrameHeight;

    int32_t newClientHeight = newFrameHeight - titleBarHeight - cb;
    if (newClientHeight < minH)
        newClientHeight = minH;

    uint32_t values[1];

    values[0] = (uint32_t)newClientHeight;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_HEIGHT, values);
    clientRect.size.height = (uint16_t)newClientHeight;

    values[0] = (uint32_t)newFrameHeight;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_HEIGHT, values);

    rect.size.height = (uint16_t)newFrameHeight;
    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x + cb,
                                  rect.position.y + titleBarHeight,
                                  clientRect.size.width,
                                  clientRect.size.height);

    clientWindow = nil;
    connection = NULL;
}

void resizeFromTopForEvent(xcb_motion_notify_event_t *anEvent,
                           xcb_connection_t *connection,
                           XCBFrame* frame,
                           int minH,
                           uint16_t titleBarHeight,
                           int cb)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    // Respect ICCCM: if client is non-resizable, ignore interactive resize
    if (clientWindow && ![clientWindow canResize]) {
        //NSDebugLog(@"Ignoring interactive top-edge resize for non-resizable client %u", [clientWindow window]);
        return;
    }
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];

    XCBRect rect = [frame windowRect];
    XCBRect titleBarRect = [titleBar windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    // Apply minimum visibility constraint
    const int32_t MIN_VISIBLE_PIXELS = 16;
    XCBConnection *xcbConn = [frame connection];
    int16_t newY = anEvent->root_y;

    if ([xcbConn workareaValid]) {
        int32_t workareaY = [xcbConn cachedWorkareaY];
        int32_t workareaHeight = [xcbConn cachedWorkareaHeight];

        // Don't allow titlebar to go above workarea top
        if (newY < workareaY) {
            newY = workareaY;
        }
        // Ensure at least MIN_VISIBLE_PIXELS of top stays on screen
        int32_t maxY = workareaY + workareaHeight - MIN_VISIBLE_PIXELS;
        if (newY > maxY) {
            newY = maxY;
        }
    }

    int32_t yDelta = (int32_t)rect.position.y - (int32_t)newY;
    int32_t newFrameHeight = (int32_t)rect.size.height + yDelta;
    int32_t minFrameHeight = minH + titleBarHeight + cb;

    // Clamp: if the new height is below minimum, fix the top position
    if (newFrameHeight < minFrameHeight) {
        // Keep the bottom edge fixed; set top to preserve minimum size
        int32_t bottomEdge = rect.position.y + rect.size.height;
        newY = bottomEdge - minFrameHeight;
        newFrameHeight = minFrameHeight;
    }

    int32_t newClientHeight = newFrameHeight - titleBarHeight - cb;
    if (newClientHeight < minH)
        newClientHeight = minH;

    uint32_t values[2];

    // Configure frame (position + height)
    values[0] = (uint32_t)newY;
    values[1] = (uint32_t)newFrameHeight;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, values);

    rect.position.y = newY;
    rect.size.height = (uint16_t)newFrameHeight;

    // Titlebar Y is always 0 relative to frame
    values[0] = 0;
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_Y, values);
    titleBarRect.position.y = 0;

    // Configure client
    values[0] = titleBarHeight;
    values[1] = (uint32_t)newClientHeight;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, values);
    clientRect.size.height = (uint16_t)newClientHeight;
    clientRect.position.y = titleBarHeight;

    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x + cb,
                                  rect.position.y + titleBarHeight,
                                  clientRect.size.width,
                                  clientRect.size.height);

    clientWindow = nil;
    titleBar = nil;
    connection = NULL;
}

void resizeFromAngleForEvent(xcb_motion_notify_event_t *anEvent,
                             xcb_connection_t *connection,
                             XCBFrame *frame,
                             int minW,
                             int minH,
                             uint16_t titleBarHeight,
                             int cb)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    // Respect ICCCM: if client is non-resizable, ignore interactive resize
    if (clientWindow && ![clientWindow canResize]) {
        //NSDebugLog(@"Ignoring interactive corner resize for non-resizable client %u", [clientWindow window]);
        return;
    }
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
    //xcb_connection_t *connection = [[frame connection] connection];

    XCBRect rect = [frame windowRect];
    XCBRect titleBarRect = [titleBar windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    // Use signed arithmetic to prevent underflow
    int32_t newFrameWidth = (int32_t)anEvent->event_x;
    int32_t newFrameHeight = (int32_t)anEvent->event_y;

    // Clamp to minimum dimensions
    int32_t minimumClientWidth = (minW < 1) ? 1 : minW;
    int32_t minimumFrameWidth = minimumClientWidth + 2 * cb;
    int32_t minFrameHeight = minH + titleBarHeight + cb;
    if (newFrameWidth < minimumFrameWidth)
        newFrameWidth = minimumFrameWidth;
    if (newFrameHeight < minFrameHeight)
        newFrameHeight = minFrameHeight;

    int32_t newClientWidth = newFrameWidth - 2 * cb;
    int32_t newClientHeight = newFrameHeight - titleBarHeight - cb;
    if (newClientWidth < minimumClientWidth) newClientWidth = minimumClientWidth;
    if (newClientHeight < 1) newClientHeight = 1;

    uint32_t values[2];

    values[0] = (uint32_t)newFrameWidth;
    values[1] = (uint32_t)newFrameHeight;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);

    values[0] = (uint32_t)newFrameWidth;
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, values);

    values[0] = (uint32_t)newClientWidth;
    values[1] = (uint32_t)newClientHeight;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, values);

    rect.size.width = (uint16_t)newFrameWidth;
    rect.size.height = (uint16_t)newFrameHeight;
    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    titleBarRect.size.width = (uint16_t)newFrameWidth;
    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    clientRect.size.width = (uint16_t)newClientWidth;
    clientRect.size.height = (uint16_t)newClientHeight;
    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x + cb,
                                  rect.position.y + titleBarHeight,
                                  clientRect.size.width,
                                  clientRect.size.height);

    titleBar = nil;
    clientWindow = nil;
    connection = NULL;
}

- (void) moveTo:(XCBPoint)coordinates
{
    // Minimal implementation for maximum performance
    XCBPoint pos = XCBMakePoint(coordinates.x - offset.x, coordinates.y - offset.y);

    // Cast through int32_t first: (uint32_t)(negative double) is undefined
    // behavior in C, causing window jumps when the position goes negative
    // (e.g. left edge crossing the left screen border).
    uint32_t values[] = {(uint32_t)(int32_t)pos.x, (uint32_t)(int32_t)pos.y};
    xcb_configure_window([connection connection], window, XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, values);
    // PERFORMANCE FIX: Don't flush on every motion event - let the event loop batch flushes
    // xcb_flush([connection connection]);

    // Update internal state only - skip expensive rect operations during drag
    XCBRect rect = [super windowRect];
    rect.position = pos;
    [super setWindowRect:rect];
}

- (void) configureClient
{
    xcb_configure_notify_event_t event;
    XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
    // Use the frame's cached rect to derive the client geometry instead of the
    // client's own cache: configureForEvent: resizes the client (and flushes)
    // but never updates the client's cached rect, so reading the stale cache
    // here would send a synthetic ConfigureNotify describing the pre-resize
    // size.  The client (GNUstep) processes that as the final geometry and its
    // tracked frame ends up desynced from the real window.
    XCBRect rect = [self windowRect];
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t height = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // While shaded the frame is clipped to the titlebar, so its cached rect
    // height is tiny.  Reporting that clipped height to the client would make
    // the application (GNUstep) shrink the client to ~0 and stop drawing;
    // on unshade no fresh ConfigureNotify is sent, leaving the window blank
    // (only the frame and shadow render).  The client content never actually
    // shrinks when shaded - only the parent clip changes - so report the
    // client's full, unshaded geometry (saved as oldRect at shade time).
    uint16_t frameHeight = rect.size.height;
    if ([self shaded]) {
        XCBRect full = [self oldRect];
        if (FnCheckXCBRectIsValid(full) && full.size.height > frameHeight)
            frameHeight = full.size.height;
    }

    XCBRect clientRect = XCBMakeRect(XCBMakePoint(self.clientBorder, height),
                                     XCBMakeSize(rect.size.width - 2 * self.clientBorder,
                                                 frameHeight - height - self.clientBorder));

    /*** synthetic event: coordinates must be in root space. ***/

    event.event = [clientWindow window];
    event.window = [clientWindow window];
    event.x = rect.position.x + self.clientBorder;
    event.y = rect.position.y + height;
    event.border_width = 0;
    event.width = clientRect.size.width;
    event.height = clientRect.size.height;
    event.override_redirect = 0;
    event.above_sibling = XCB_NONE;
    event.response_type = XCB_CONFIGURE_NOTIFY;
    event.sequence = 0;

    [connection sendEvent:(const char*) &event toClient:clientWindow propagate:NO];

    [clientWindow setWindowRect:clientRect];

    clientWindow = nil;
    settings = nil;
}

- (void)configureClientWithFramePosition:(XCBPoint)framePos
                              clientSize:(XCBSize)clientSize
{
    XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
    if (!clientWindow) return;

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHgt = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // Use the static helper with explicit dimensions (same as manual resize)
    sendSyntheticConfigureNotify([connection connection], clientWindow,
                                  framePos.x + self.clientBorder,
                                  framePos.y + titleHgt,
                                  clientSize.width,
                                  clientSize.height);

    clientWindow = nil;
    settings = nil;
}

- (void)programmaticResizeToRect:(XCBRect)targetRect
{
    XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
    XCBTitleBar *titleBar = (XCBTitleBar*)[self childWindowForKey:TitleBar];
    if (!clientWindow || !titleBar) return;

    // Enforce ICCCM / WM_NORMAL_HINTS: do not resize non-resizable (fixed-size) clients
    if (![clientWindow canResize]) {
        //NSLog(@"[XCBFrame] Refusing programmatic resize for non-resizable client %u", [clientWindow window]);
        return;
    }

    xcb_connection_t *conn = [connection connection];

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHgt = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // Calculate child window dimensions (same as manual resize functions)
    XCBRect titleBarRect = XCBMakeRect(XCBMakePoint(0, 0),
                                        XCBMakeSize(targetRect.size.width, titleHgt));
    // Client fills frame below titlebar with 1px border on left, right, and bottom
    XCBRect clientRect = XCBMakeRect(XCBMakePoint(1, titleHgt),
                                      XCBMakeSize(targetRect.size.width - 2,
                                                   targetRect.size.height - titleHgt - 1));

    // Configure frame window (position + size)
    uint32_t frameValues[4] = {(uint32_t)targetRect.position.x, (uint32_t)targetRect.position.y,
                               targetRect.size.width, targetRect.size.height};
    xcb_configure_window(conn, [self window],
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                         frameValues);

    // Configure titlebar window (size only, position relative to frame)
    uint32_t titleValues[2] = {titleBarRect.size.width, titleBarRect.size.height};
    xcb_configure_window(conn, [titleBar window],
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                         titleValues);

    // Configure client window (position + size relative to frame)
    uint32_t clientValues[4] = {(uint32_t)clientRect.position.x, (uint32_t)clientRect.position.y,
                                clientRect.size.width, clientRect.size.height};
    xcb_configure_window(conn, [clientWindow window],
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                         clientValues);

    // Flush immediately (critical - this is what manual resize does)
    xcb_flush(conn);

    // Update both windowRect AND originalRect for all windows (like manual resize)
    [self setWindowRect:targetRect];
    [self setOriginalRect:targetRect];

    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify with the calculated dimensions.
    // Coordinates must be in ROOT space (ICCCM): the client's absolute
    // position is the frame's origin plus its offset inside the frame.
    // Using client-relative coords here makes GNUstep believe the window
    // sits near the top-left of the screen (it interprets synthetic event
    // coords as root coords), and it would then remember that wrong frame
    // and restore it after close+reopen.
    sendSyntheticConfigureNotify(conn, clientWindow,
                                  targetRect.position.x + clientRect.position.x,
                                  targetRect.position.y + clientRect.position.y,
                                  clientRect.size.width,
                                  clientRect.size.height);

    settings = nil;
}

#pragma mark - WindowShade

// Height of a shaded frame: titlebar plus the bottom border strip so the
// rounded bottom edge stays visible.
- (uint16_t)shadedFrameHeight
{
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHgt = [settings heightDefined] ? [settings height] : [settings defaultHeight];
    settings = nil;
    return titleHgt + (uint16_t)self.clientBorder;
}

// Real geometry change for shading/unshading.  The client window is
// deliberately left mapped and untouched: X clips children to their parent,
// so the smaller frame simply hides it.  The client receives no
// ConfigureNotify and no Expose - unshading is a pure parent resize with
// zero redraw round-trips on the application side.
//
// Light variant used for every animation step: only the resize itself plus
// caches and the corner shape mask.
- (void)applyFrameHeight:(uint16_t)newHeight
{
    xcb_connection_t *conn = [connection connection];
    XCBRect rect = [self windowRect];

    uint32_t values[2] = {rect.size.width, newHeight};
    xcb_configure_window(conn,
                         [self window],
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                         values);

    XCBRect newRect = XCBMakeRect(rect.position, XCBMakeSize(rect.size.width, newHeight));
    [self setWindowRect:newRect];
    [self setOriginalRect:newRect];

    [self applyRoundedCornersShapeMask];

    xcb_flush(conn);
}

// Expensive tail work done once when a shade animation finishes: resize
// zones back in place and tell the compositor to re-acquire the pixmap.
 - (void)finishShadeGeometryChange
 {
     [self updateAllResizeZonePositions];

     // A peek roll-up just finished: the window is now fully collapsed, so
     // restore it to opaque.  (Kept translucent during the animation above.)
     if (self.restoreOpacityAfterShade)
     {
         [self setCompositeOpacity:1.0];
         self.restoreOpacityAfterShade = NO;
     }

     Class compositorClass = NSClassFromString(@"URSCompositingManager");
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)])
    {
        id<URSCompositorShadeAPI> compositor = [compositorClass performSelector:@selector(sharedManager)];
        if (compositor && [compositor respondsToSelector:@selector(invalidateWindowPixmap:)])
            [compositor invalidateWindowPixmap:[self window]];
        if (compositor && [compositor respondsToSelector:@selector(performRepairNow)])
            [compositor performRepairNow];
    }
}

// Roller-blind animation: step the REAL frame height through intermediate
// sizes so the untouched client content slides up under the titlebar (shade)
// or back down out of it (unshade).  Purely vertical by construction - X
// clipping does the visual work, no scaling involved - and the exact same
// motion plays in reverse for unshade.  Driven by an NSTimer on the main
// runloop (the same loop that already runs the scale-factor timer).
 - (void)animateFrameHeightFrom:(uint16_t)fromHeight toHeight:(uint16_t)toHeight
 {
     self.shadeAnimationInProgress = YES;

     // Interrupt any animation already in flight: a hover-peek can fire while
     // a roll-up/roll-down is still running, and we must seamlessly reverse it
     // instead of being dropped by a "busy" guard.
     if (self.shadeAnimTimer)
     {
         [self.shadeAnimTimer invalidate];
         self.shadeAnimTimer = nil;
     }

     if (fromHeight == toHeight)
     {
         self.shadeAnimationInProgress = NO;
         return;
     }

     __weak XCBFrame *weakSelf = self;
     NSTimeInterval duration = 0.22;
     NSDate *startDate = [NSDate date];

     NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                             repeats:YES
                                               block:^(NSTimer *stepTimer) {
         XCBFrame *strongSelf = weakSelf;
         if (!strongSelf)
         {
             [stepTimer invalidate];
             return;
         }

         NSTimeInterval elapsed = -1.0 * [startDate timeIntervalSinceNow];
         CGFloat progress = elapsed / duration;
         if (progress < 0.0)
             progress = 0.0;
         BOOL done = progress >= 1.0;
         if (!done)
             progress = 1.0 - (1.0 - progress) * (1.0 - progress);   // ease-out

         int delta = (int)toHeight - (int)fromHeight;
         uint16_t h = (uint16_t)((int)fromHeight + (int)(delta * progress));
         [strongSelf applyFrameHeight:h];

         if (done)
         {
             [stepTimer invalidate];
             strongSelf.shadeAnimTimer = nil;
             [strongSelf applyFrameHeight:toHeight];
             [strongSelf finishShadeGeometryChange];
             strongSelf.shadeAnimationInProgress = NO;
         }
     }];

     self.shadeAnimTimer = timer;
     [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
 }

// Publish the shaded flag through _NET_WM_STATE on the client window.
- (void)setShadeFlags:(BOOL)flag
{
    [self setShaded:flag];

    XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
    if (!clientWindow)
        return;

    [clientWindow setShaded:flag];

    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    [ewmhService updateNetWmState:clientWindow];
    ewmhService = nil;
}

 - (void)shade
 {
     // Shade happens ONLY on an explicit double-click or a _NET_WM_STATE_SHADED
     // request; single clicks take the normal focus/drag path and never reach
     // this method.
     // Allowed even mid-animation so a hover-peek can reverse a roll-up that is
     // still in flight; the in-progress animation is cancelled by
     // animateFrameHeightFrom:.  Already-shaded-and-idle is the only no-op.
     if (([self shaded] && !self.shadeAnimationInProgress) || [self isMinimized])
         return;

     XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
     if (!clientWindow)
         return;

    XCBRect startRect = [self windowRect];
    uint16_t targetHeight = [self shadedFrameHeight];
    if (startRect.size.height <= targetHeight)
    {
        // The window is already at (or below) the shaded height.  When a
        // hover-peek ends before the unshade roll-down has grown the window,
        // shade is called while the unshade animation is still in flight.  We
        // must NOT early-return here or that in-flight unshade keeps running and
        // the window ends up permanently unshaded.  Fall through (guarded by
        // the animation being in progress) so animateFrameHeightFrom: cancels
        // the unshade and the opacity is restored by the shade-completion path.
        if (!self.shadeAnimationInProgress)
        {
            if (self.restoreOpacityAfterShade)
            {
                [self setCompositeOpacity:1.0];
                self.restoreOpacityAfterShade = NO;
            }
            return;
        }
    }

     // Restore source for unshade.  Shading a maximized window saving the
     // maximized rect is exactly right: unshade brings the maximized size back.
     // Preserve an existing saved rect when we are interrupting an unshade
     // animation, otherwise the window would only roll back to the mid-animation
     // height instead of its full size.
     if (!self.shadeAnimationInProgress)
         [self setOldRect:startRect];

     // Flag first, so a second double-click during the animation is answered
     // by unshade instead of queueing up a second shade.
     [self setShadeFlags:YES];

     // Disabled vertical resize also means no resize cursor while shaded.
     [self updateResizeCursorForShadedState];

     uint16_t fromHeight = startRect.size.height;
     [self animateFrameHeightFrom:fromHeight toHeight:targetHeight];

     // If the roll-up completed with no animation (already at shaded height),
     // restore opacity here; otherwise the animation completion does it.
     if (!self.shadeAnimationInProgress && self.restoreOpacityAfterShade)
     {
         [self setCompositeOpacity:1.0];
         self.restoreOpacityAfterShade = NO;
     }
 }

 - (void)unshade
 {
     if ([self isMinimized])
         return;
     // Allowed mid-animation (interrupting a roll-up) so a hover-peek can roll
     // back down even while the window is still collapsing.  Only an already
     // unshaded-and-idle window is a no-op.
     if (![self shaded] && !self.shadeAnimationInProgress)
         return;

     XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
     if (!clientWindow)
         return;

    uint16_t targetHeight = [self shadedFrameHeight];
    XCBRect fullRect = [self oldRect];

    if (!FnCheckXCBRectIsValid(fullRect) ||
        fullRect.size.width == 0 ||
        fullRect.size.height <= targetHeight)
    {
        // No usable saved geometry - just clear the state.
        [self setShadeFlags:NO];
        [self updateResizeCursorForShadedState];
        return;
    }

    // Render the window's CURRENT contents into the compositor's pixmap
    // BEFORE rolling the shade open.  While shaded the frame was clipped
    // shut but the client stayed mapped and redirected, so a fresh pixmap
    // capture now hands the compositor the up-to-date content to reveal.
    // Doing this up front avoids a one-frame artifact on the very first
    // animation step: applyFrameHeight: frees the composite picture, and
    // without a render here that freed picture would be composited before
    // it is recreated for the new (taller) frame.
    [self paintContentBeforeShadeRoll];

    // Same motion in reverse: roll back down out of the titlebar.
    [self setShadeFlags:NO];

    // Resize is enabled again: restore the resize cursors on the zones/handle.
    [self updateResizeCursorForShadedState];

    [self animateFrameHeightFrom:[self windowRect].size.height
                        toHeight:fullRect.size.height];
}

// Re-acquire and paint the frame's current content immediately (no animation).
// Used by unshade to guarantee fresh content before the roll-out step that
// frees and recreates the composite picture.
- (void)paintContentBeforeShadeRoll
{
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    if (!compositorClass || ![compositorClass respondsToSelector:@selector(sharedManager)])
        return;

    id<URSCompositorShadeAPI> compositor = [compositorClass performSelector:@selector(sharedManager)];
    if (!compositor)
        return;

    if ([compositor respondsToSelector:@selector(invalidateWindowPixmap:)])
        [compositor invalidateWindowPixmap:[self window]];
    if ([compositor respondsToSelector:@selector(performRepairNow)])
        [compositor performRepairNow];
}

- (void)toggleShade
{
    // A hover-peek leaves the window unshaded but flagged peeking; a
    // double-click should keep it open at full opacity rather than collapse.
    if (self.peeking) {
        self.peeking = NO;
        [self setCompositeOpacity:1.0];
        return;
    }
    if ([self shaded])
        [self unshade];
    else
        [self shade];
}

#pragma mark - Hover-peek (shaded window preview)

// Roll a shaded window down at reduced opacity while the pointer is on its
// titlebar.  Suppressed until the pointer re-enters the window after a
// peek ended by moving into the content (avoids collapse/expand flicker).
 - (void)beginHoverPeek
 {
     if (![self shaded] || self.peeking ||
         [self isMinimized] || !self.hoverPeekArmed)
         return;

     // Swallow any enter that arrives within the roll-up window after a peek
     // ended (or a synthetic EnterNotify our own collapse generates): otherwise
     // the window re-opens and stays put.  A genuine re-hover after the window
     // has settled will arrive later and is allowed.
     NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
     if (self.peekEndTime > 0 && (now - self.peekEndTime) < 0.30)
         return;

     // Capture whether the activity spinner was already spinning before this
     // peek.  A temporary rolldown must never start the spinner from cold - it
     // only keeps a spinner that was already running (as if still rolled up).
     self.peekSpinnerWasActive = self.lastContentChange > 0 &&
                                 (now - self.lastContentChange) < 2.0;

     // A new peek cancels any pending opacity restore from a previous roll-up.
     self.restoreOpacityAfterShade = NO;

     self.peeking = YES;
     [self setCompositeOpacity:0.66];
     [self unshade];
 }

 - (void)endHoverPeek
 {
      if (!self.peeking)
          return;

      // Arm the opacity-restore flag first so the roll-up animation is covered
      // by the noteContentChanged suppression below (keeps the spinner frozen).
      self.restoreOpacityAfterShade = YES;

      self.peeking = NO;

     // Remember when the peek ended so a synthetic/duplicate EnterNotify that
     // arrives within the roll-up window (or any too-rapid re-hover) is ignored,
     // preventing the window from getting stuck open.
     self.peekEndTime = [NSDate timeIntervalSinceReferenceDate];

     // If the pointer slid from the titlebar into the now-revealed content the
     // window would immediately re-peek (and flicker).  Disarm until the pointer
     // actually leaves the window; handleLeaveNotify re-arms via hoverPeekArmed.
     self.hoverPeekArmed = NO;
     [self shade];
 }

- (void)setCompositeOpacity:(CGFloat)opacity
{
    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    if (!compositorClass || ![compositorClass respondsToSelector:@selector(sharedManager)])
        return;

    id<URSCompositorShadeAPI> compositor = [compositorClass performSelector:@selector(sharedManager)];
    if (!compositor || ![compositor respondsToSelector:@selector(setWindowOpacity:forWindow:)])
        return;

    // The frame (WM decoration / titlebar) and the client (window content)
    // are separate composited windows; both must be made translucent so the
    // whole rolldown reads as one semi-transparent surface.
    [compositor setWindowOpacity:opacity forWindow:[self window]];
    XCBWindow *client = [self childWindowForKey:ClientWindow];
    if (client)
        [compositor setWindowOpacity:opacity forWindow:[client window]];
}

#pragma mark - Content Activity (spinner driver)

NSString *URSWindowTitleContentChangedNotification = @"URSWindowTitleContentChangedNotification";

static const NSTimeInterval URSWindowTitleActivityWindow = 2.0;

// Called from the compositor's damage path for every damaged client
// surface.  Must stay cheap: a timestamp write, plus one notification only
// on the idle-to-active transition.  Activity is sampled at most every 100ms -
// the spinner ticks at 100ms, so finer resolution is wasted work and a busy
// terminal can emit hundreds of damage events per second.
 - (void)noteContentChanged
 {
     // A hover-peek (and its roll-up) must never start the titlebar spinner
     // from cold.  The peek's own reveal repaint and the unshade/roll-up
     // animations generate client damage that would otherwise bump the
     // activity timestamp and make the spinner spin after the peek, even
     // though it was idle before.  Freeze the timestamp while a peek or its
     // roll-up is in flight so the spinner state is unchanged across the peek.
     if (self.peeking || self.restoreOpacityAfterShade)
         return;

     NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (_lastContentChange > 0 && (now - _lastContentChange) < 0.1)
        return;

    BOOL wasIdle = (_lastContentChange <= 0) ||
                   (now - _lastContentChange >= URSWindowTitleActivityWindow);
    _lastContentChange = now;

    if (wasIdle)
    {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:URSWindowTitleContentChangedNotification
                          object:self];
    }
}

- (MousePosition) mouseIsOnWindowBorderForEvent:(xcb_motion_notify_event_t *)anEvent
{
    int rightBorder = [super windowRect].size.width;
    int bottomBorder = [super windowRect].size.height;
    int leftBorder = [super windowRect].position.x;
    int topBorder = [super windowRect].position.y;
    MousePosition position = None;

    if (rightBorder == anEvent->event_x || (rightBorder - 3) < anEvent->event_x)
    {
        position = RightBorder;
    }


    if (bottomBorder == anEvent->event_y || (bottomBorder - 3) < anEvent->event_y)
    {
        position = BottomBorder;
    }

    if ((bottomBorder == anEvent->event_y || (bottomBorder - 3) < anEvent->event_y) &&
        (rightBorder == anEvent->event_x || (rightBorder - 3) < anEvent->event_x))
    {
        position = BottomRightCorner;
    }

    if (leftBorder == anEvent->root_x || (leftBorder + 3) > anEvent->root_x)
    {
        position = LeftBorder;
    }

    if (topBorder == anEvent->root_y || (topBorder + 3) > anEvent->root_y)
    {
        position = TopBorder;
    }

    // Top-left corner
    if ((topBorder == anEvent->root_y || (topBorder + 3) > anEvent->root_y) &&
        (leftBorder == anEvent->root_x || (leftBorder + 3) > anEvent->root_x))
    {
        position = TopLeftCorner;
    }

    // Top-right corner
    if ((topBorder == anEvent->root_y || (topBorder + 3) > anEvent->root_y) &&
        (rightBorder == anEvent->event_x || (rightBorder - 3) < anEvent->event_x))
    {
        position = TopRightCorner;
    }

    // Bottom-left corner
    if ((bottomBorder == anEvent->event_y || (bottomBorder - 3) < anEvent->event_y) &&
        (leftBorder == anEvent->root_x || (leftBorder + 3) > anEvent->root_x))
    {
        position = BottomLeftCorner;
    }

    return position;

}

- (void) restoreDimensionAndPosition
{
    XCBWindow *clientWindow = [self childWindowForKey:ClientWindow];
    XCBTitleBar *titleBar = (XCBTitleBar*)[self childWindowForKey:TitleBar];

    [super restoreDimensionAndPosition];
    [clientWindow restoreDimensionAndPosition];
    [titleBar restoreDimensionAndPosition];
    [titleBar drawTitleBarComponents];

    clientWindow = nil;
    titleBar = nil;
}


/********************************
 *                               *
 *            ACCESSORS          *
 *                               *
 ********************************/

- (void)setChildren:(NSMutableDictionary *)aChildrenSet
{
    children = aChildrenSet;
}

-(NSMutableDictionary*) getChildren
{
    return children;
}

- (void) dealloc
{
    [children removeAllObjects]; //not needed probably
    children = nil;
}


@end
