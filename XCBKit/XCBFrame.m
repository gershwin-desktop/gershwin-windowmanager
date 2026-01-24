//
//  XCBFrame.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 05/08/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBFrame.h"
#import "functions/Transformers.h"
#import "services/ICCCMService.h"
#import "services/TitleBarSettingsService.h"
#import "utils/CairoDrawer.h"
#import "utils/XCBShape.h"
#import <AppKit/NSScroller.h>
#import <GNUstepGUI/GSTheme.h>

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
// Per ICCCM 4.1.5, reparented windows need synthetic ConfigureNotify events
// This inline version avoids X server round-trips for better performance
static void sendSyntheticConfigureNotify(xcb_connection_t *conn,
                                          XCBWindow *clientWindow,
                                          int16_t rootX,
                                          int16_t rootY,
                                          uint16_t width,
                                          uint16_t height)
{
    xcb_configure_notify_event_t event;
    memset(&event, 0, sizeof(event));
    event.response_type = XCB_CONFIGURE_NOTIFY;
    event.event = [clientWindow window];
    event.window = [clientWindow window];
    event.x = rootX;
    event.y = rootY;
    event.width = width;
    event.height = height;
    event.border_width = 0;
    event.above_sibling = XCB_NONE;
    event.override_redirect = 0;

    xcb_send_event(conn, 0, [clientWindow window],
                   XCB_EVENT_MASK_STRUCTURE_NOTIFY, (const char *)&event);
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
    /*** checks normal hints for client window **/
    [connection setIsWindowsMapUpdated:NO];
    
    ICCCMService* icccmService = [ICCCMService sharedInstanceWithConnection:connection];
    xcb_size_hints_t *sizeHints = [icccmService wmNormalHintsForWindow:aClientWindow];

    [self setMinHeightHint:sizeHints->min_height];
    [self setMinWidthHint:sizeHints->min_width];


    if (minWidthHint > [aClientWindow windowRect].size.width)
    {
        XCBRect rect = XCBMakeRect(XCBMakePoint(0,0), XCBMakeSize(minWidthHint, [aClientWindow windowRect].size.height));
        [aClientWindow setWindowRect:rect];
        [aClientWindow setOriginalRect:rect];
        rect.size.width = rect.size.width + 1;
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
        rect.size.height = rect.size.height + 21;
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

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    titleHeight = [settings heightDefined] ? [settings height] : [settings defaultHeight];

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

    uint32_t values[2];
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;

    values[0] = [scr screen]->white_pixel;
    values[1] = TITLE_MASK_VALUES;

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];

    uint16_t height = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    XCBCreateWindowTypeRequest* request = [[XCBCreateWindowTypeRequest alloc] initForWindowType:XCBTitleBarRequest];
    [request setDepth:XCB_COPY_FROM_PARENT];
    [request setParentWindow:self];
    [request setXPosition:0];
    [request setYPosition:0];
    [request setWidth:[self windowRect].size.width];
    [request setHeight:height];
    [request setBorderWidth:0];
    [request setXcbClass:XCB_WINDOW_CLASS_INPUT_OUTPUT];
    [request setVisual:rootVisual];
    [request setValueMask:mask];
    [request setValueList:values];

    XCBWindowTypeResponse* response = [[super connection] createWindowForRequest:request registerWindow:YES];
    XCBTitleBar *titleBar = [response titleBar];

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
        NSLog(@"Window title: %s, len: %d", value, len);
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
    
    // OPTIMIZATION: Only create pixmaps - skip Cairo drawing if GSTheme will override
    // GSTheme integration in URSHybridEventHandler will render the titlebar contents
    // Creating pixmaps is still needed as GSTheme renders to them
    [titleBar createPixmap];
    
    // OPTIMIZATION: Skip button generation and Cairo drawing when GSTheme is active
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

    // Position client window directly below titlebar with no gap
    XCBPoint position = XCBMakePoint(0, height);
    [connection reparentWindow:clientWindow toWindow:self position:position];
    [connection mapWindow:clientWindow];
    uint32_t border[] = {0};
    // Ensure no borders on frame window
    xcb_configure_window([connection connection], window, XCB_CONFIG_WINDOW_BORDER_WIDTH, border);
    // Ensure no borders on client window
    xcb_configure_window([connection connection], [clientWindow window], XCB_CONFIG_WINDOW_BORDER_WIDTH, border);
    
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

    // Get diagonal resize cursor (bottom-right)
    xcb_cursor_t resizeCursor = [[self cursor] selectResizeCursorForPosition:BottomRightCorner];

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

- (void) resize:(xcb_motion_notify_event_t *)anEvent xcbConnection:(xcb_connection_t*)aXcbConnection
{

    /*** width ***/

    if (rightBorderClicked && !bottomBorderClicked && !leftBorderClicked && !topBorderClicked)
    {
        resizeFromRightForEvent(anEvent, aXcbConnection, self, minWidthHint);
    }

    if (leftBorderClicked && !bottomBorderClicked && !rightBorderClicked && !topBorderClicked)
    {
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint);
    }


    /** height **/

    if (bottomBorderClicked && !rightBorderClicked && !leftBorderClicked)
    {
        resizeFromBottomForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight);
    }


    if (topBorderClicked && !rightBorderClicked && !leftBorderClicked && !bottomBorderClicked)
    {
        resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight);
    }


    /** width and height - corner resizes **/

    // SE corner (bottom-right)
    if (rightBorderClicked && bottomBorderClicked && !leftBorderClicked && !topBorderClicked)
    {
        resizeFromAngleForEvent(anEvent, aXcbConnection, self, minWidthHint, minHeightHint, titleHeight);
    }

    // NW corner (top-left) - combine top and left resizes
    if (topBorderClicked && leftBorderClicked && !rightBorderClicked && !bottomBorderClicked)
    {
        resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight);
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint);
    }

    // NE corner (top-right) - combine top and right resizes
    if (topBorderClicked && rightBorderClicked && !leftBorderClicked && !bottomBorderClicked)
    {
        resizeFromTopForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight);
        resizeFromRightForEvent(anEvent, aXcbConnection, self, minWidthHint);
    }

    // SW corner (bottom-left) - combine bottom and left resizes
    if (bottomBorderClicked && leftBorderClicked && !rightBorderClicked && !topBorderClicked)
    {
        resizeFromBottomForEvent(anEvent, aXcbConnection, self, minHeightHint, titleHeight);
        resizeFromLeftForEvent(anEvent, aXcbConnection, self, minWidthHint);
    }

    // Update resize zone positions if they exist
    [self updateAllResizeZonePositions];

    // Update shape mask for rounded corners (must match new window dimensions)
    [self applyRoundedCornersShapeMask];

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

    // Get appropriate resize cursor for this position
    xcb_cursor_t resizeCursor = [[self cursor] selectResizeCursorForPosition:position];

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

    if (topRadius > 0 || bottomRadius > 0) {
        XCBShape *shape = [[XCBShape alloc] initWithConnection:connection withWinId:window];
        if ([shape checkSupported]) {
            XCBGeometryReply *geometry = [self geometries];
            [shape calculateDimensionsFromGeometries:geometry];
            [shape createPixmapsAndGCs];
            [shape createRoundedCornersWithTopRadius:(int)topRadius bottomRadius:(int)bottomRadius];
        }
    }
}

