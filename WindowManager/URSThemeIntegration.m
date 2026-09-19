//
//  URSThemeIntegration.m
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Implementation of GSTheme window decoration rendering for X11 titlebars.
//

#import "URSThemeIntegration.h"
#import "URSProfiler.h"
#import "URSRenderingContext.h"
#import "URSCompositingManager.h"
#import "XCBConnection.h"
#import "XCBFrame.h"
#import "XCBScreen.h"
#import <objc/runtime.h>
#import <math.h>
#import "GSThemeTitleBar.h"
#import "ICCCMService.h"

// From libs-back: the flag telling that _GNUSTEP_WM_ATTR carries a style mask.
#define GSWindowStyleAttr (1 << 0)

// Category to expose private GSTheme methods for theme-agnostic titlebar rendering
// These methods exist in GSTheme but aren't in the public header
@interface GSTheme (URSPrivateMethods)
- (void)drawTitleBarRect:(NSRect)titleBarRect
            forStyleMask:(unsigned int)styleMask
                   state:(int)inputState
                andTitle:(NSString*)title;
@end

@interface GSTheme (URSThemeCornerRadius)
- (CGFloat)titlebarCornerRadius;
@end

// Implemented by themes that draw and lay out their own titlebar buttons (Eau)
@interface GSTheme (URSThemeTitlebarButtons)
- (BOOL)drawsTitlebarButtons;
- (NSRect)titlebarButtonRectForButton:(NSInteger)button
                        titlebarWidth:(CGFloat)width
                            styleMask:(NSUInteger)styleMask;
@end

// Implemented by themes that draw their own window border
@interface GSTheme (URSThemeWindowFrame)
- (CGFloat)windowFrameBorderWidth;
- (NSColor *)windowFrameBorderColorAtDepth:(NSInteger)depth
                                      edge:(NSInteger)edge
                                    active:(BOOL)active;
@end

// What the border of one frame needs between paints: the state it was last
// painted with, so an expose can repeat it without asking who has focus, and
// the graphics context it is painted through, which belongs to the frame
// because a frame may be an ARGB window while another is not.
@interface URSFrameBorder : NSObject
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) xcb_gcontext_t gc;
@end

@implementation URSFrameBorder
@end

@implementation URSThemeIntegration

static URSThemeIntegration *sharedInstance = nil;
static NSMutableSet *fixedSizeWindows = nil;

// Hover state tracking for titlebar buttons
static xcb_window_t hoveredTitlebarWindow = 0;
static NSInteger hoveredButtonIndex = -1;  // -1=none, 0=close, 1=mini, 2=zoom

// Edge button metrics: buttons are square, width equals titlebar height (queried at render time)
// Declared early so they can be used in hover state methods
// Multiplied by GSScaleFactor for HiDPI support (lazily computed).
static CGFloat _wmScaleFactor = 0;
static CGFloat WMScaleFactor(void) {
    if (_wmScaleFactor == 0) {
        _wmScaleFactor = [[NSUserDefaults standardUserDefaults] floatForKey:@"GSScaleFactor"];
        if (_wmScaleFactor == 0)
            _wmScaleFactor = [[NSScreen mainScreen] backingScaleFactor];
        if (_wmScaleFactor == 0) _wmScaleFactor = 1.0;
    }
    return _wmScaleFactor;
}
+ (void)invalidateScaleFactorCache {
    _wmScaleFactor = 0;
}
#define ICON_STROKE (1.5 * WMScaleFactor())     // Subtle icon strokes
#define ICON_INSET (8.0 * WMScaleFactor())      // Icon inset from button edges (matches Eau theme)

#pragma mark - Fixed-size window tracking

+ (void)initialize {
    if (self == [URSThemeIntegration class]) {
        fixedSizeWindows = [[NSMutableSet alloc] init];
    }
}

#pragma mark - ARGB Visual Support for Compositor Alpha

// Find 32-bit ARGB visual for alpha transparency support
// Returns 0 if no ARGB visual is found
+ (xcb_visualid_t)findARGBVisualForScreen:(XCBScreen *)screen connection:(XCBConnection *)connection {
    if (!screen || !connection) return 0;

    xcb_screen_t *xcbScreen = [screen screen];
    if (!xcbScreen) return 0;

    // Iterate through all depths and visuals to find a 32-bit TrueColor visual
    xcb_depth_iterator_t depth_iter = xcb_screen_allowed_depths_iterator(xcbScreen);

    for (; depth_iter.rem; xcb_depth_next(&depth_iter)) {
        if (depth_iter.data->depth != 32) continue;

        xcb_visualtype_iterator_t visual_iter = xcb_depth_visuals_iterator(depth_iter.data);

        for (; visual_iter.rem; xcb_visualtype_next(&visual_iter)) {
            xcb_visualtype_t *visual = visual_iter.data;

            // Look for TrueColor with 8-bit alpha channel
            // TrueColor class is 4, DirectColor is 5
            if (visual->_class == XCB_VISUAL_CLASS_TRUE_COLOR) {
                // Check that it has reasonable bit masks for ARGB
                // 32-bit visuals typically have 8 bits per channel
                //NSLog(@"[URSThemeIntegration] Found 32-bit TrueColor visual: 0x%x", visual->visual_id);
                return visual->visual_id;
            }
        }
    }

    //NSLog(@"[URSThemeIntegration] No 32-bit ARGB visual found");
    return 0;
}

// Get xcb_visualtype_t for a given visual ID
+ (xcb_visualtype_t *)findVisualTypeForId:(xcb_visualid_t)visualId screen:(XCBScreen *)screen {
    if (!screen || visualId == 0) return NULL;

    xcb_screen_t *xcbScreen = [screen screen];
    if (!xcbScreen) return NULL;

    xcb_depth_iterator_t depth_iter = xcb_screen_allowed_depths_iterator(xcbScreen);

    for (; depth_iter.rem; xcb_depth_next(&depth_iter)) {
        xcb_visualtype_iterator_t visual_iter = xcb_depth_visuals_iterator(depth_iter.data);

        for (; visual_iter.rem; xcb_visualtype_next(&visual_iter)) {
            if (visual_iter.data->visual_id == visualId) {
                return visual_iter.data;
            }
        }
    }

    return NULL;
}

+ (void)registerFixedSizeWindow:(xcb_window_t)windowId {
    @synchronized(fixedSizeWindows) {
        [fixedSizeWindows addObject:@(windowId)];
        //NSLog(@"Registered fixed-size window %u (total: %lu)", windowId, (unsigned long)[fixedSizeWindows count]);
    }
}

+ (void)unregisterFixedSizeWindow:(xcb_window_t)windowId {
    @synchronized(fixedSizeWindows) {
        [fixedSizeWindows removeObject:@(windowId)];
        //NSLog(@"Unregistered fixed-size window %u", windowId);
    }
}

+ (BOOL)isFixedSizeWindow:(xcb_window_t)windowId {
    @synchronized(fixedSizeWindows) {
        return [fixedSizeWindows containsObject:@(windowId)];
    }
}

#pragma mark - Hover State Tracking

+ (xcb_window_t)hoveredTitlebarWindow {
    return hoveredTitlebarWindow;
}

+ (NSInteger)hoveredButtonIndex {
    return hoveredButtonIndex;
}

+ (void)setHoveredTitlebar:(xcb_window_t)titlebarId buttonIndex:(NSInteger)buttonIdx {
    hoveredTitlebarWindow = titlebarId;
    hoveredButtonIndex = buttonIdx;
}

+ (void)clearHoverState {
    hoveredTitlebarWindow = 0;
    hoveredButtonIndex = -1;
}

+ (BOOL)themeDrawsTitlebarButtons {
    GSTheme *theme = [self currentTheme];
    return [theme respondsToSelector:@selector(drawsTitlebarButtons)] &&
           [theme drawsTitlebarButtons];
}

+ (NSRect)themeButtonRect:(NSInteger)buttonIndex
             titlebarSize:(NSSize)size
                styleMask:(NSUInteger)styleMask {
    GSTheme *theme = [self currentTheme];
    if (![theme respondsToSelector:@selector(titlebarButtonRectForButton:titlebarWidth:styleMask:)]) {
        return NSZeroRect;
    }
    return [theme titlebarButtonRectForButton:buttonIndex
                                titlebarWidth:size.width
                                    styleMask:styleMask];
}

+ (CGFloat)frameBorderWidth {
    GSTheme *theme = [self currentTheme];
    if (![theme respondsToSelector:@selector(windowFrameBorderWidth)]) {
        return 0.0;
    }
    return [theme windowFrameBorderWidth];
}

static NSMutableDictionary *frameBorders = nil;
// Frame window id -> the button rects last put on its titlebar
static NSMutableDictionary *publishedButtonRects = nil;

+ (URSFrameBorder *)borderRecordForWindow:(xcb_window_t)window create:(BOOL)create
{
    NSNumber *key = [NSNumber numberWithUnsignedInt:window];
    URSFrameBorder *record = [frameBorders objectForKey:key];

    if (record == nil && create) {
        if (frameBorders == nil) {
            frameBorders = [[NSMutableDictionary alloc] init];
        }
        record = [[URSFrameBorder alloc] init];
        [frameBorders setObject:record forKey:key];
    }
    return record;
}

+ (void)forgetFrameBorder:(XCBWindow *)window
{
    NSNumber *key = [NSNumber numberWithUnsignedInt:[window window]];
    URSFrameBorder *record = [frameBorders objectForKey:key];

    [publishedButtonRects removeObjectForKey:key];

    if (record == nil) {
        return;
    }
    if ([record gc] != 0) {
        xcb_free_gc([[window connection] connection], [record gc]);
    }
    [frameBorders removeObjectForKey:key];
}

+ (void)paintFrameBorder:(XCBFrame *)frame active:(BOOL)active {
    CGFloat border = [self frameBorderWidth];
    GSTheme *theme = [self currentTheme];
    XCBWindow *titlebar;
    xcb_connection_t *conn;
    URSFrameBorder *record;
    xcb_gcontext_t gc;
    XCBRect frameRect;
    uint16_t width, height, top;
    NSInteger depth, edge;

    if (frame == nil || border <= 0.0) {
        return;
    }
    if (![theme respondsToSelector:@selector(windowFrameBorderColorAtDepth:edge:active:)]) {
        return;
    }
    record = [self borderRecordForWindow:[frame window] create:YES];
    [record setActive:active];

    frameRect = [frame windowRect];
    width = frameRect.size.width;
    height = frameRect.size.height;
    titlebar = [frame childWindowForKey:TitleBar];
    top = titlebar ? [titlebar windowRect].size.height : 0;
    if (height <= top || width == 0) {
        return;
    }

    conn = [[frame connection] connection];
    gc = [record gc];
    if (gc == 0) {
        // The border is repainted on every expose and every change of focus,
        // so the context is kept until the frame goes away.
        gc = xcb_generate_id(conn);
        xcb_create_gc(conn, gc, [frame window], 0, NULL);
        [record setGc:gc];
    }
    for (depth = 0; depth < (NSInteger)border; depth++) {
        for (edge = 0; edge <= 2; edge++) {
            NSColor *color = [[theme windowFrameBorderColorAtDepth:depth
                                                              edge:edge
                                                            active:active]
                               colorUsingColorSpaceName:NSDeviceRGBColorSpace];
            // The frame is an ARGB window when the compositor is running, so
            // the border has to be painted opaque or it composites away.
            uint32_t pixel = 0xFF000000u
                           | ((uint32_t)([color redComponent] * 255.0) << 16)
                           | ((uint32_t)([color greenComponent] * 255.0) << 8)
                           | (uint32_t)([color blueComponent] * 255.0);
            xcb_rectangle_t rect;

            xcb_change_gc(conn, gc, XCB_GC_FOREGROUND, &pixel);
            switch (edge) {
                case 0:   // left
                    rect = (xcb_rectangle_t){(int16_t)depth, (int16_t)top,
                                             1, (uint16_t)(height - top)};
                    break;
                case 1:   // right
                    rect = (xcb_rectangle_t){(int16_t)(width - 1 - depth), (int16_t)top,
                                             1, (uint16_t)(height - top)};
                    break;
                default:  // bottom
                    rect = (xcb_rectangle_t){0, (int16_t)(height - 1 - depth),
                                             width, 1};
                    break;
            }
            xcb_poly_fill_rectangle(conn, [frame window], gc, 1, &rect);
        }
    }
    xcb_flush(conn);
}

+ (void)repaintFrameBorder:(XCBFrame *)frame {
    URSFrameBorder *record = [self borderRecordForWindow:[frame window]
                                                  create:NO];

    [self paintFrameBorder:frame active:record ? [record active] : NO];
}

// GNUstep publishes the window's real style mask in _GNUSTEP_WM_ATTR whether
// or not the toolkit found EWMH support, so this is what tells a utility panel
// from a document window. Returns 0 for windows of other toolkits.
+ (NSUInteger)gnustepStyleMaskForWindow:(XCBWindow *)clientWindow {
    EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:[clientWindow connection]];
    // flags, window_style, window_level, reserved, four pixmaps, extra_flags
    xcb_get_property_reply_t *reply = [ewmh getProperty:[ewmh GNUStepWmAttr]
                                          propertyType:XCB_GET_PROPERTY_TYPE_ANY
                                             forWindow:clientWindow
                                                delete:NO
                                                length:9];
    NSUInteger styleMask = 0;

    if (reply == NULL) {
        return 0;
    }
    if (reply->format == 32 && xcb_get_property_value_length(reply) >= 8) {
        uint32_t *attributes = (uint32_t *)xcb_get_property_value(reply);

        if (attributes[0] & GSWindowStyleAttr) {
            styleMask = attributes[1];
        }
    }
    free(reply);
    return styleMask;
}

+ (NSUInteger)buttonStyleMaskForFrame:(XCBFrame *)frame {
    XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
    NSUInteger styleMask = NSTitledWindowMask;

    // Panels are titled differently (Platinum gives them a windoid bar), and
    // the theme tells them apart by this bit.
    if (clientWindow) {
        EWMHService *ewmh = [EWMHService sharedInstanceWithConnection:[frame connection]];

        if (([self gnustepStyleMaskForWindow:clientWindow] & NSUtilityWindowMask)
            || [[clientWindow windowType] isEqualToString:[ewmh EWMHWMWindowTypeUtility]]) {
            styleMask |= NSUtilityWindowMask;
        }
    }

    // Require both canClose and WM_DELETE_WINDOW (ICCCM WMProtocols) to
    // consider close functional; without it the titlebar gets no buttons.
    if (!clientWindow || ![clientWindow canClose]) {
        return styleMask;
    }
    ICCCMService *icccm = [ICCCMService sharedInstanceWithConnection:[frame connection]];
    if (![icccm hasProtocol:[icccm WMDeleteWindow] forWindow:clientWindow]) {
        return styleMask;
    }

    styleMask |= NSClosableWindowMask;
    if (![self isFixedSizeWindow:[clientWindow window]]) {
        styleMask |= NSResizableWindowMask;
    }
    if ([clientWindow respondsToSelector:@selector(canMinimize)] && [clientWindow canMinimize]) {
        styleMask |= NSMiniaturizableWindowMask;
    }
    return styleMask;
}

+ (NSRect)buttonRect:(NSInteger)buttonIndex
        titlebarSize:(NSSize)size
           styleMask:(NSUInteger)styleMask {
    CGFloat width = size.width;
    CGFloat height = size.height;

    if ([self themeDrawsTitlebarButtons]) {
        NSRect r = [self themeButtonRect:buttonIndex titlebarSize:size styleMask:styleMask];
        if (NSIsEmptyRect(r)) {
            return NSZeroRect;
        }
        // Themes lay buttons out from the bottom left, X11 events count
        // from the top left.
        r.origin.y = height - NSMaxY(r);
        return r;
    }

    // Edge layout: Close (X) on left | title | Minimize (-) | Maximize (+) on right
    // Buttons are square: width == height
    BOOL hasMax = (styleMask & NSResizableWindowMask) != 0;
    switch (buttonIndex) {
        case 0:
            return NSMakeRect(0, 0, height, height);
        case 1:
            // Inner right when there is a maximize button, far right otherwise
            return NSMakeRect(hasMax ? width - 2 * height : width - height, 0, height, height);
        case 2:
            return hasMax ? NSMakeRect(width - height, 0, height, height) : NSZeroRect;
        default:
            return NSZeroRect;
    }
}

+ (NSInteger)buttonIndexAtPoint:(NSPoint)point
                   titlebarSize:(NSSize)size
                      styleMask:(NSUInteger)styleMask {
    NSInteger i;
    for (i = 0; i <= 2; i++) {
        if (NSPointInRect(point, [self buttonRect:i titlebarSize:size styleMask:styleMask])) {
            return i;
        }
    }
    return -1;  // Not over any button
}

// The style mask the button layout of frame's titlebar is computed from.
+ (NSUInteger)buttonLayoutStyleMaskForFrame:(XCBFrame *)frame {
    if ([self themeDrawsTitlebarButtons]) {
        // Theme layouts depend on exactly which buttons the titlebar shows.
        return [self buttonStyleMaskForFrame:frame];
    }
    // Edge hit areas only depend on resizability; this runs on every
    // pointer motion, so skip the WM_PROTOCOLS round trip.
    XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
    BOOL isFixedSize = clientWindow && [self isFixedSizeWindow:[clientWindow window]];
    return isFixedSize ? 0 : NSResizableWindowMask;
}

+ (NSInteger)buttonIndexAtPoint:(NSPoint)point
                   titlebarSize:(NSSize)size
                          frame:(XCBFrame *)frame {
    return [self buttonIndexAtPoint:point titlebarSize:size
                          styleMask:[self buttonLayoutStyleMaskForFrame:frame]];
}

+ (void)publishButtonRectsForTitlebar:(XCBTitleBar *)titlebar
                                 size:(NSSize)size
                                frame:(XCBFrame *)frame {
    NSUInteger styleMask = [self buttonLayoutStyleMaskForFrame:frame];
    NSMutableData *values = [NSMutableData data];
    NSInteger i;
    for (i = 0; i <= 2; i++) {
        NSRect r = [self buttonRect:i titlebarSize:size styleMask:styleMask];
        if (NSIsEmptyRect(r)) {
            continue;
        }
        uint32_t entry[5] = {
            (uint32_t)i,
            (uint32_t)lround(NSMinX(r)), (uint32_t)lround(NSMinY(r)),
            (uint32_t)lround(NSWidth(r)), (uint32_t)lround(NSHeight(r))
        };
        [values appendBytes:entry length:sizeof(entry)];
    }

    NSNumber *key = [NSNumber numberWithUnsignedInt:[frame window]];
    if ([[publishedButtonRects objectForKey:key] isEqualToData:values]) {
        return;
    }
    if (!publishedButtonRects) {
        publishedButtonRects = [[NSMutableDictionary alloc] init];
    }
    [publishedButtonRects setObject:values forKey:key];

    XCBConnection *connection = [frame connection];
    XCBAtomService *atomService = [XCBAtomService sharedInstanceWithConnection:connection];
    xcb_atom_t atom = [atomService cacheAtom:@"_WINDOW_TITLEBAR_BUTTONS"];
    xcb_change_property([connection connection], XCB_PROP_MODE_REPLACE,
                        [titlebar window], atom, XCB_ATOM_CARDINAL, 32,
                        (uint32_t)([values length] / sizeof(uint32_t)), [values bytes]);
}