void resizeFromRightForEvent(xcb_motion_notify_event_t *anEvent,
                             xcb_connection_t *connection,
                             XCBFrame* frame,
                             int minW)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
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

    uint32_t values[] = {newWidth};

    if (frameRect.size.width <= minW && anEvent->event_x < minW)
    {
        frameRect.size.width = minW;
        titleBarRect.size.width = minW;
        clientRect.size.width = minW;
        values[0] = minW;
        xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH, &values);
        xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, &values);
        xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH, &values);

        [frame setWindowRect:frameRect];
        [frame setOriginalRect:frameRect];

        [titleBar setWindowRect:titleBarRect];
        [titleBar setOriginalRect:titleBarRect];

        [clientWindow setWindowRect:clientRect];
        [clientWindow setOriginalRect:clientRect];
        //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

        // Send synthetic ConfigureNotify to client
        sendSyntheticConfigureNotify(connection, clientWindow,
                                      frameRect.position.x,
                                      frameRect.position.y + [frame titleHeight],
                                      clientRect.size.width,
                                      clientRect.size.height);

        clientWindow = nil;
        titleBar = nil;
        connection = NULL;
        return;
    }

    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH, &values);
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, &values);
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH, &values);

    // Flush to ensure smooth resizing updates
    xcb_flush(connection);

    frameRect.size.width = anEvent->event_x;

    [frame setWindowRect:frameRect];
    [frame setOriginalRect:frameRect];

    titleBarRect.size.width = anEvent->event_x;
    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    clientRect.size.width = anEvent->event_x;
    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];
    //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  frameRect.position.x,
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
                            int minW)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
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
    uint32_t values[] = {newX, xDelta + rect.size.width};

    if (rect.size.width <= minW && anEvent->root_x > rect.position.x)
    {
        // When hitting minimum width, maintain the right edge position
        // Calculate the correct left position to preserve right edge
        int rightEdge = rect.position.x + rect.size.width;
        int newX = rightEdge - minW;

        rect.size.width = minW;
        rect.position.x = newX;
        titleBarRect.size.width = minW;
        titleBarRect.position.x = 0; // Relative to frame
        clientRect.size.width = minW;
        clientRect.position.x = 0; // Relative to frame

        values[0] = newX;
        values[1] = minW;
        xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);
        values[0] = 0;
        xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);
        xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);

        [frame setWindowRect:rect];
        [frame setOriginalRect:rect];

        titleBarRect.position.x = values[0];
        titleBarRect.size.width = values[1];
        [titleBar setWindowRect:titleBarRect];
        [titleBar setOriginalRect:titleBarRect];

        clientRect.position.x = values[0];
        clientRect.size.width = values[1];
        [clientWindow setWindowRect:clientRect];
        [clientWindow setOriginalRect:clientRect];
        //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

        // Send synthetic ConfigureNotify to client
        sendSyntheticConfigureNotify(connection, clientWindow,
                                      rect.position.x,
                                      rect.position.y + [frame titleHeight],
                                      clientRect.size.width,
                                      clientRect.size.height);

        clientWindow = nil;
        titleBar = nil;
        connection = NULL;
        return;
    }


    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);
    rect.position.x = values[0];
    rect.size.width = values[1];
    values[0] = 0;
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH, &values);

    // Flush to ensure smooth resizing updates
    xcb_flush(connection);

    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    titleBarRect.position.x = values[0];
    titleBarRect.size.width = values[1];
    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    clientRect.position.x = values[0];
    clientRect.size.width = values[1];
    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];
    //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x,
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
                              uint16_t titleBarHeight)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
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

    uint32_t values[] = {anEvent->event_y};

    if (rect.size.height <= minH + titleBarHeight && anEvent->event_y < minH)
    {
        rect.size.height = minH + titleBarHeight;
        clientRect.size.height = minH;
        values[0] = clientRect.size.height;
        xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_HEIGHT, &values);
        values[0] = rect.size.height;
        xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_HEIGHT, &values);

        [frame setWindowRect:rect];
        [frame setOriginalRect:rect];

        [clientWindow setWindowRect:clientRect];
        [clientWindow setOriginalRect:clientRect];

        // Send synthetic ConfigureNotify to client
        sendSyntheticConfigureNotify(connection, clientWindow,
                                      rect.position.x,
                                      rect.position.y + titleBarHeight,
                                      clientRect.size.width,
                                      clientRect.size.height);

        clientWindow = nil;
        connection = NULL;
        return;
    }

    values[0] = anEvent->event_y - titleBarHeight;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_HEIGHT, &values);
    clientRect.size.height = values[0];
    values[0] = anEvent->event_y;
    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_HEIGHT, &values);

    // Flush to ensure smooth resizing updates
    xcb_flush(connection);

    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];


    rect.size.height = values[0];
    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x,
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
                           uint16_t titleBarHeight)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
    //xcb_connection_t *connection = [[frame connection] connection];

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

    int yDelta = rect.position.y - newY;

    uint32_t values[] = {newY, yDelta + rect.size.height};

    if (rect.size.height <= minH + titleBarHeight && anEvent->root_y > rect.position.y)
    {
        // When hitting minimum height, maintain the bottom edge position
        // Calculate the correct top position to preserve bottom edge
        int bottomEdge = rect.position.y + rect.size.height;
        int newY = bottomEdge - (minH + titleBarHeight + 2);  // +2 for top and bottom borders

        rect.size.height = minH + titleBarHeight + 2;  // +2 for borders
        rect.position.y = newY;
        clientRect.size.height = minH;
        clientRect.position.y = 1 + titleBarHeight;  // Inside top border + titlebar

        values[0] = clientRect.position.y;
        values[1] = clientRect.size.height;
        xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, &values);

        values[0] = newY;
        values[1] = rect.size.height;
        xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, &values);


        [frame setWindowRect:rect];
        [frame setOriginalRect:rect];

        [clientWindow setWindowRect:clientRect];
        [clientWindow setOriginalRect:clientRect];

        // Send synthetic ConfigureNotify to client
        sendSyntheticConfigureNotify(connection, clientWindow,
                                      rect.position.x,
                                      rect.position.y + titleBarHeight,
                                      clientRect.size.width,
                                      clientRect.size.height);

        titleBar = nil;
        clientWindow = nil;
        connection = NULL;

        return;
    }

    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, &values);

    rect.position.y = values[0];
    rect.size.height = values[1];
    values[0] = 1;  // Inside top border

    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_Y, &values);

    titleBarRect.position.y = values[0];

    values[0] = 1 + titleBarHeight;  // Inside top border + titlebar height
    values[1] = rect.size.height - titleBarHeight;  // Subtract titlebar height only

    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_Y | XCB_CONFIG_WINDOW_HEIGHT, &values);
    clientRect.size.height = values[1];
    
    // Flush to ensure smooth resizing updates
    xcb_flush(connection);

    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];

    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];


    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x,
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
                             uint16_t titleBarHeight)
{
    XCBWindow* clientWindow = [frame childWindowForKey:ClientWindow];
    XCBTitleBar* titleBar = (XCBTitleBar*)[frame childWindowForKey:TitleBar];
    //xcb_connection_t *connection = [[frame connection] connection];

    XCBRect rect = [frame windowRect];
    XCBRect titleBarRect = [titleBar windowRect];
    XCBRect clientRect = [clientWindow windowRect];

    uint32_t values[] = {anEvent->event_x, anEvent->event_y};

    if (rect.size.width <= minW && anEvent->event_x < minW &&
        rect.size.height <= minH + titleBarHeight && anEvent->event_y < minH)
    {
        rect.size.width = minW;
        titleBarRect.size.width = minW;
        clientRect.size.width = minW;

        rect.size.height = minH + titleBarHeight;
        clientRect.size.height = minH;

        values[0] = rect.size.width;
        values[1] = rect.size.height;

        xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, &values);
        values[0] = titleBarRect.size.width;
        xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, &values);
        values[0] = clientRect.size.width;
        values[1] = clientRect.size.height;
        xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, &values);

        [frame setWindowRect:rect];
        [frame setOriginalRect:rect];

        [titleBar setWindowRect:titleBarRect];
        [titleBar setOriginalRect:titleBarRect];

        [clientWindow setWindowRect:clientRect];
        [clientWindow setOriginalRect:clientRect];
        //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

        // Send synthetic ConfigureNotify to client
        sendSyntheticConfigureNotify(connection, clientWindow,
                                      rect.position.x,
                                      rect.position.y + titleBarHeight,
                                      clientRect.size.width,
                                      clientRect.size.height);

        titleBar = nil;
        clientWindow = nil;
        connection = NULL;

        return;
    }

    xcb_configure_window(connection, [frame window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, &values);
    xcb_configure_window(connection, [titleBar window], XCB_CONFIG_WINDOW_WIDTH, &values);
    values[1] = values[1] - titleBarHeight;
    xcb_configure_window(connection, [clientWindow window], XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, &values);
    
    // Flush to ensure smooth resizing updates
    xcb_flush(connection);

    rect.size.width = anEvent->event_x;
    rect.size.height = anEvent->event_y;
    [frame setWindowRect:rect];
    [frame setOriginalRect:rect];


    titleBarRect.size.width = anEvent->event_x;
    [titleBar setWindowRect:titleBarRect];
    [titleBar setOriginalRect:titleBarRect];

    clientRect.size.width = anEvent->event_x;
    clientRect.size.height = values[1];
    [clientWindow setWindowRect:clientRect];
    [clientWindow setOriginalRect:clientRect];
    //[titleBar drawTitleBarComponentsForColor:TitleBarUpColor];

    // Send synthetic ConfigureNotify to client
    sendSyntheticConfigureNotify(connection, clientWindow,
                                  rect.position.x,
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

    uint32_t values[] = {(uint32_t)pos.x, (uint32_t)pos.y};
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
    XCBRect rect = [[self geometries] rect];
    XCBRect clientRect = [clientWindow rectFromGeometries];
    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t height = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    /*** synthetic event: coordinates must be in root space. ***/

    event.event = [clientWindow window];
    event.window = [clientWindow window];
    event.x = rect.position.x;
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
                                  framePos.x,
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

    xcb_connection_t *conn = [connection connection];

    TitleBarSettingsService *settings = [TitleBarSettingsService sharedInstance];
    uint16_t titleHgt = [settings heightDefined] ? [settings height] : [settings defaultHeight];

    // Calculate child window dimensions (same as manual resize functions)
    XCBRect titleBarRect = XCBMakeRect(XCBMakePoint(0, 0),
                                        XCBMakeSize(targetRect.size.width, titleHgt));
    XCBRect clientRect = XCBMakeRect(XCBMakePoint(0, titleHgt - 1),
                                      XCBMakeSize(targetRect.size.width,
                                                   targetRect.size.height - titleHgt));

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

    // Send synthetic ConfigureNotify with the calculated dimensions
    sendSyntheticConfigureNotify(conn, clientWindow,
                                  targetRect.position.x,
                                  targetRect.position.y + titleHgt,
                                  clientRect.size.width,
                                  clientRect.size.height);

    settings = nil;
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