// Button position enum for side-by-side titlebar buttons
typedef NS_ENUM(NSInteger, TitleBarButtonPosition) {
    TitleBarButtonPositionLeft = 0,       // Close button - left edge, full height, top-left rounded
    TitleBarButtonPositionRightInner,     // Minimize - inner right, full height, no corners rounded
    TitleBarButtonPositionRightOuter,     // Zoom/maximize - far right, full height, top-right rounded
    TitleBarButtonPositionRightFull       // Single button alone - full height, top-right rounded
};

// Draw rectangular edge button with gradient
// buttonType: 0=close, 1=minimize, 2=maximize
+ (void)drawEdgeButtonInRect:(NSRect)rect
                    position:(TitleBarButtonPosition)position
                  buttonType:(NSInteger)buttonType
                      active:(BOOL)active
                     hovered:(BOOL)hovered {
    // Get button gradient colors
    NSColor *gradientColor1;
    NSColor *gradientColor2;

    if (hovered) {
        // Hover colors - traffic light colors (apply to ALL windows, active and inactive)
        switch (buttonType) {
            case 0:  // Close - Red
                gradientColor1 = [NSColor colorWithCalibratedRed:0.95 green:0.45 blue:0.42 alpha:1];
                gradientColor2 = [NSColor colorWithCalibratedRed:0.85 green:0.30 blue:0.27 alpha:1];
                break;
            case 1:  // Minimize - Yellow
                gradientColor1 = [NSColor colorWithCalibratedRed:0.95 green:0.75 blue:0.25 alpha:1];
                gradientColor2 = [NSColor colorWithCalibratedRed:0.85 green:0.65 blue:0.15 alpha:1];
                break;
            case 2:  // Maximize - Green
                gradientColor1 = [NSColor colorWithCalibratedRed:0.35 green:0.78 blue:0.35 alpha:1];
                gradientColor2 = [NSColor colorWithCalibratedRed:0.25 green:0.68 blue:0.25 alpha:1];
                break;
            default:
                // Fallback to gray
                gradientColor1 = [NSColor colorWithCalibratedRed:0.65 green:0.65 blue:0.65 alpha:1];
                gradientColor2 = [NSColor colorWithCalibratedRed:0.45 green:0.45 blue:0.45 alpha:1];
                break;
        }
    } else if (active) {
        // Match active titlebar gradient (0.83→0.63)
        gradientColor1 = [NSColor colorWithCalibratedRed:0.83 green:0.83 blue:0.83 alpha:1];
        gradientColor2 = [NSColor colorWithCalibratedRed:0.63 green:0.63 blue:0.63 alpha:1];
    } else {
        // Match inactive titlebar gradient (0.92→0.83)
        gradientColor1 = [NSColor colorWithCalibratedRed:0.92 green:0.92 blue:0.92 alpha:1];
        gradientColor2 = [NSColor colorWithCalibratedRed:0.83 green:0.83 blue:0.83 alpha:1];
    }

    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:gradientColor1
                                                         endingColor:gradientColor2];

    // Create path with appropriate corner rounding
    NSBezierPath *path = [self buttonPathForRect:rect position:position];

    // Fill with gradient
    [gradient drawInBezierPath:path angle:-90];

    // Single 1px highlight along top edge — straight line for all positions.
    // The XCB shape mask handles visible corner rounding; highlight arcs
    // created a brightness boundary that appeared as a circle artifact.
    NSColor *highlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
    [highlightColor setStroke];
    NSBezierPath *highlight = [NSBezierPath bezierPath];
    [highlight moveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - 0.5)];
    [highlight lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 0.5)];
    [highlight setLineWidth:(1.0 * WMScaleFactor())];
    [highlight stroke];
}

+ (NSBezierPath *)buttonPathForRect:(NSRect)frame position:(TitleBarButtonPosition)position {
    // Use simple rectangular fills for all positions.
    // The frame's XCB shape mask handles visible corner rounding, and the
    // highlight arcs provide the visual corner cue.  Rounded fill paths left
    // gaps at the corners where the Eau theme's stroked arc (radius 6, grey40)
    // showed through as a visible circle artifact.
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path appendBezierPathWithRect:frame];
    return path;
}

// Draw close icon (lowercase x style - square proportions)
+ (void)drawCloseIconInRect:(NSRect)rect withColor:(NSColor *)color {
    // Make icon rect square by adding extra horizontal inset if needed
    CGFloat extraHInset = (NSWidth(rect) - NSHeight(rect)) / 2.0;
    if (extraHInset > 0) {
        rect = NSInsetRect(rect, extraHInset, 0);
    }

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path setLineWidth:ICON_STROKE];
    [path setLineCapStyle:NSRoundLineCapStyle];

    // Lowercase x style - shorter strokes, more square
    // Inset slightly from corners for a more compact look
    CGFloat inset = NSWidth(rect) * 0.15;
    [path moveToPoint:NSMakePoint(NSMinX(rect) + inset, NSMinY(rect) + inset)];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - inset, NSMaxY(rect) - inset)];
    [path moveToPoint:NSMakePoint(NSMaxX(rect) - inset, NSMinY(rect) + inset)];
    [path lineToPoint:NSMakePoint(NSMinX(rect) + inset, NSMaxY(rect) - inset)];

    [color setStroke];
    [path stroke];
}

// Draw minimize icon (horizontal minus symbol −)
+ (void)drawMinimizeIconInRect:(NSRect)rect withColor:(NSColor *)color {
    if (!color) return;

    CGFloat strokeWidth = ICON_STROKE;
    CGFloat insetFactor = 0.15;

    // Make icon rect square by adding extra horizontal inset if needed
    CGFloat extraHInset = (NSWidth(rect) - NSHeight(rect)) / 2.0;
    if (extraHInset > 0) {
        rect = NSInsetRect(rect, extraHInset, 0);
    }

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path setLineWidth:strokeWidth];
    [path setLineCapStyle:NSRoundLineCapStyle];

    // Horizontal line (minus symbol)
    CGFloat inset = NSWidth(rect) * insetFactor;
    CGFloat midY = NSMidY(rect);
    [path moveToPoint:NSMakePoint(NSMinX(rect) + inset, midY)];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - inset, midY)];

    [color setStroke];
    [path stroke];
}

// Draw maximize/zoom icon (plus symbol)
+ (void)drawMaximizeIconInRect:(NSRect)rect withColor:(NSColor *)color {
    if (!color) return;

    CGFloat strokeWidth = ICON_STROKE;
    CGFloat insetFactor = 0.15;

    // Make icon rect square by adding extra horizontal inset if needed
    CGFloat extraHInset = (NSWidth(rect) - NSHeight(rect)) / 2.0;
    if (extraHInset > 0) {
        rect = NSInsetRect(rect, extraHInset, 0);
    }

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path setLineWidth:strokeWidth];
    [path setLineCapStyle:NSRoundLineCapStyle];

    // Plus symbol
    CGFloat inset = NSWidth(rect) * insetFactor;
    CGFloat midX = NSMidX(rect);
    CGFloat midY = NSMidY(rect);

    // Horizontal line
    [path moveToPoint:NSMakePoint(NSMinX(rect) + inset, midY)];
    [path lineToPoint:NSMakePoint(NSMaxX(rect) - inset, midY)];
    // Vertical line
    [path moveToPoint:NSMakePoint(midX, NSMinY(rect) + inset)];
    [path lineToPoint:NSMakePoint(midX, NSMaxY(rect) - inset)];

    [color setStroke];
    [path stroke];
}

// Get icon color based on active/highlighted state
+ (NSColor *)iconColorForActive:(BOOL)active highlighted:(BOOL)highlighted {
    NSColor *color;
    if (!active) {
        color = [NSColor colorWithCalibratedRed:0.55 green:0.55 blue:0.55 alpha:1.0];
    } else {
        color = [NSColor colorWithCalibratedRed:0.20 green:0.20 blue:0.20 alpha:1.0];
    }

    if (highlighted) {
        color = [color shadowWithLevel:0.2];
    }

    return color;
}

#pragma mark - Singleton Management

+ (instancetype)sharedInstance {
    if (sharedInstance == nil) {
        sharedInstance = [[self alloc] init];
    }
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.enabled = YES;
        self.managedTitlebars = [[NSMutableArray alloc] init];
        //NSLog(@"GSTheme titlebar integration initialized");
    }
    return self;
}

#pragma mark - GSTheme Management

+ (void)initializeGSTheme {
    // Load the user's current theme from system defaults
    @try {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *themeName = [defaults stringForKey:@"GSTheme"];

        //NSLog(@"GSTheme user default: '%@'", themeName ?: @"(none)");

        if (themeName && [themeName length] > 0) {
            // Remove .theme extension if present
            if ([[themeName pathExtension] isEqualToString:@"theme"]) {
                themeName = [themeName stringByDeletingPathExtension];
            }

            //NSLog(@"Loading user's selected theme: %@", themeName);
            GSTheme *userTheme = [GSTheme loadThemeNamed:themeName];
            if (userTheme) {
                [GSTheme setTheme:userTheme];
                //NSLog(@"GSTheme loaded: %@", [userTheme name] ?: @"Unknown");
                return;
            } else {
                NSLog(@"Failed to load theme '%@', falling back to default", themeName);
            }
        } else {
            //NSLog(@"No theme specified in GSTheme default, using system default");
        }

        //// Fallback to whatever GSTheme gives us by default
        //GSTheme *theme = [GSTheme theme];
        ////NSLog(@"GSTheme fallback loaded: %@", [theme name] ?: @"Default");

        //// Log theme bundle info for debugging
        //if (theme && [theme bundle]) {
        //    //NSLog(@"Theme bundle path: %@", [[theme bundle] bundlePath]);
        //}

    } @catch (NSException *exception) {
        NSLog(@"Failed to load GSTheme: %@", exception.reason);
    }
}

+ (GSTheme*)currentTheme {
    return [GSTheme theme];
}

+ (void)enableGSThemeTitleBars {
    //NSLog(@"Enabling GSThemeTitleBar replacement for XCBTitleBar...");

    // The GSThemeTitleBar class will automatically override XCBTitleBar methods
    // when instances are created. We just need to ensure it's loaded.
    Class gsThemeClass = [GSThemeTitleBar class];
    if (gsThemeClass) {
        //NSLog(@"GSThemeTitleBar class loaded successfully");
    } else {
        //NSLog(@"Warning: GSThemeTitleBar class not found");
    }
}

#pragma mark - GSTheme Titlebar Rendering

// The image a titlebar is rendered into before its pixels go to the X
// pixmap.  Every -lockFocus on a new NSImage makes the backend create a
// hidden X window for the image's cache (GNUstep cannot draw into a bitmap),
// so a new image per render created and destroyed hundreds of windows while
// the window manager started.  One image per size is reused instead; both
// render paths fill the whole image with NSCompositeCopy first, so nothing
// of the previous render shows through.
+ (NSImage *)renderImageOfSize:(NSSize)size {
    static NSMutableDictionary<NSString *, NSImage *> *images = nil;
    // Windows come in few widths; the limit only keeps resizes from
    // piling up one image per width.
    static const NSUInteger maxImages = 16;

    if (images == nil) {
        images = [[NSMutableDictionary alloc] init];
    }
    NSString *key = NSStringFromSize(size);
    NSImage *image = images[key];
    if (image == nil) {
        if ([images count] >= maxImages) {
            [images removeAllObjects];
        }
        image = [[NSImage alloc] initWithSize:size];
        images[key] = image;
    }
    return image;
}

+ (BOOL)renderGSThemeTitlebar:(XCBTitleBar*)titlebar
                        title:(NSString*)title
                       active:(BOOL)isActive {

    if (![[URSThemeIntegration sharedInstance] enabled] || !titlebar) {
        return NO;
    }

    GSTheme *theme = [self currentTheme];
    if (!theme) {
        //NSLog(@"Warning: No GSTheme available for titlebar rendering");
        return NO;
    }

    @try {
        // Get titlebar dimensions - use parent frame width to ensure titlebar spans full window
        XCBRect xcbRect = titlebar.windowRect;
        XCBWindow *parentFrame = [titlebar parentWindow];
        uint16_t titlebarWidth = xcbRect.size.width;

        if (parentFrame) {
            XCBRect frameRect = [parentFrame windowRect];
            titlebarWidth = frameRect.size.width;

            // Resize the X11 titlebar window if it doesn't match the frame width
            if (xcbRect.size.width != frameRect.size.width) {
                NSDebugLog(@"Resizing titlebar X11 window from %d to %d to match frame",
                      xcbRect.size.width, frameRect.size.width);

                uint32_t values[] = {frameRect.size.width};
                xcb_configure_window([[titlebar connection] connection],
                                     [titlebar window],
                                     XCB_CONFIG_WINDOW_WIDTH,
                                     values);

                // Update the titlebar's internal rect
                xcbRect.size.width = frameRect.size.width;
                [titlebar setWindowRect:xcbRect];

                // Recreate the pixmap with the new size
                [titlebar createPixmap];

                [[titlebar connection] flush];
            }
        }
        NSSize titlebarSize = NSMakeSize(titlebarWidth, xcbRect.size.height);

        NSImage *titlebarImage = [self renderImageOfSize:titlebarSize];

        [titlebarImage lockFocus];

        // Check if compositor is active for alpha transparency support
        BOOL compositorActive = [[URSCompositingManager sharedManager] compositingActive];

        // Clear background - use transparent for compositor mode to support rounded corner alpha
        // Non-compositor mode uses opaque color to prevent garbage pixels
        if (compositorActive) {
            // Use NSCompositeCopy to truly clear to transparent (NSRectFill composites over existing content)
            [[NSColor clearColor] set];
            NSRectFillUsingOperation(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height), NSCompositeCopy);
            NSDebugLog(@"[URSThemeIntegration] Using transparent background for compositor alpha support");
        } else {
            [[NSColor lightGrayColor] set];
            NSRectFill(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height));
        }

        // Define the titlebar rect
        NSRect titlebarRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);

        // Determine style mask based on client capabilities
        // (re-use parentFrame variable declared above)
        XCBWindow *clientWindow = nil;
        if (parentFrame && [parentFrame isKindOfClass:[XCBFrame class]]) {
            clientWindow = [(XCBFrame*)parentFrame childWindowForKey:ClientWindow];
        }

        NSUInteger styleMask = NSTitledWindowMask;
        if (clientWindow) {
            // Require both canClose and WM_DELETE_WINDOW support before showing controls
            ICCCMService *icccm = [ICCCMService sharedInstanceWithConnection:[titlebar connection]];
            BOOL supportsDelete = [icccm hasProtocol:[icccm WMDeleteWindow] forWindow:clientWindow];

            if (![clientWindow canClose] || !supportsDelete) {
                NSDebugLog(@"GSTheme: Client %u reports canClose=NO or lacks WM_DELETE_WINDOW - omitting control buttons", [clientWindow window]);
            } else {
                styleMask |= NSClosableWindowMask;

                // Respect fixed-size windows (hide resize)
                xcb_window_t clientId = [clientWindow window];
                if (clientId == 0 || ![URSThemeIntegration isFixedSizeWindow:clientId]) {
                    styleMask |= NSResizableWindowMask;
                }

                // Show minimize if client supports it
                if ([clientWindow respondsToSelector:@selector(canMinimize)] && [clientWindow canMinimize]) {
                    styleMask |= NSMiniaturizableWindowMask;
                }
            }
        } else {
            // Fallback to all buttons when client unknown
            styleMask |= NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
        }

        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        NSDebugLog(@"Drawing GSTheme titlebar with styleMask: 0x%lx, state: %d", (unsigned long)styleMask, (int)state);

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:titlebarRect
                      withFrame:titlebarRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

        // Themes that draw their own buttons already drew everything in
        // drawWindowBorder. Skip the WM's edge button overlay.
        if (![self themeDrawsTitlebarButtons]) {
            // Draw buttons: Close (X) on left | title | Minimize (-) | Maximize (+) on right
            // Icons show on active windows always, and on inactive windows when hovered.
            xcb_window_t tbId = [titlebar window];
            BOOL isTitlebarHovered = (tbId == hoveredTitlebarWindow);
            NSInteger hovIdx = isTitlebarHovered ? hoveredButtonIndex : -1;
            BOOL hasMaximize = (styleMask & NSResizableWindowMask) != 0;
            BOOL hasMinimize = (styleMask & NSMiniaturizableWindowMask) != 0;

            // Close button at left edge, square (width == height)
            if (styleMask & NSClosableWindowMask) {
                NSRect closeFrame = NSMakeRect(0, 0, titlebarSize.height, titlebarSize.height);
                BOOL closeHovered = (hovIdx == 0);
                [URSThemeIntegration drawEdgeButtonInRect:closeFrame
                                                 position:TitleBarButtonPositionLeft
                                               buttonType:0
                                                   active:isActive
                                                  hovered:closeHovered];
                if (isActive || closeHovered) {
                    NSColor *ic = [URSThemeIntegration iconColorForActive:isActive highlighted:closeHovered];
                    NSRect iconRect = NSInsetRect(closeFrame, ICON_INSET, ICON_INSET);
                    [URSThemeIntegration drawCloseIconInRect:iconRect withColor:ic];
                }
                NSDebugLog(@"Drew close button at: %@ hovered:%d", NSStringFromRect(closeFrame), closeHovered);
            }

            // Side-by-side buttons on right: Minimize (-) inner, Maximize (+) outer
            if (hasMinimize) {
                NSRect miniFrame;
                TitleBarButtonPosition miniPosition;
                BOOL miniHovered = (hovIdx == 1);
                if (hasMaximize) {
                    miniFrame = NSMakeRect(titlebarSize.width - 2 * titlebarSize.height,
                                           0,
                                           titlebarSize.height,
                                           titlebarSize.height);
                    miniPosition = TitleBarButtonPositionRightInner;
                } else {
                    miniFrame = NSMakeRect(titlebarSize.width - titlebarSize.height,
                                           0,
                                           titlebarSize.height,
                                           titlebarSize.height);
                    miniPosition = TitleBarButtonPositionRightFull;
                }
                [URSThemeIntegration drawEdgeButtonInRect:miniFrame
                                                 position:miniPosition
                                               buttonType:1
                                                   active:isActive
                                                  hovered:miniHovered];
                if (isActive || miniHovered) {
                    NSColor *ic = [URSThemeIntegration iconColorForActive:isActive highlighted:miniHovered];
                    NSRect miniIconRect = NSInsetRect(miniFrame, ICON_INSET, ICON_INSET);
                    [URSThemeIntegration drawMinimizeIconInRect:miniIconRect withColor:ic];
                }
                NSDebugLog(@"Drew miniaturize button at: %@ hovered:%d", NSStringFromRect(miniFrame), miniHovered);
            }

            if (hasMaximize) {
                TitleBarButtonPosition zoomPosition = hasMinimize ? TitleBarButtonPositionRightOuter : TitleBarButtonPositionRightFull;
                NSRect zoomFrame = NSMakeRect(titlebarSize.width - titlebarSize.height,
                                              0,
                                              titlebarSize.height,
                                              titlebarSize.height);
                BOOL zoomHovered = (hovIdx == 2);
                [URSThemeIntegration drawEdgeButtonInRect:zoomFrame
                                                 position:zoomPosition
                                               buttonType:2
                                                   active:isActive
                                                  hovered:zoomHovered];
                if (isActive || zoomHovered) {
                    NSColor *ic = [URSThemeIntegration iconColorForActive:isActive highlighted:zoomHovered];
                    NSRect zoomIconRect = NSInsetRect(zoomFrame, ICON_INSET, ICON_INSET);
                    [URSThemeIntegration drawMaximizeIconInRect:zoomIconRect withColor:ic];
                }
                NSDebugLog(@"Drew zoom button at: %@ hovered:%d", NSStringFromRect(zoomFrame), zoomHovered);
            }

            // Top highlight across title area (connecting button highlights)
            CGFloat highlightLeft = (styleMask & NSClosableWindowMask) ? titlebarSize.height : 0;
            CGFloat highlightRight = (hasMaximize && hasMinimize) ? (titlebarSize.width - 2 * titlebarSize.height) :
                                     (hasMaximize || hasMinimize) ? (titlebarSize.width - titlebarSize.height) : titlebarSize.width;
            NSColor *titleBaseColor = isActive
                ? [NSColor colorWithCalibratedWhite:0.75 alpha:1.0]
                : [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
            [titleBaseColor setStroke];
            NSBezierPath *titleBase = [NSBezierPath bezierPath];
            [titleBase moveToPoint:NSMakePoint(highlightLeft, titlebarSize.height - 0.5)];
            [titleBase lineToPoint:NSMakePoint(highlightRight, titlebarSize.height - 0.5)];
            [titleBase setLineWidth:(1.0 * WMScaleFactor())];
            [titleBase stroke];

            NSColor *titleHighlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
            [titleHighlightColor setStroke];
            NSBezierPath *titleHighlight = [NSBezierPath bezierPath];
            [titleHighlight moveToPoint:NSMakePoint(0, titlebarSize.height - 0.5)];
            [titleHighlight lineToPoint:NSMakePoint(titlebarSize.width, titlebarSize.height - 0.5)];
            [titleHighlight setLineWidth:(1.0 * WMScaleFactor())];
            [titleHighlight stroke];

            // Button dividers — lightened to blend with inactive gradient
            NSColor *separatorColor = [NSColor colorWithCalibratedWhite:0.75 alpha:1.0];
            [separatorColor setStroke];

            // Vertical dividers at button boundaries
            NSBezierPath *dividers = [NSBezierPath bezierPath];
            if (styleMask & NSClosableWindowMask) {
                [dividers moveToPoint:NSMakePoint(titlebarSize.height, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarSize.height, titlebarSize.height)];
            }
            if (hasMaximize) {
                [dividers moveToPoint:NSMakePoint(titlebarSize.width - 2 * titlebarSize.height, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarSize.width - 2 * titlebarSize.height, titlebarSize.height)];
                [dividers moveToPoint:NSMakePoint(titlebarSize.width - titlebarSize.height, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarSize.width - titlebarSize.height, titlebarSize.height)];
            } else if (hasMinimize) {
                [dividers moveToPoint:NSMakePoint(titlebarSize.width - titlebarSize.height, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarSize.width - titlebarSize.height, titlebarSize.height)];
            }
            [dividers setLineWidth:(1.0 * WMScaleFactor())];
            [dividers stroke];
        }

        // Read the pixels while the image is focused: -TIFFRepresentation
        // would add the bitmap to the reused image and serve that stale
        // bitmap on every later render.
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithFocusedViewRect:
                                       NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height)];
        [titlebarImage unlockFocus];

        // Convert NSImage to pixel buffer and apply to titlebar
        BOOL success = [self transferBitmap:bitmap toPixmap:[titlebar pixmap] onTitlebar:titlebar];

        if (success) {
            NSDebugLog(@"GSTheme titlebar rendered successfully for: %@", title);
        } else {
            NSLog(@"Failed to transfer GSTheme titlebar for: %@", title);
        }

        return success;

    } @catch (NSException *exception) {
        //NSLog(@"GSTheme titlebar rendering failed: %@", exception.reason);
        return NO;
    }
}

#pragma mark - Image Transfer

// Create a dimmed/desaturated version of an image for inactive window decorations
+ (NSImage*)createDimmedImage:(NSImage*)image {
    if (!image) return nil;

    NSSize size = [image size];
    NSImage *dimmedImage = [[NSImage alloc] initWithSize:size];

    [dimmedImage lockFocus];

    // Draw the original image
    [image drawInRect:NSMakeRect(0, 0, size.width, size.height)
             fromRect:NSZeroRect
            operation:NSCompositeSourceOver
             fraction:1.0];

    // Apply desaturation overlay using a semi-transparent gray
    // This reduces vibrancy while maintaining visibility
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.35] set];
    NSRectFillUsingOperation(NSMakeRect(0, 0, size.width, size.height), NSCompositeSourceAtop);

    [dimmedImage unlockFocus];

    return dimmedImage;
}

// Transfer rendered image to a specific pixmap (pixmap or dPixmap)
+ (BOOL)transferBitmap:(NSBitmapImageRep*)bitmap toPixmap:(xcb_pixmap_t)targetPixmap onTitlebar:(XCBTitleBar*)titlebar {
    if (!bitmap) {
        NSLog(@"Failed to read the rendered titlebar for transfer");
        return NO;
    }

    // Validate bitmap data is actually allocated
    unsigned char *bitmapData = [bitmap bitmapData];
    if (!bitmapData) {
        NSLog(@"Failed to get bitmap data pointer for titlebar transfer");
        return NO;
    }

    // Check if compositor is active for ARGB visual support
    BOOL compositorActive = [[URSCompositingManager sharedManager] compositingActive];

    if (compositorActive) {
        XCBScreen *screen = [titlebar onScreen];
        if (!screen) screen = [titlebar screen];

        if (screen && [titlebar argbVisualId] == 0) {
            xcb_visualid_t argbVisualId = [self findARGBVisualForScreen:screen connection:titlebar.connection];

            if (argbVisualId != 0) {
                [titlebar setUse32BitDepth:YES];
                [titlebar setArgbVisualId:argbVisualId];
                [titlebar createPixmap];
                NSDebugLog(@"[URSThemeIntegration] Created 32-bit pixmap for titlebar (fallback path)");
            }
        }
    }

    // Convert bitmap pixels to premultiplied BGRA in memory for xcb_put_image (Z_PIXMAP).
    int width = [bitmap pixelsWide];
    int height = [bitmap pixelsHigh];
    int bytesPerRow = [bitmap bytesPerRow];

    NSBitmapFormat bitmapFormat = [bitmap bitmapFormat];
    BOOL alphaFirst = (bitmapFormat & NSAlphaFirstBitmapFormat) != 0;

    // Convert to premultiplied BGRA: B | G<<8 | R<<16 | A<<24 on little-endian.
    for (int y = 0; y < height; y++) {
        uint32_t *rowPtr = (uint32_t *)(bitmapData + (y * bytesPerRow));
        for (int x = 0; x < width; x++) {
            uint32_t pixel = rowPtr[x];
            uint32_t r, g, b, a;

            if (alphaFirst) {
                // ARGB in memory: A, R, G, B bytes
                // On little-endian read as uint32_t: B<<24 | G<<16 | R<<8 | A
                a = (pixel >> 0) & 0xFF;
                r = (pixel >> 8) & 0xFF;
                g = (pixel >> 16) & 0xFF;
                b = (pixel >> 24) & 0xFF;
            } else {
                // RGBA in memory: R, G, B, A bytes
                // On little-endian read as uint32_t: A<<24 | B<<16 | G<<8 | R
                r = (pixel >> 0) & 0xFF;
                g = (pixel >> 8) & 0xFF;
                b = (pixel >> 16) & 0xFF;
                a = (pixel >> 24) & 0xFF;
            }

            // Pre-multiply RGB by alpha.
            if (a < 255) {
                r = (r * a) / 255;
                g = (g * a) / 255;
                b = (b * a) / 255;
            }

            // Premultiplied BGRA: B, G, R, A bytes = B | G<<8 | R<<16 | A<<24
            rowPtr[x] = b | (g << 8) | (r << 16) | (a << 24);
        }
    }

    // Get corner radius — zero corner pixels for compositor transparency.
    CGFloat topR = 0;
    if (compositorActive) {
        GSTheme *theme = [GSTheme theme];
        if ([theme respondsToSelector:@selector(titlebarCornerRadius)])
            topR = [theme titlebarCornerRadius];
    }

    // Zero out corner pixels for rounded top corners directly in the pixel buffer.
    // Both corners use the same convention: dx ranges -(cr-1)...0 for the left,
    // 0...cr-1 for the right, and dy ranges -(cr-1)...0. This ensures the arc
    // shape is perfectly symmetric left-to-right (previously the left corner
    // used dx∈{-cr,...,-1} while the right used dx∈{0,...,cr-1}, creating a
    // 1-pixel offset that made the radius appear different in x vs y).
    if (topR > 0) {
        int cr = (int)ceil((double)topR);
        for (int y = 0; y < cr && y < height; y++) {
            uint32_t *row = (uint32_t *)(bitmapData + y * bytesPerRow);
            for (int x = 0; x < cr && x < width; x++) {
                int dx = x - (cr - 1), dy = y - cr;
                if (dx * dx + dy * dy > cr * cr)
                    row[x] = 0;
            }
            for (int x = width - cr; x < width; x++) {
                int dx = x - (width - cr), dy = y - cr;
                if (dx * dx + dy * dy > cr * cr)
                    row[x] = 0;
            }
        }
    }

    // Upload pixels to the XCB pixmap via xcb_put_image (Z_PIXMAP).
    {
        xcb_connection_t *conn = [titlebar.connection connection];
        uint8_t depth = 32;
        if (!titlebar.use32BitDepth) {
            XCBScreen *screen = [titlebar onScreen];
            if (!screen) screen = [titlebar screen];
            if (screen) depth = [screen screen]->root_depth;
        }
        xcb_gcontext_t gc = xcb_generate_id(conn);
        xcb_create_gc(conn, gc, targetPixmap, 0, NULL);
        xcb_put_image(conn, XCB_IMAGE_FORMAT_Z_PIXMAP,
                      targetPixmap, gc,
                      (uint16_t)width, (uint16_t)height,
                      0, 0, 0, depth,
                      (uint32_t)((size_t)height * (size_t)bytesPerRow),
                      bitmapData);
        xcb_free_gc(conn, gc);
    }

    // Copy pixmap content to dPixmap unchanged.  Both pixmaps always have the
    // same content — no brightening or dimming — so there can never be a
    // mismatch between the gradient and button symbols.  The active/inactive
    // distinction comes from the THEME drawing differently for each state
    // (via drawTitleBarBackground:active:), and the window manager always
    // re-renders on focus changes.
    xcb_pixmap_t dPixmap = [titlebar dPixmap];
    if (dPixmap != 0 && [titlebar pixmap] != 0) {
        xcb_connection_t *conn = [titlebar.connection connection];
        xcb_gcontext_t copyGc = xcb_generate_id(conn);
        xcb_create_gc(conn, copyGc, dPixmap, 0, NULL);
        xcb_copy_area(conn,
                      [titlebar pixmap],
                      dPixmap,
                      copyGc,
                      0, 0,      // src x, y
                      0, 0,      // dst x, y
                      (uint16_t)width,
                      (uint16_t)height);
        xcb_free_gc(conn, copyGc);
    }

    [titlebar.connection flush];

    // Notify compositor that titlebar rendering is complete
    // Use the parent frame's window ID for compositor notification
    xcb_window_t windowId = [[titlebar parentWindow] window];
    if (windowId != 0) {
        [URSRenderingContext notifyRenderingComplete:windowId];
    }

    return YES;
}

// Snapshot the current frame of a real NSProgressIndicator (spinning) into the
// caller's current graphics context.  Using the actual control - rather than
// replaying common_ProgressSpinning_N by hand - makes the titlebar activity
// spinner pixel-identical to every other Eau spinner: drawRect: goes through
// GSTheme, which resolves the *themed* spinner art (Eau's override), whereas
// a direct [NSImage imageNamed:] lookup returns the default GNUstep image.
// Same frame sequence and animation rate as anywhere else.  The indicator is
// created and started once on the main runloop; each call captures its frame.
+ (void)drawContentActivitySpinnerInRect:(NSRect)rect
                                     alpha:(CGFloat)alpha {
    static NSProgressIndicator *spinner = nil;
    static NSImage *cache = nil;
    static NSSize cacheSize = {0.0, 0.0};
    static BOOL started = NO;

    if (spinner == nil) {
        spinner = [[NSProgressIndicator alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, 32.0, 32.0)];
        [spinner setStyle:NSProgressIndicatorSpinningStyle];
        [spinner setIndeterminate:YES];
        [spinner setUsesThreadedAnimation:NO];
    }
    if (!started) {
        [spinner startAnimation:nil];
        started = YES;
    }

    NSSize s = rect.size;
    if (cache == nil || !NSEqualSizes(cacheSize, s)) {
        cache = [[NSImage alloc] initWithSize:s];
        cacheSize = s;
    }

    // Snapshot the live spinner frame at full alpha into a cache image, then
    // composite it into the titlebar with the requested fade alpha.
    [cache lockFocus];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0.0, 0.0, s.width, s.height));
    [spinner setFrame:NSMakeRect(0.0, 0.0, s.width, s.height)];
    [spinner drawRect:NSMakeRect(0.0, 0.0, s.width, s.height)];
    [cache unlockFocus];

    [cache drawInRect:rect
             fromRect:NSZeroRect
            operation:NSCompositeSourceOver
             fraction:alpha];
}

+ (BOOL)renderGSThemeToWindow:(XCBWindow*)window
                         frame:(XCBFrame*)frame
                         title:(NSString*)title
                        active:(BOOL)isActive {
    URS_PROFILE_BEGIN(themeRender);

    if (![[URSThemeIntegration sharedInstance] enabled] || !window || !frame) {
        URS_PROFILE_END(themeRender);
        return NO;
    }

    GSTheme *theme = [self currentTheme];
    if (!theme) {
        //NSLog(@"Warning: No GSTheme available for standalone titlebar rendering");
        return NO;
    }

    @try {
        // Get the frame's titlebar area
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            //NSLog(@"Warning: No titlebar found in frame for GSTheme rendering");
            return NO;
        }
        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

        // Get titlebar dimensions - use frame width to ensure titlebar spans full window
        XCBRect titlebarRect = [titlebar windowRect];
        XCBRect frameRect = [frame windowRect];

        uint16_t targetWidth;
        int16_t targetX;
        if ([URSThemeIntegration themeDrawsTitlebarButtons]) {
            // Theme-drawn buttons don't extend to the edges; use exact frame width
            targetWidth = frameRect.size.width;
            targetX = 0;
        } else {
            // Edge buttons need +2 to cover border edges
            targetWidth = frameRect.size.width + 2;
            targetX = -1;
        }
        BOOL needsGeometryUpdate = (titlebarRect.position.x != targetX ||
                                    titlebarRect.size.width != targetWidth);
        XCBSize pixmapSize = [titlebar pixmapSize];
        BOOL needsPixmapRecreate = ([titlebar pixmap] == 0 ||
                                    [titlebar dPixmap] == 0 ||
                                    pixmapSize.width != targetWidth ||
                                    pixmapSize.height != titlebarRect.size.height);

        if (needsGeometryUpdate) {
            NSDebugLog(@"DEBUG: Resizing titlebar X11 window to %d at x=%d (frame=%d, current titlebar=%d)",
                  targetWidth, targetX, frameRect.size.width, titlebarRect.size.width);

            uint32_t values[2] = {(uint32_t)targetX, targetWidth};
            xcb_configure_window([[frame connection] connection],
                                 [titlebar window],
                                 XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH,
                                 values);

            // Keep the cached rect in sync with X11 geometry updates.
            titlebarRect.position.x = targetX;
            titlebarRect.size.width = targetWidth;
            [titlebar setWindowRect:titlebarRect];
        }

        if (needsPixmapRecreate) {
            if ([titlebar pixmap] != 0 || [titlebar dPixmap] != 0) {
                [titlebar destroyPixmap];
            }
            [titlebar createPixmap];
        }

        if (needsGeometryUpdate || needsPixmapRecreate) {
            [[frame connection] flush];
        }

        NSSize titlebarSize = NSMakeSize(targetWidth, titlebarRect.size.height);
        [self publishButtonRectsForTitlebar:titlebar size:titlebarSize frame:frame];
        NSDebugLog(@"DEBUG: Using titlebarSize.width = %d (frame was %d)", (int)titlebarSize.width, (int)frameRect.size.width);

        // DEBUG: Also get client window dimensions for comparison
        XCBWindow *clientWin = [frame childWindowForKey:ClientWindow];
        XCBRect clientRect = clientWin ? [clientWin windowRect] : XCBMakeRect(XCBMakePoint(0,0), XCBMakeSize(0,0));
        NSDebugLog(@"DEBUG DIMENSIONS: frame=%dx%d, titlebar=%dx%d, client=%dx%d",
              (int)frameRect.size.width, (int)frameRect.size.height,
              (int)titlebarRect.size.width, (int)titlebarRect.size.height,
              (int)clientRect.size.width, (int)clientRect.size.height);

        NSDebugLog(@"Rendering standalone GSTheme titlebar: %dx%d (frame: %dx%d) for window %u",
              (int)titlebarSize.width, (int)titlebarSize.height,
              (int)frameRect.size.width, (int)frameRect.size.height, [window window]);

        NSImage *titlebarImage = [self renderImageOfSize:titlebarSize];

        [titlebarImage lockFocus];
        
        // Set up the graphics state for theme drawing
        NSGraphicsContext *gctx = [NSGraphicsContext currentContext];
        [gctx saveGraphicsState];

        // Use GSTheme to draw titlebar decoration

        // Hit testing uses the same mask, so the buttons stay where they are drawn
        NSUInteger styleMask = [URSThemeIntegration buttonStyleMaskForFrame:frame];

        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        NSDebugLog(@"Drawing standalone GSTheme titlebar with styleMask: 0x%lx, state: %d", (unsigned long)styleMask, (int)state);

        // Log GSTheme padding and size values to verify Eau theme values
        if ([theme respondsToSelector:@selector(titlebarPaddingLeft)]) {
            NSDebugLog(@"GSTheme titlebarPaddingLeft: %.1f", [theme titlebarPaddingLeft]);
        }
        if ([theme respondsToSelector:@selector(titlebarPaddingRight)]) {
            NSDebugLog(@"GSTheme titlebarPaddingRight: %.1f", [theme titlebarPaddingRight]);
        }
        if ([theme respondsToSelector:@selector(titlebarPaddingTop)]) {
            NSDebugLog(@"GSTheme titlebarPaddingTop: %.1f", [theme titlebarPaddingTop]);
        }
        if ([theme respondsToSelector:@selector(titlebarButtonSize)]) {
            NSDebugLog(@"GSTheme titlebarButtonSize: %.1f", [theme titlebarButtonSize]);
        }
        NSDebugLog(@"Expected Eau values: paddingLeft=2, paddingRight=2, paddingTop=6, buttonSize=13");

        // Get theme font settings for titlebar text
        NSString *themeFontName = @"LuxiSans"; // Default from Eau theme
        float themeFontSize = 13.0;            // Default from Eau theme

        // Try to get font settings from theme bundle
        NSBundle *themeBundle = [theme bundle];
        if (themeBundle) {
            NSDictionary *themeInfo = [themeBundle infoDictionary];
            if (themeInfo) {
                NSString *fontName = [themeInfo objectForKey:@"NSFont"];
                NSString *fontSize = [themeInfo objectForKey:@"NSFontSize"];

                if (fontName) {
                    themeFontName = fontName;
                    NSDebugLog(@"Theme font name: %@", themeFontName);
                }
                if (fontSize) {
                    themeFontSize = [fontSize floatValue];
                    NSDebugLog(@"Theme font size: %.1f", themeFontSize);
                }
            }
        }

        // Set the font for titlebar text rendering
        NSFont *titlebarFont = [NSFont fontWithName:themeFontName size:themeFontSize];
        if (!titlebarFont) {
            // Fallback if LuxiSans is not available
            titlebarFont = [NSFont systemFontOfSize:themeFontSize];
            NSDebugLog(@"Using system font fallback at size %.1f (LuxiSans not available)", themeFontSize);
        } else {
            NSDebugLog(@"Using theme font: %@ %.1f", themeFontName, themeFontSize);
        }

        // *** THEME-AGNOSTIC APPROACH ***
        // Call the theme's titlebar drawing method. Different themes may use
        // different method names:
        //   - Base GSTheme: drawTitleBarRect (uppercase T)
        //   - Eau theme: drawtitleRect (lowercase t)
        // We check for theme-specific methods first, then fall back to base.
        
        NSRect titleBarRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);

        // Check if compositor is active for alpha transparency support
        BOOL compositorActive = [[URSCompositingManager sharedManager] compositingActive];

        // Pre-fill the entire rect
        // In compositor mode, use clearColor for transparent rounded corners
        // Otherwise, use grey to ensure no garbage pixels at theme edges
        if (compositorActive) {
            // Use NSCompositeCopy to truly clear to transparent
            [[NSColor clearColor] set];
            NSRectFillUsingOperation(titleBarRect, NSCompositeCopy);
            NSDebugLog(@"[URSThemeIntegration] Using transparent prefill for compositor alpha support");
        } else {
            // Grey40 #666666 - matches Eau border, prevents garbage at edges
            NSColor *prefillColor = [NSColor colorWithCalibratedWhite:0.4 alpha:1.0];
            [prefillColor set];
            NSRectFill(titleBarRect);
        }
        
        NSDebugLog(@"DEBUG: Calling theme titlebar drawing with rect=%@", NSStringFromRect(titleBarRect));
        
        // Check for Eau-style drawtitleRect (lowercase 't')
        SEL eauSelector = @selector(drawtitleRect:forStyleMask:state:andTitle:);
        // Check for base drawTitleBarRect (uppercase 'T')
        SEL baseSelector = @selector(drawTitleBarRect:forStyleMask:state:andTitle:);
        
        @try {
            if ([theme respondsToSelector:eauSelector]) {
                // Eau theme (and similar) - call drawtitleRect directly
                NSDebugLog(@"DEBUG: Theme responds to drawtitleRect (Eau-style)");
                
                NSMethodSignature *sig = [theme methodSignatureForSelector:eauSelector];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:eauSelector];
                [inv setTarget:theme];
                [inv setArgument:&titleBarRect atIndex:2];
                [inv setArgument:&styleMask atIndex:3];
                [inv setArgument:&state atIndex:4];
                NSString *titleStr = title ?: @"";
                [inv setArgument:&titleStr atIndex:5];
                [inv invoke];
                
                NSDebugLog(@"DEBUG: Successfully called theme's drawtitleRect");
            } else if ([theme respondsToSelector:baseSelector]) {
                // Base GSTheme - call drawTitleBarRect
                NSDebugLog(@"DEBUG: Theme responds to drawTitleBarRect (base-style)");
                [theme drawTitleBarRect:titleBarRect
                           forStyleMask:styleMask
                                  state:state
                               andTitle:title ?: @""];
                NSDebugLog(@"DEBUG: Successfully called theme's drawTitleBarRect");
            } else {
                // Fallback: simple gray background
                NSDebugLog(@"DEBUG: Theme doesn't respond to any titlebar drawing method, using fallback");
                [[NSColor lightGrayColor] set];
                NSRectFill(titleBarRect);
            }
        } @catch (NSException *e) {
            NSDebugLog(@"DEBUG: Titlebar drawing threw exception: %@, using fallback", e.reason);
            [[NSColor lightGrayColor] set];
            NSRectFill(titleBarRect);
        }
        
        // Restore graphics state
        [gctx restoreGraphicsState];

        // *** CONTENT-ACTIVITY SPINNER OVERLAY ***
        // Draw a real NSProgressIndicator (spinning) so the titlebar spinner is
        // pixel-identical to every other Eau spinner: same GSTheme art, same
        // frame sequence, same animation rate.  The control is animated once on
        // the main runloop; here we snapshot its current frame.
        if ([titlebar respondsToSelector:@selector(spinnerRenderFrame)] &&
            [(XCBTitleBar *)titlebar spinnerRenderFrame] >= 0) {
            CGFloat side = titlebarSize.height - 6.0;
            if (side < 8.0) side = 8.0;
            CGFloat sx = [(XCBTitleBar *)titlebar spinnerTargetX];
            NSRect spinRect = NSMakeRect(sx, (titlebarSize.height - side) / 2.0, side, side);
            CGFloat alpha = [(XCBTitleBar *)titlebar spinnerAlpha];
            [URSThemeIntegration drawContentActivitySpinnerInRect:spinRect
                                                            alpha:alpha];
        }

        // *** BUTTON DRAWING ***
        CGFloat titlebarWidth = titlebarSize.width;
        CGFloat buttonHeight = titlebarSize.height;
        BOOL hasMaximize = (styleMask & NSResizableWindowMask) != 0;
        BOOL hasMinimize = (styleMask & NSMiniaturizableWindowMask) != 0;

        // Check if this titlebar is being hovered
        xcb_window_t titlebarId = [titlebar window];
        BOOL isTitlebarHovered = (titlebarId == hoveredTitlebarWindow);
        NSInteger hoverIdx = isTitlebarHovered ? hoveredButtonIndex : -1;

        if ([self themeDrawsTitlebarButtons]) {
            // The theme already drew its buttons in drawtitleRect; redraw the
            // hovered one in its highlighted state.
            if (hoverIdx >= 0 && hoverIdx <= 2) {
                SEL hoverSelectors[] = {
                    @selector(drawCloseButtonInRect:state:active:),
                    @selector(drawMinimizeButtonInRect:state:active:),
                    @selector(drawMaximizeButtonInRect:state:active:)
                };
                SEL sel = hoverSelectors[hoverIdx];
                NSRect r = [self themeButtonRect:hoverIdx
                                    titlebarSize:titlebarSize
                                       styleMask:styleMask];

                if (!NSIsEmptyRect(r) && [theme respondsToSelector:sel]) {
                    GSThemeControlState hState = GSThemeHighlightedState;
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[theme methodSignatureForSelector:sel]];
                    [inv setSelector:sel];
                    [inv setTarget:theme];
                    [inv setArgument:&r atIndex:2];
                    [inv setArgument:&hState atIndex:3];
                    [inv setArgument:&isActive atIndex:4];
                    [inv invoke];
                }
            }
        } else {
            // Edge mode: draw buttons, highlights, dividers
            NSDebugLog(@"Drawing side-by-side edge buttons for theme: %@", [theme name]);

            // Close button at left edge, square (width == height)
            if (styleMask & NSClosableWindowMask) {
                NSRect closeFrame = NSMakeRect(0, 0, buttonHeight, buttonHeight);
                BOOL closeHovered = (hoverIdx == 0);

                [self drawEdgeButtonInRect:closeFrame
                                  position:TitleBarButtonPositionLeft
                                buttonType:0
                                    active:isActive
                                   hovered:closeHovered];

                // Show icon on active, or when hovering this button on inactive
                if (isActive || closeHovered) {
                    NSColor *ic = [self iconColorForActive:isActive highlighted:closeHovered];
                    NSRect iconRect = NSInsetRect(closeFrame, ICON_INSET, ICON_INSET);
                    [self drawCloseIconInRect:iconRect withColor:ic];
                }

                NSDebugLog(@"Drew close button at: %@ hovered:%d", NSStringFromRect(closeFrame), closeHovered);
            }

            // Side-by-side buttons on right: Minimize (-) inner, Maximize (+) outer
            if (hasMinimize) {
                NSRect miniFrame;
                TitleBarButtonPosition miniPosition;
                BOOL miniHovered = (hoverIdx == 1);

                if (hasMaximize) {
                    miniFrame = NSMakeRect(titlebarWidth - 2 * buttonHeight,
                                           0,
                                           buttonHeight,
                                           buttonHeight);
                    miniPosition = TitleBarButtonPositionRightInner;
                } else {
                    miniFrame = NSMakeRect(titlebarWidth - buttonHeight,
                                           0,
                                           buttonHeight,
                                           buttonHeight);
                    miniPosition = TitleBarButtonPositionRightFull;
                }

                [self drawEdgeButtonInRect:miniFrame
                                  position:miniPosition
                                buttonType:1
                                    active:isActive
                                   hovered:miniHovered];

                if (isActive || miniHovered) {
                    NSColor *ic = [self iconColorForActive:isActive highlighted:miniHovered];
                    NSRect iconRect = NSInsetRect(miniFrame, ICON_INSET, ICON_INSET);
                    [self drawMinimizeIconInRect:iconRect withColor:ic];
                }

                NSDebugLog(@"Drew miniaturize button at: %@ hovered:%d", NSStringFromRect(miniFrame), miniHovered);
            }

            if (hasMaximize) {
                TitleBarButtonPosition zoomPosition = hasMinimize ? TitleBarButtonPositionRightOuter : TitleBarButtonPositionRightFull;
                NSRect zoomFrame = NSMakeRect(titlebarWidth - buttonHeight,
                                              0,
                                              buttonHeight,
                                              buttonHeight);
                BOOL zoomHovered = (hoverIdx == 2);

                [self drawEdgeButtonInRect:zoomFrame
                                  position:zoomPosition
                                buttonType:2
                                    active:isActive
                                   hovered:zoomHovered];

                if (isActive || zoomHovered) {
                    NSColor *ic = [self iconColorForActive:isActive highlighted:zoomHovered];
                    NSRect iconRect = NSInsetRect(zoomFrame, ICON_INSET, ICON_INSET);
                    [self drawMaximizeIconInRect:iconRect withColor:ic];
                }

                NSDebugLog(@"Drew zoom button at: %@ hovered:%d", NSStringFromRect(zoomFrame), zoomHovered);
            }

            // Top highlight across title area (connecting button highlights)
            CGFloat highlightLeft = (styleMask & NSClosableWindowMask) ? buttonHeight : 0;
            CGFloat highlightRight = (hasMaximize && hasMinimize) ? (titlebarWidth - 2 * buttonHeight) :
                                     (hasMaximize || hasMinimize) ? (titlebarWidth - buttonHeight) : titlebarWidth;
            NSColor *titleBaseColor = isActive
                ? [NSColor colorWithCalibratedWhite:0.75 alpha:1.0]
                : [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
            [titleBaseColor setStroke];
            NSBezierPath *titleBase = [NSBezierPath bezierPath];
            [titleBase moveToPoint:NSMakePoint(highlightLeft, buttonHeight - 0.5)];
            [titleBase lineToPoint:NSMakePoint(highlightRight, buttonHeight - 0.5)];
            [titleBase setLineWidth:(1.0 * WMScaleFactor())];
            [titleBase stroke];

            NSColor *titleHighlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
            [titleHighlightColor setStroke];
            NSBezierPath *titleHighlight = [NSBezierPath bezierPath];
            [titleHighlight moveToPoint:NSMakePoint(0, buttonHeight - 0.5)];
            [titleHighlight lineToPoint:NSMakePoint(titlebarWidth, buttonHeight - 0.5)];
            [titleHighlight setLineWidth:(1.0 * WMScaleFactor())];
            [titleHighlight stroke];

            // Button dividers — lightened to blend with inactive gradient
            NSColor *separatorColor = [NSColor colorWithCalibratedWhite:0.75 alpha:1.0];
            [separatorColor setStroke];

            // Vertical dividers at button boundaries
            NSBezierPath *dividers = [NSBezierPath bezierPath];
            if (styleMask & NSClosableWindowMask) {
                [dividers moveToPoint:NSMakePoint(buttonHeight, 0)];
                [dividers lineToPoint:NSMakePoint(buttonHeight, buttonHeight)];
            }
            if (hasMaximize) {
                [dividers moveToPoint:NSMakePoint(titlebarWidth - 2 * buttonHeight, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarWidth - 2 * buttonHeight, buttonHeight)];
                [dividers moveToPoint:NSMakePoint(titlebarWidth - buttonHeight, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarWidth - buttonHeight, buttonHeight)];
            } else if (hasMinimize) {
                [dividers moveToPoint:NSMakePoint(titlebarWidth - buttonHeight, 0)];
                [dividers lineToPoint:NSMakePoint(titlebarWidth - buttonHeight, buttonHeight)];
            }
            [dividers setLineWidth:(1.0 * WMScaleFactor())];
            [dividers stroke];
        }

        // Read the pixels while the image is focused: -TIFFRepresentation
        // would add the bitmap to the reused image and serve that stale
        // bitmap on every later render.
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithFocusedViewRect:
                                       NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height)];
        [titlebarImage unlockFocus];

        // Transfer the image to the titlebar
        BOOL success = [self transferBitmap:bitmap toPixmap:[titlebar pixmap] onTitlebar:titlebar];

        if (success) {
            // Keep dPixmap in sync so drawArea: (which picks pixmap or dPixmap
            // based on isAbove) always shows the GSTheme-rendered content
            // regardless of the window's stacking-order state.
            xcb_connection_t *c = [[titlebar connection] connection];
            xcb_copy_area(c,
                          [titlebar pixmap],
                          [titlebar dPixmap],
                          [titlebar graphicContextId],
                          0, 0,
                          0, 0,
                          titlebarSize.width, titlebarSize.height);

            NSDebugLog(@"Standalone GSTheme titlebar rendered successfully for: %@", title);
        } else {
            NSLog(@"Failed to transfer standalone GSTheme titlebar for: %@", title);
        }

        // The window border shares the frame with the titlebar and changes
        // with the same active state.
        [self paintFrameBorder:frame active:isActive];

        URS_PROFILE_END(themeRender);
        return success;

    } @catch (NSException *exception) {
        //NSLog(@"Standalone GSTheme titlebar rendering failed: %@", exception.reason);
        URS_PROFILE_END(themeRender);
        return NO;
    }
}

#pragma mark - Titlebar Management

+ (void)refreshAllTitlebarsWithFocusedWindow:(xcb_window_t)focusedClientId {
    URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];

    if (!integration.enabled) {
        return;
    }

    for (XCBTitleBar *titlebar in integration.managedTitlebars) {
        // Determine if window has keyboard focus by comparing its client
        // window against the focus manager's lastFocusedWindowId.
        XCBFrame *frame = (XCBFrame *)[titlebar parentWindow];
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        BOOL isActive = (focusedClientId != XCB_NONE &&
                         clientWindow != nil &&
                         [clientWindow window] == focusedClientId);

        [self renderGSThemeTitlebar:titlebar
                              title:titlebar.windowTitle
                             active:isActive];
    }

    //NSLog(@"Refreshed %lu titlebars with GSTheme decorations", (unsigned long)[integration.managedTitlebars count]);
}

#pragma mark - Event Handlers

- (void)handleWindowCreated:(XCBTitleBar*)titlebar {
    if (!self.enabled || !titlebar) {
        return;
    }

    // Add to managed windows list
    if (![self.managedTitlebars containsObject:titlebar]) {
        [self.managedTitlebars addObject:titlebar];
        //NSLog(@"Added titlebar to GSTheme management: %@", titlebar.windowTitle);
    }

    // Newly mapped windows almost always become the active (focused) window,
    // so render them as active.  The focus manager will correct them later
    // via handleFocusChange: if needed.
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:YES];
}

- (void)handleWindowFocusChanged:(XCBTitleBar*)titlebar isActive:(BOOL)active {
    if (!self.enabled || !titlebar) {
        return;
    }

    // Re-render with updated active state
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:active];
}


#pragma mark - Configuration

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) {
        return; // Prevent recursion
    }

    _enabled = enabled;

    // Set user default to inform XCBKit about GSTheme status
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:enabled forKey:@"UROSWMGSThemeEnabled"];
    [defaults synchronize];

    if (enabled) {
        //NSLog(@"GSTheme integration enabled - XCBKit will skip legacy button drawing");
        // Don't call refreshAllTitlebars here - let the periodic timer handle it
    } else {
        //NSLog(@"GSTheme integration disabled - falling back to default titlebar rendering");
    }
}

#pragma mark - Cleanup

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end