//
//  URSThemeIntegration.m
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Implementation of GSTheme window decoration rendering for X11 titlebars.
//

#import "URSThemeIntegration.h"
#import "URSRenderingContext.h"
#import "URSCompositingManager.h"
#import <XCBKit/XCBConnection.h>
#import <XCBKit/XCBFrame.h>
#import <XCBKit/XCBScreen.h>
#import <cairo/cairo.h>
#import <cairo/cairo-xcb.h>
#import <objc/runtime.h>
#import <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#import "GSThemeTitleBar.h"
#import <XCBKit/services/ICCCMService.h>

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

@implementation URSThemeIntegration

static URSThemeIntegration *sharedInstance = nil;
static NSMutableSet *fixedSizeWindows = nil;

// Hover state tracking for titlebar buttons
static xcb_window_t hoveredTitlebarWindow = 0;
static NSInteger hoveredButtonIndex = -1;  // -1=none, 0=close, 1=mini, 2=zoom

// Edge button metrics (matching Eau theme AppearanceMetrics.h)
// Declared early so they can be used in hover state methods
static const CGFloat TITLEBAR_HEIGHT = 24.0;
static const CGFloat EDGE_BUTTON_WIDTH = 28.0;        // Close button width (left edge)
static const CGFloat RIGHT_BUTTON_WIDTH = 28.0;       // Width for each right-side button (maximize, minimize)
static const CGFloat BUTTON_INNER_RADIUS = 5.0;               // Matches Eau theme METRICS_TITLEBAR_BUTTON_INNER_RADIUS
static const CGFloat ICON_STROKE = 1.5;               // Subtle icon strokes
static const CGFloat ICON_INSET = 8.0;                // Icon inset from button edges (matches Eau theme)

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

    xcb_connection_t *conn = [connection connection];
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
                NSLog(@"[URSThemeIntegration] Found 32-bit TrueColor visual: 0x%x", visual->visual_id);
                return visual->visual_id;
            }
        }
    }

    NSLog(@"[URSThemeIntegration] No 32-bit ARGB visual found");
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
        NSLog(@"Registered fixed-size window %u (total: %lu)", windowId, (unsigned long)[fixedSizeWindows count]);
    }
}

+ (void)unregisterFixedSizeWindow:(xcb_window_t)windowId {
    @synchronized(fixedSizeWindows) {
        [fixedSizeWindows removeObject:@(windowId)];
        NSLog(@"Unregistered fixed-size window %u", windowId);
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

// Determine which button (if any) is at a given x coordinate
// Returns: 0=close, 1=mini, 2=zoom, -1=none
// Convenience method that delegates to buttonIndexAtX:y:forWidth:height:hasMaximize:
+ (NSInteger)buttonIndexAtX:(CGFloat)x forWidth:(CGFloat)width hasMaximize:(BOOL)hasMax {
    // Delegate to the full method with y at middle of titlebar
    return [self buttonIndexAtX:x y:TITLEBAR_HEIGHT / 2.0 forWidth:width height:TITLEBAR_HEIGHT hasMaximize:hasMax];
}

// Determine which button (if any) is at a given x,y coordinate (side-by-side layout)
// Returns: 0=close, 1=mini, 2=zoom, -1=none
// Layout: Close (X) on left | ---- title ---- | Minimize (-) | Maximize (+) on right
+ (NSInteger)buttonIndexAtX:(CGFloat)x y:(CGFloat)y forWidth:(CGFloat)width height:(CGFloat)height hasMaximize:(BOOL)hasMax {
    // Close button at left edge (0 to EDGE_BUTTON_WIDTH, full height)
    if (x >= 0 && x < EDGE_BUTTON_WIDTH) {
        return 0;  // Close button
    }

    // Side-by-side buttons on right side
    if (hasMax) {
        // Two buttons: Minimize (inner) | Maximize (outer/far right)
        CGFloat innerStart = width - 2 * RIGHT_BUTTON_WIDTH;
        CGFloat outerStart = width - RIGHT_BUTTON_WIDTH;
        if (x >= innerStart && x < outerStart) {
            return 1;  // Minimize button (inner right)
        }
        if (x >= outerStart && x <= width) {
            return 2;  // Zoom/maximize button (far right)
        }
    } else {
        // Only minimize button at far right
        CGFloat miniStart = width - RIGHT_BUTTON_WIDTH;
        if (x >= miniStart && x <= width) {
            return 1;  // Minimize button
        }
    }

    return -1;  // Not over any button
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
        // Active window - #C2C2C2 average (0.76) with subtle gradient
        gradientColor1 = [NSColor colorWithCalibratedRed:0.82 green:0.82 blue:0.82 alpha:1];  // #D1D1D1
        gradientColor2 = [NSColor colorWithCalibratedRed:0.70 green:0.70 blue:0.70 alpha:1];  // #B3B3B3
    } else {
        // Inactive window - slightly lighter/washed out
        gradientColor1 = [NSColor colorWithCalibratedRed:0.85 green:0.85 blue:0.85 alpha:1];
        gradientColor2 = [NSColor colorWithCalibratedRed:0.75 green:0.75 blue:0.75 alpha:1];
    }

    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:gradientColor1
                                                         endingColor:gradientColor2];

    NSColor *borderColor = [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0];

    // Top border color - matches titlebar top edge (slightly lighter for visual trick)
    NSColor *topBorderColor = [NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:1.0];

    // Bottom border color - matches titlebar bottom edge #717171
    NSColor *bottomBorderColor = [NSColor colorWithCalibratedRed:0.443 green:0.443 blue:0.443 alpha:1.0];

    // Create path with appropriate corner rounding
    NSBezierPath *path = [self buttonPathForRect:rect position:position];

    // Fill with gradient
    [gradient drawInBezierPath:path angle:-90];

    // Inner highlight - white line near top for 3D raised effect
    NSColor *highlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
    NSBezierPath *highlightPath = [NSBezierPath bezierPath];
    CGFloat highlightY = NSMaxY(rect) - 2.5;
    [highlightPath moveToPoint:NSMakePoint(NSMinX(rect) + 2, highlightY)];
    [highlightPath lineToPoint:NSMakePoint(NSMaxX(rect) - 2, highlightY)];
    [highlightColor setStroke];
    [highlightPath setLineWidth:1.0];
    [highlightPath stroke];

    // Inner shadow - black line near bottom for 3D depth
    NSColor *shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.15];
    NSBezierPath *shadowPath = [NSBezierPath bezierPath];
    CGFloat shadowY = NSMinY(rect) + 1.5;
    [shadowPath moveToPoint:NSMakePoint(NSMinX(rect) + 2, shadowY)];
    [shadowPath lineToPoint:NSMakePoint(NSMaxX(rect) - 2, shadowY)];
    [shadowColor setStroke];
    [shadowPath setLineWidth:1.0];
    [shadowPath stroke];

    // Stroke border for interior buttons only.
    // Edge buttons skip the rectangle stroke because it creates a visible gap
    // between the rectangle's top edge (y=NSMaxY) and the corner arc below it.
    // Edge button borders are drawn explicitly (edge arcs, top line, bottom line,
    // interior side line) for seamless rounded corners.
    if (position == TitleBarButtonPositionRightInner) {
        [borderColor setStroke];
        [path setLineWidth:1.0];
        [path stroke];
    }

    // Draw top border line (replicates titlebar top edge on buttons)
    NSBezierPath *topLine = [NSBezierPath bezierPath];
    CGFloat radius = BUTTON_INNER_RADIUS;
    if (position == TitleBarButtonPositionLeft) {
        // Close button: line from after top-left arc to right edge
        [topLine moveToPoint:NSMakePoint(1.5 + radius, NSMaxY(rect) - 0.5)];
        [topLine lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 0.5)];
    } else if (position == TitleBarButtonPositionRightInner) {
        // Maximize button (inner right): full-width top line (no rounded corners)
        [topLine moveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - 0.5)];
        [topLine lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 0.5)];
    } else if (position == TitleBarButtonPositionRightOuter ||
               position == TitleBarButtonPositionRightFull) {
        // Minimize button (far right): line from left edge to before top-right arc
        [topLine moveToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect) - 0.5)];
        [topLine lineToPoint:NSMakePoint(NSMaxX(rect) - 1.5 - radius, NSMaxY(rect) - 0.5)];
    }
    if ([topLine elementCount] > 0) {
        [topBorderColor setStroke];
        [topLine setLineWidth:1.0];
        [topLine stroke];
    }

    // Draw vertical divider between side-by-side buttons (right edge of inner button)
    if (position == TitleBarButtonPositionRightInner) {
        NSBezierPath *divider = [NSBezierPath bezierPath];
        [divider moveToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect) + 4)];
        [divider lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect) - 4)];
        [borderColor setStroke];
        [divider setLineWidth:1.0];
        [divider stroke];
    }

    // Draw outer edge borders (1px darker outline on far left/right of titlebar)
    // Use same color as main border for consistency
    [borderColor setStroke];

    if (position == TitleBarButtonPositionLeft) {
        // Close button: draw left edge border (far left of titlebar)
        // Draw at x=1.5 to account for X11 window offset (positioned at x=-1)
        NSBezierPath *leftEdge = [NSBezierPath bezierPath];
        [leftEdge moveToPoint:NSMakePoint(1.5, NSMinY(rect))];
        [leftEdge lineToPoint:NSMakePoint(1.5, NSMaxY(rect) - 0.5 - radius)];
        [leftEdge appendBezierPathWithArcWithCenter:NSMakePoint(1.5 + radius, NSMaxY(rect) - 0.5 - radius)
                                             radius:radius
                                         startAngle:180
                                           endAngle:90
                                          clockwise:YES];
        [leftEdge setLineWidth:1.0];
        [leftEdge stroke];
    }

    // Right edge border - drawn by outermost right-side button
    if (position == TitleBarButtonPositionRightOuter ||
        position == TitleBarButtonPositionRightFull) {
        // Draw right edge border
        // Draw at NSMaxX(rect) - 1.5 to account for X11 window offset (positioned at x=-1, width += 2)
        NSBezierPath *rightEdge = [NSBezierPath bezierPath];
        [rightEdge moveToPoint:NSMakePoint(NSMaxX(rect) - 1.5, NSMinY(rect))];
        [rightEdge lineToPoint:NSMakePoint(NSMaxX(rect) - 1.5, NSMaxY(rect) - 0.5 - radius)];
        [rightEdge appendBezierPathWithArcWithCenter:NSMakePoint(NSMaxX(rect) - 1.5 - radius, NSMaxY(rect) - 0.5 - radius)
                                              radius:radius
                                          startAngle:0
                                            endAngle:90];
        [rightEdge setLineWidth:1.0];
        [rightEdge stroke];
    }

    // Bottom border - all buttons are full height so all get bottom border
    if (position == TitleBarButtonPositionLeft ||
        position == TitleBarButtonPositionRightInner ||
        position == TitleBarButtonPositionRightOuter ||
        position == TitleBarButtonPositionRightFull) {
        NSBezierPath *bottomLine = [NSBezierPath bezierPath];
        [bottomLine moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect) + 0.5)];
        [bottomLine lineToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect) + 0.5)];
        [bottomBorderColor setStroke];
        [bottomLine setLineWidth:1.0];
        [bottomLine stroke];
    }

    // Interior-side borders for edge buttons (replaces rectangle stroke's side borders)
    // These border the edge between the button and the adjacent title area
    if (position == TitleBarButtonPositionLeft) {
        // Close button: right side border (facing title area)
        NSBezierPath *rightSide = [NSBezierPath bezierPath];
        [rightSide moveToPoint:NSMakePoint(NSMaxX(rect), NSMinY(rect))];
        [rightSide lineToPoint:NSMakePoint(NSMaxX(rect), NSMaxY(rect))];
        [borderColor setStroke];
        [rightSide setLineWidth:1.0];
        [rightSide stroke];
    } else if (position == TitleBarButtonPositionRightOuter ||
               position == TitleBarButtonPositionRightFull) {
        // Minimize button: left side border (facing title/zoom area)
        NSBezierPath *leftSide = [NSBezierPath bezierPath];
        [leftSide moveToPoint:NSMakePoint(NSMinX(rect), NSMinY(rect))];
        [leftSide lineToPoint:NSMakePoint(NSMinX(rect), NSMaxY(rect))];
        [borderColor setStroke];
        [leftSide setLineWidth:1.0];
        [leftSide stroke];
    }
}

+ (NSBezierPath *)buttonPathForRect:(NSRect)frame position:(TitleBarButtonPosition)position {
    // All button positions use full rectangles for fill/stroke.
    // Visible corner rounding is handled by edge border arcs in drawEdgeButtonInRect:.
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
// Returns nil for inactive windows (icons should be hidden)
+ (NSColor *)iconColorForActive:(BOOL)active highlighted:(BOOL)highlighted {
    if (!active) {
        return nil;  // No icons on inactive windows
    }

    // Darker icon color for active windows (0.20 - halfway between original 0.15 and 0.25)
    NSColor *color = [NSColor colorWithCalibratedRed:0.20 green:0.20 blue:0.20 alpha:1.0];

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
        NSLog(@"GSTheme titlebar integration initialized");
    }
    return self;
}

#pragma mark - GSTheme Management

+ (void)initializeGSTheme {
    // Load the user's current theme from system defaults
    @try {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *themeName = [defaults stringForKey:@"GSTheme"];

        NSLog(@"GSTheme user default: '%@'", themeName ?: @"(none)");

        if (themeName && [themeName length] > 0) {
            // Remove .theme extension if present
            if ([[themeName pathExtension] isEqualToString:@"theme"]) {
                themeName = [themeName stringByDeletingPathExtension];
            }

            NSLog(@"Loading user's selected theme: %@", themeName);
            GSTheme *userTheme = [GSTheme loadThemeNamed:themeName];
            if (userTheme) {
                [GSTheme setTheme:userTheme];
                NSLog(@"GSTheme loaded: %@", [userTheme name] ?: @"Unknown");
                return;
            } else {
                NSLog(@"Failed to load theme '%@', falling back to default", themeName);
            }
        } else {
            NSLog(@"No theme specified in GSTheme default, using system default");
        }

        // Fallback to whatever GSTheme gives us by default
        GSTheme *theme = [GSTheme theme];
        NSLog(@"GSTheme fallback loaded: %@", [theme name] ?: @"Default");

        // Log theme bundle info for debugging
        if (theme && [theme bundle]) {
            NSLog(@"Theme bundle path: %@", [[theme bundle] bundlePath]);
        }

    } @catch (NSException *exception) {
        NSLog(@"Failed to load GSTheme: %@", exception.reason);
    }
}

+ (GSTheme*)currentTheme {
    return [GSTheme theme];
}

+ (void)enableGSThemeTitleBars {
    NSLog(@"Enabling GSThemeTitleBar replacement for XCBTitleBar...");

    // The GSThemeTitleBar class will automatically override XCBTitleBar methods
    // when instances are created. We just need to ensure it's loaded.
    Class gsThemeClass = [GSThemeTitleBar class];
    if (gsThemeClass) {
        NSLog(@"GSThemeTitleBar class loaded successfully");
    } else {
        NSLog(@"Warning: GSThemeTitleBar class not found");
    }
}

#pragma mark - GSTheme Titlebar Rendering

+ (BOOL)renderGSThemeTitlebar:(XCBTitleBar*)titlebar
                        title:(NSString*)title
                       active:(BOOL)isActive {

    if (![[URSThemeIntegration sharedInstance] enabled] || !titlebar) {
        return NO;
    }

    GSTheme *theme = [self currentTheme];
    if (!theme) {
        NSLog(@"Warning: No GSTheme available for titlebar rendering");
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
                NSLog(@"Resizing titlebar X11 window from %d to %d to match frame",
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

        // Create NSImage for GSTheme to render into
        NSImage *titlebarImage = [[NSImage alloc] initWithSize:titlebarSize];

        [titlebarImage lockFocus];

        // Check if compositor is active for alpha transparency support
        BOOL compositorActive = [[URSCompositingManager sharedManager] compositingActive];

        // Clear background - use transparent for compositor mode to support rounded corner alpha
        // Non-compositor mode uses opaque color to prevent garbage pixels
        if (compositorActive) {
            // Use NSCompositeCopy to truly clear to transparent (NSRectFill composites over existing content)
            [[NSColor clearColor] set];
            NSRectFillUsingOperation(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height), NSCompositeCopy);
            NSLog(@"[URSThemeIntegration] Using transparent background for compositor alpha support");
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
                NSLog(@"GSTheme: Client %u reports canClose=NO or lacks WM_DELETE_WINDOW - omitting control buttons", [clientWindow window]);
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

        NSLog(@"Drawing GSTheme titlebar with styleMask: 0x%lx, state: %d", (unsigned long)styleMask, (int)state);

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:titlebarRect
                      withFrame:titlebarRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

        // Draw buttons: Close (X) on left | title | Minimize (-) | Maximize (+) on right
        NSColor *iconColor = [URSThemeIntegration iconColorForActive:isActive highlighted:NO];
        BOOL hasMaximize = (styleMask & NSResizableWindowMask) != 0;
        BOOL hasMinimize = (styleMask & NSMiniaturizableWindowMask) != 0;

        // Close button at left edge (full height)
        if (styleMask & NSClosableWindowMask) {
            NSRect closeFrame = NSMakeRect(0, 0, EDGE_BUTTON_WIDTH, TITLEBAR_HEIGHT);
            [URSThemeIntegration drawEdgeButtonInRect:closeFrame
                                             position:TitleBarButtonPositionLeft
                                           buttonType:0
                                               active:isActive
                                              hovered:NO];
            NSRect iconRect = NSInsetRect(closeFrame, ICON_INSET, ICON_INSET);
            [URSThemeIntegration drawCloseIconInRect:iconRect withColor:iconColor];
            NSLog(@"Drew close button at: %@", NSStringFromRect(closeFrame));
        }

        // Side-by-side buttons on right: Minimize (-) inner, Maximize (+) outer
        if (hasMinimize) {
            // Minimize button (inner right when maximize exists, far right alone)
            NSRect miniFrame;
            TitleBarButtonPosition miniPosition;
            if (hasMaximize) {
                miniFrame = NSMakeRect(titlebarSize.width - 2 * RIGHT_BUTTON_WIDTH,
                                       0,
                                       RIGHT_BUTTON_WIDTH,
                                       TITLEBAR_HEIGHT);
                miniPosition = TitleBarButtonPositionRightInner;
            } else {
                // No maximize: minimize takes far right alone
                miniFrame = NSMakeRect(titlebarSize.width - RIGHT_BUTTON_WIDTH,
                                       0,
                                       RIGHT_BUTTON_WIDTH,
                                       TITLEBAR_HEIGHT);
                miniPosition = TitleBarButtonPositionRightFull;
            }
            [URSThemeIntegration drawEdgeButtonInRect:miniFrame
                                             position:miniPosition
                                           buttonType:1
                                               active:isActive
                                              hovered:NO];
            NSRect miniIconRect = NSInsetRect(miniFrame, ICON_INSET, ICON_INSET);
            [URSThemeIntegration drawMinimizeIconInRect:miniIconRect withColor:iconColor];
            NSLog(@"Drew miniaturize button at: %@", NSStringFromRect(miniFrame));
        }

        if (hasMaximize) {
            // Zoom button (far right, full height)
            TitleBarButtonPosition zoomPosition = hasMinimize ? TitleBarButtonPositionRightOuter : TitleBarButtonPositionRightFull;
            NSRect zoomFrame = NSMakeRect(titlebarSize.width - RIGHT_BUTTON_WIDTH,
                                          0,
                                          RIGHT_BUTTON_WIDTH,
                                          TITLEBAR_HEIGHT);
            [URSThemeIntegration drawEdgeButtonInRect:zoomFrame
                                             position:zoomPosition
                                           buttonType:2
                                               active:isActive
                                              hovered:NO];
            NSRect zoomIconRect = NSInsetRect(zoomFrame, ICON_INSET, ICON_INSET);
            [URSThemeIntegration drawMaximizeIconInRect:zoomIconRect withColor:iconColor];
            NSLog(@"Drew zoom button at: %@", NSStringFromRect(zoomFrame));
        }

        // Top highlight across title area (connecting button highlights)
        // First paint 1px opaque base matching the button gradient top color so
        // the semi-transparent highlight blends identically to the buttons.
        CGFloat highlightLeft = EDGE_BUTTON_WIDTH;
        CGFloat highlightRight = (hasMaximize && hasMinimize) ? (titlebarSize.width - 2 * RIGHT_BUTTON_WIDTH) :
                                 (hasMaximize || hasMinimize) ? (titlebarSize.width - RIGHT_BUTTON_WIDTH) : titlebarSize.width;
        NSColor *titleBaseColor = isActive
            ? [NSColor colorWithCalibratedWhite:0.82 alpha:1.0]
            : [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
        [titleBaseColor setStroke];
        NSBezierPath *titleBase = [NSBezierPath bezierPath];
        [titleBase moveToPoint:NSMakePoint(highlightLeft, TITLEBAR_HEIGHT - 0.5)];
        [titleBase lineToPoint:NSMakePoint(highlightRight, TITLEBAR_HEIGHT - 0.5)];
        [titleBase setLineWidth:1.0];
        [titleBase stroke];

        NSColor *titleHighlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
        [titleHighlightColor setStroke];
        NSBezierPath *titleHighlight = [NSBezierPath bezierPath];
        [titleHighlight moveToPoint:NSMakePoint(highlightLeft, TITLEBAR_HEIGHT - 0.5)];
        [titleHighlight lineToPoint:NSMakePoint(highlightRight, TITLEBAR_HEIGHT - 0.5)];
        [titleHighlight setLineWidth:1.0];
        [titleHighlight stroke];

        // Bottom edge and button dividers (#979797)
        NSColor *separatorColor = [NSColor colorWithCalibratedWhite:0.592 alpha:1.0];
        [separatorColor setStroke];

        // Full-width bottom edge
        NSBezierPath *bottomEdge = [NSBezierPath bezierPath];
        [bottomEdge moveToPoint:NSMakePoint(0, 0.5)];
        [bottomEdge lineToPoint:NSMakePoint(titlebarSize.width, 0.5)];
        [bottomEdge setLineWidth:1.0];
        [bottomEdge stroke];

        // Vertical dividers at button boundaries
        NSBezierPath *dividers = [NSBezierPath bezierPath];
        // Right edge of close button
        if (styleMask & NSClosableWindowMask) {
            [dividers moveToPoint:NSMakePoint(EDGE_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(EDGE_BUTTON_WIDTH, TITLEBAR_HEIGHT)];
        }
        if (hasMaximize) {
            // Left edge of zoom button
            [dividers moveToPoint:NSMakePoint(titlebarSize.width - 2 * RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarSize.width - 2 * RIGHT_BUTTON_WIDTH, TITLEBAR_HEIGHT)];
            // Between zoom and minimize
            [dividers moveToPoint:NSMakePoint(titlebarSize.width - RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarSize.width - RIGHT_BUTTON_WIDTH, TITLEBAR_HEIGHT)];
        } else if (hasMinimize) {
            // Left edge of minimize button
            [dividers moveToPoint:NSMakePoint(titlebarSize.width - RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarSize.width - RIGHT_BUTTON_WIDTH, TITLEBAR_HEIGHT)];
        }
        [dividers setLineWidth:1.0];
        [dividers stroke];

        [titlebarImage unlockFocus];

        // Convert NSImage to Cairo surface and apply to titlebar
        BOOL success = [self transferImage:titlebarImage toTitlebar:titlebar];

        if (success) {
            NSLog(@"GSTheme titlebar rendered successfully for: %@", title);
        } else {
            NSLog(@"Failed to transfer GSTheme titlebar for: %@", title);
        }

        return success;

    } @catch (NSException *exception) {
        NSLog(@"GSTheme titlebar rendering failed: %@", exception.reason);
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

+ (BOOL)transferImage:(NSImage*)image toTitlebar:(XCBTitleBar*)titlebar {
    // Convert NSImage to bitmap representation
    NSBitmapImageRep *bitmap = nil;
    for (NSImageRep *rep in [image representations]) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            bitmap = (NSBitmapImageRep*)rep;
            break;
        }
    }

    if (!bitmap) {
        // Create bitmap from image data
        NSData *imageData = [image TIFFRepresentation];
        bitmap = [NSBitmapImageRep imageRepWithData:imageData];
    }

    if (!bitmap) {
        NSLog(@"Failed to create bitmap from NSImage for titlebar transfer");
        return NO;
    }

    // Check if compositor is active for ARGB visual support
    BOOL compositorActive = [[URSCompositingManager sharedManager] compositingActive];
    xcb_visualtype_t *visualType = titlebar.visual.visualType;

    // Set up ARGB visual for Cairo if compositor is active
    // Note: The titlebar window and pixmap are now created with 32-bit depth in XCBFrame.m
    // We just need to get the correct visual type for Cairo surface creation
    if (compositorActive) {
        XCBScreen *screen = [titlebar onScreen];
        if (!screen) screen = [titlebar screen];

        if (screen) {
            // Check if titlebar already has ARGB visual configured (set by XCBFrame)
            xcb_visualid_t argbVisualId = [titlebar argbVisualId];

            // If not already configured, set it up (fallback for windows created before this change)
            if (argbVisualId == 0) {
                argbVisualId = [self findARGBVisualForScreen:screen connection:titlebar.connection];

                if (argbVisualId != 0) {
                    // Set ARGB visual on titlebar for 32-bit pixmap support
                    [titlebar setUse32BitDepth:YES];
                    [titlebar setArgbVisualId:argbVisualId];

                    // Recreate pixmap with 32-bit depth
                    [titlebar createPixmap];
                    NSLog(@"[URSThemeIntegration] Created 32-bit pixmap for titlebar (fallback path)");
                }
            }

            // Get the ARGB visual type for Cairo surface
            if (argbVisualId != 0) {
                xcb_visualtype_t *argbVisualType = [self findVisualTypeForId:argbVisualId screen:screen];
                if (argbVisualType) {
                    visualType = argbVisualType;
                    NSLog(@"[URSThemeIntegration] Using 32-bit ARGB visual for Cairo surface (id: 0x%x)", argbVisualId);
                }
            }
        }
    }

    NSLog(@"Creating Cairo surface for titlebar pixmap: %u, size: %dx%d, compositor: %d",
          titlebar.pixmap, (int)image.size.width, (int)image.size.height, compositorActive);

    // DEBUG: Check bitmap format and sample pixel data
    NSLog(@"Bitmap format: %ldx%ld, bitsPerPixel=%ld, bytesPerRow=%ld, colorSpace=%@, format=%u",
          [bitmap pixelsWide], [bitmap pixelsHigh], [bitmap bitsPerPixel],
          [bitmap bytesPerRow], [bitmap colorSpaceName], (unsigned int)[bitmap bitmapFormat]);

    // Sample a few pixels to see actual byte values
    unsigned char *pixels = [bitmap bitmapData];
    if (pixels && [bitmap pixelsWide] >= 15 && [bitmap pixelsHigh] >= 8) {
        int closeX = 18, closeY = 12;  // Should be red button area
        int miniX = 37, miniY = 12;   // Should be yellow button area
        int zoomX = 56, zoomY = 12;   // Should be green button area

        int bytesPerPixel = [bitmap bitsPerPixel] / 8;

        // Sample close button pixel (should be red)
        int offset = (closeY * [bitmap bytesPerRow]) + (closeX * bytesPerPixel);
        if (bytesPerPixel >= 4) {
            NSLog(@"Close button pixel (%d,%d): [0]=%d [1]=%d [2]=%d [3]=%d",
                  closeX, closeY, pixels[offset], pixels[offset+1], pixels[offset+2], pixels[offset+3]);
        }

        // Sample miniaturize button pixel (should be yellow)
        offset = (miniY * [bitmap bytesPerRow]) + (miniX * bytesPerPixel);
        if (bytesPerPixel >= 4) {
            NSLog(@"Mini button pixel (%d,%d): [0]=%d [1]=%d [2]=%d [3]=%d",
                  miniX, miniY, pixels[offset], pixels[offset+1], pixels[offset+2], pixels[offset+3]);
        }

        // Sample zoom button pixel (should be green)
        offset = (zoomY * [bitmap bytesPerRow]) + (zoomX * bytesPerPixel);
        if (bytesPerPixel >= 4) {
            NSLog(@"Zoom button pixel (%d,%d): [0]=%d [1]=%d [2]=%d [3]=%d",
                  zoomX, zoomY, pixels[offset], pixels[offset+1], pixels[offset+2], pixels[offset+3]);
        }
    }

    // Create Cairo surface from XCB titlebar pixmap
    // Use ARGB visual when compositor is active for alpha transparency
    cairo_surface_t *x11Surface = cairo_xcb_surface_create(
        [titlebar.connection connection],
        titlebar.pixmap,
        visualType,
        (int)image.size.width,
        (int)image.size.height
    );

    cairo_status_t surface_status = cairo_surface_status(x11Surface);
    if (surface_status != CAIRO_STATUS_SUCCESS) {
        NSLog(@"Failed to create Cairo X11 surface for titlebar: %s", cairo_status_to_string(surface_status));
        cairo_surface_destroy(x11Surface);
        return NO;
    }

    NSLog(@"Cairo X11 surface created successfully");

    cairo_t *ctx = cairo_create(x11Surface);

    // Create Cairo image surface from bitmap data
    // Cairo ARGB32 expects pre-multiplied BGRA in memory (B, G, R, A bytes on little-endian)
    unsigned char *bitmapPixels = [bitmap bitmapData];
    int width = [bitmap pixelsWide];
    int height = [bitmap pixelsHigh];
    int bytesPerRow = [bitmap bytesPerRow];

    // Check bitmap format to determine correct conversion
    // NSAlphaFirstBitmapFormat (1): Alpha is first byte (ARGB in memory)
    // Otherwise: Alpha is last byte (RGBA in memory)
    NSBitmapFormat bitmapFormat = [bitmap bitmapFormat];
    BOOL alphaFirst = (bitmapFormat & NSAlphaFirstBitmapFormat) != 0;

    NSLog(@"[URSThemeIntegration] Bitmap format: 0x%x, alphaFirst: %d", (unsigned)bitmapFormat, alphaFirst);

    // Convert to Cairo ARGB32 format (BGRA in memory on little-endian)
    int rowPixels = width;
    for (int y = 0; y < height; y++) {
        uint32_t *rowPtr = (uint32_t *)(bitmapPixels + (y * bytesPerRow));
        for (int x = 0; x < rowPixels; x++) {
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

            // Pre-multiply RGB by alpha for Cairo ARGB32 format
            // Cairo expects pre-multiplied alpha: R_out = R * (A / 255)
            // This fixes transparent areas like clearColor (255,255,255,0) -> (0,0,0,0)
            if (a < 255) {
                r = (r * a) / 255;
                g = (g * a) / 255;
                b = (b * a) / 255;
            }

            // Cairo ARGB32 on little-endian: B, G, R, A bytes = B | G<<8 | R<<16 | A<<24
            rowPtr[x] = b | (g << 8) | (r << 16) | (a << 24);
        }
    }

    cairo_surface_t *imageSurface = cairo_image_surface_create_for_data(
        bitmapPixels,
        CAIRO_FORMAT_ARGB32,
        width,
        height,
        bytesPerRow
    );

    if (cairo_surface_status(imageSurface) != CAIRO_STATUS_SUCCESS) {
        NSLog(@"Failed to create Cairo image surface for titlebar transfer");
        cairo_surface_destroy(imageSurface);
        cairo_destroy(ctx);
        cairo_surface_destroy(x11Surface);
        return NO;
    }

    NSLog(@"Painting GSTheme image to X11 surface...");

    // Paint GSTheme image to X11 surface using SOURCE operator
    // SOURCE completely replaces destination pixels with source (including alpha values)
    // The X11 compositor then uses those alpha values when compositing windows
    // This works for both compositor and non-compositor modes
    cairo_set_operator(ctx, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_surface(ctx, imageSurface, 0, 0);
    cairo_paint(ctx);
    cairo_surface_flush(x11Surface);

    // Force immediate X11 update to ensure GSTheme is visible
    [titlebar.connection flush];
    xcb_flush([titlebar.connection connection]);

    NSLog(@"GSTheme image painted and surface flushed");

    // Cleanup first surface
    cairo_surface_destroy(imageSurface);
    cairo_destroy(ctx);
    cairo_surface_destroy(x11Surface);

    // Paint DIMMED version to dPixmap (inactive pixmap) for unfocused windows
    // XCBWindow.drawArea uses isAbove ? pixmap : dPixmap
    xcb_pixmap_t dPixmap = [titlebar dPixmap];
    if (dPixmap != 0) {
        NSLog(@"Painting dimmed GSTheme to dPixmap (inactive pixmap): %u", dPixmap);

        // Create a dimmed version of the titlebar image for inactive state
        NSImage *dimmedImage = [self createDimmedImage:image];
        if (dimmedImage) {
            // Get bitmap from dimmed image
            NSBitmapImageRep *dimmedBitmap = nil;
            for (NSImageRep *rep in [dimmedImage representations]) {
                if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
                    dimmedBitmap = (NSBitmapImageRep*)rep;
                    break;
                }
            }
            if (!dimmedBitmap) {
                NSData *dimmedData = [dimmedImage TIFFRepresentation];
                dimmedBitmap = [NSBitmapImageRep imageRepWithData:dimmedData];
            }

            if (dimmedBitmap) {
                unsigned char *dimmedPixels = [dimmedBitmap bitmapData];
                int dimmedWidth = [dimmedBitmap pixelsWide];
                int dimmedHeight = [dimmedBitmap pixelsHigh];
                int dimmedBytesPerRow = [dimmedBitmap bytesPerRow];

                // Check bitmap format for dimmed image
                NSBitmapFormat dimmedFormat = [dimmedBitmap bitmapFormat];
                BOOL dimmedAlphaFirst = (dimmedFormat & NSAlphaFirstBitmapFormat) != 0;

                // Convert to Cairo ARGB32 format (BGRA in memory on little-endian)
                for (int y = 0; y < dimmedHeight; y++) {
                    uint32_t *rowPtr = (uint32_t *)(dimmedPixels + (y * dimmedBytesPerRow));
                    for (int x = 0; x < dimmedWidth; x++) {
                        uint32_t pixel = rowPtr[x];
                        uint32_t r, g, b, a;

                        if (dimmedAlphaFirst) {
                            // ARGB in memory
                            a = (pixel >> 0) & 0xFF;
                            r = (pixel >> 8) & 0xFF;
                            g = (pixel >> 16) & 0xFF;
                            b = (pixel >> 24) & 0xFF;
                        } else {
                            // RGBA in memory
                            r = (pixel >> 0) & 0xFF;
                            g = (pixel >> 8) & 0xFF;
                            b = (pixel >> 16) & 0xFF;
                            a = (pixel >> 24) & 0xFF;
                        }

                        // Pre-multiply RGB by alpha for Cairo ARGB32 format
                        if (a < 255) {
                            r = (r * a) / 255;
                            g = (g * a) / 255;
                            b = (b * a) / 255;
                        }

                        // Cairo ARGB32 on little-endian: B, G, R, A bytes
                        rowPtr[x] = b | (g << 8) | (r << 16) | (a << 24);
                    }
                }

                // Use ARGB visual for dPixmap when compositor is active
                cairo_surface_t *dSurface = cairo_xcb_surface_create(
                    [titlebar.connection connection],
                    dPixmap,
                    visualType,  // Uses ARGB visual when compositor active
                    dimmedWidth,
                    dimmedHeight
                );

                if (cairo_surface_status(dSurface) == CAIRO_STATUS_SUCCESS) {
                    cairo_t *dCtx = cairo_create(dSurface);

                    cairo_surface_t *dImageSurface = cairo_image_surface_create_for_data(
                        dimmedPixels,
                        CAIRO_FORMAT_ARGB32,
                        dimmedWidth,
                        dimmedHeight,
                        dimmedBytesPerRow
                    );

                    if (cairo_surface_status(dImageSurface) == CAIRO_STATUS_SUCCESS) {
                        // Use SOURCE to replace destination with source (including alpha)
                        cairo_set_operator(dCtx, CAIRO_OPERATOR_SOURCE);
                        cairo_set_source_surface(dCtx, dImageSurface, 0, 0);
                        cairo_paint(dCtx);
                        cairo_surface_flush(dSurface);
                        NSLog(@"Dimmed GSTheme painted to dPixmap successfully");
                    }

                    cairo_surface_destroy(dImageSurface);
                    cairo_destroy(dCtx);
                }
                cairo_surface_destroy(dSurface);
            }
        }
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

#pragma mark - GSTheme Method Swizzling Implementations

// These methods replace XCBTitleBar's drawing methods
- (void)gstheme_drawTitleBarComponentsPixmaps {
    // Replace XCBTitleBar's Cairo drawing with GSTheme
    NSLog(@"GSTheme: Replacing drawTitleBarComponentsPixmaps with GSTheme rendering");

    XCBTitleBar *titlebar = (XCBTitleBar*)self;
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:YES];
}

- (void)gstheme_drawTitleBarComponents {
    // Replace XCBTitleBar's Cairo drawing with GSTheme
    NSLog(@"GSTheme: Replacing drawTitleBarComponents with GSTheme rendering");

    XCBTitleBar *titlebar = (XCBTitleBar*)self;
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:YES];
}

- (void)gstheme_drawTitleBarForColor:(TitleBarColor)aColor {
    // Replace XCBTitleBar's Cairo drawing with GSTheme
    NSLog(@"GSTheme: Replacing drawTitleBarForColor: with GSTheme rendering");

    XCBTitleBar *titlebar = (XCBTitleBar*)self;
    BOOL isActive = (aColor == TitleBarUpColor);
    [URSThemeIntegration renderGSThemeTitlebar:titlebar
                                         title:titlebar.windowTitle
                                        active:isActive];
}

+ (BOOL)renderGSThemeToWindow:(XCBWindow*)window
                        frame:(XCBFrame*)frame
                        title:(NSString*)title
                       active:(BOOL)isActive {

    if (![[URSThemeIntegration sharedInstance] enabled] || !window || !frame) {
        return NO;
    }

    GSTheme *theme = [self currentTheme];
    if (!theme) {
        NSLog(@"Warning: No GSTheme available for standalone titlebar rendering");
        return NO;
    }

    @try {
        // Get the frame's titlebar area
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow || ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            NSLog(@"Warning: No titlebar found in frame for GSTheme rendering");
            return NO;
        }
        XCBTitleBar *titlebar = (XCBTitleBar*)titlebarWindow;

        // Get titlebar dimensions - use frame width to ensure titlebar spans full window
        XCBRect titlebarRect = [titlebar windowRect];
        XCBRect frameRect = [frame windowRect];

        // DEBUG: Add 2 pixels to width and shift 1 pixel left to cover both edges
        uint16_t targetWidth = frameRect.size.width + 2;
        int16_t targetX = -1;  // Shift titlebar 1 pixel left
        NSDebugLog(@"DEBUG: Resizing titlebar X11 window to %d at x=%d (frame=%d, current titlebar=%d)",
              targetWidth, targetX, frameRect.size.width, titlebarRect.size.width);

        uint32_t values[2] = {(uint32_t)targetX, targetWidth};
        xcb_configure_window([[frame connection] connection],
                             [titlebar window],
                             XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_WIDTH,
                             values);

        // Update the titlebar's internal rect
        titlebarRect.size.width = targetWidth;
        [titlebar setWindowRect:titlebarRect];

        // Recreate the pixmap with the new size
        [titlebar createPixmap];

        [[frame connection] flush];

        // Use frame width to ensure titlebar matches window width exactly
        // DEBUG: Add 2 pixels (1 on each side) to cover both edges
        NSSize titlebarSize = NSMakeSize(frameRect.size.width + 2, titlebarRect.size.height);
        NSDebugLog(@"DEBUG: Using titlebarSize.width = %d (frame was %d)", (int)titlebarSize.width, (int)frameRect.size.width);

        // DEBUG: Also get client window dimensions for comparison
        XCBWindow *clientWin = [frame childWindowForKey:ClientWindow];
        XCBRect clientRect = clientWin ? [clientWin windowRect] : XCBMakeRect(XCBMakePoint(0,0), XCBMakeSize(0,0));
        NSLog(@"DEBUG DIMENSIONS: frame=%dx%d, titlebar=%dx%d, client=%dx%d",
              (int)frameRect.size.width, (int)frameRect.size.height,
              (int)titlebarRect.size.width, (int)titlebarRect.size.height,
              (int)clientRect.size.width, (int)clientRect.size.height);

        NSLog(@"Rendering standalone GSTheme titlebar: %dx%d (frame: %dx%d) for window %u",
              (int)titlebarSize.width, (int)titlebarSize.height,
              (int)frameRect.size.width, (int)frameRect.size.height, [window window]);

        // Create NSImage for GSTheme to render into
        NSImage *titlebarImage = [[NSImage alloc] initWithSize:titlebarSize];

        [titlebarImage lockFocus];
        
        // Set up the graphics state for theme drawing
        NSGraphicsContext *gctx = [NSGraphicsContext currentContext];
        [gctx saveGraphicsState];

        // Use GSTheme to draw titlebar decoration
        NSRect drawRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);

        // Check if this is a fixed-size window (hide resize but show minimize when supported)
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        xcb_window_t clientWindowId = clientWindow ? [clientWindow window] : 0;
        BOOL isFixedSize = clientWindowId && [URSThemeIntegration isFixedSizeWindow:clientWindowId];

        // Base style: title only
        NSUInteger styleMask = NSTitledWindowMask;

        // Determine whether control buttons should be shown. Require both canClose
        // and presence of WM_DELETE_WINDOW (ICCCM WMProtocols) to consider close functional.
        BOOL showControls = NO;
        if (clientWindow && [clientWindow canClose]) {
            ICCCMService *icccm = [ICCCMService sharedInstanceWithConnection:[frame connection]];
            if ([icccm hasProtocol:[icccm WMDeleteWindow] forWindow:clientWindow]) {
                showControls = YES;
            }
        }

        if (showControls) {
            styleMask |= NSClosableWindowMask;

            // If not fixed-size, include resize button
            if (!isFixedSize) {
                styleMask |= NSResizableWindowMask;
            }

            // If the client supports minimization, include miniaturize button
            if ([clientWindow respondsToSelector:@selector(canMinimize)] && [clientWindow canMinimize]) {
                styleMask |= NSMiniaturizableWindowMask;
            }
        }

        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        NSLog(@"Drawing standalone GSTheme titlebar with styleMask: 0x%lx, state: %d (fixedSize=%d, mini=%d)", (unsigned long)styleMask, (int)state, (int)isFixedSize, clientWindow ? (int)[clientWindow canMinimize] : 0);

        // Log GSTheme padding and size values to verify Eau theme values
        if ([theme respondsToSelector:@selector(titlebarPaddingLeft)]) {
            NSLog(@"GSTheme titlebarPaddingLeft: %.1f", [theme titlebarPaddingLeft]);
        }
        if ([theme respondsToSelector:@selector(titlebarPaddingRight)]) {
            NSLog(@"GSTheme titlebarPaddingRight: %.1f", [theme titlebarPaddingRight]);
        }
        if ([theme respondsToSelector:@selector(titlebarPaddingTop)]) {
            NSLog(@"GSTheme titlebarPaddingTop: %.1f", [theme titlebarPaddingTop]);
        }
        if ([theme respondsToSelector:@selector(titlebarButtonSize)]) {
            NSLog(@"GSTheme titlebarButtonSize: %.1f", [theme titlebarButtonSize]);
        }
        NSLog(@"Expected Eau values: paddingLeft=2, paddingRight=2, paddingTop=6, buttonSize=13");

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
                    NSLog(@"Theme font name: %@", themeFontName);
                }
                if (fontSize) {
                    themeFontSize = [fontSize floatValue];
                    NSLog(@"Theme font size: %.1f", themeFontSize);
                }
            }
        }

        // Set the font for titlebar text rendering
        NSFont *titlebarFont = [NSFont fontWithName:themeFontName size:themeFontSize];
        if (!titlebarFont) {
            // Fallback if LuxiSans is not available
            titlebarFont = [NSFont systemFontOfSize:themeFontSize];
            NSLog(@"Using system font fallback at size %.1f (LuxiSans not available)", themeFontSize);
        } else {
            NSLog(@"Using theme font: %@ %.1f", themeFontName, themeFontSize);
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
            NSLog(@"[URSThemeIntegration] Using transparent prefill for compositor alpha support");
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

        // *** BUTTON DRAWING ***
        // Draw buttons: Close (X) on left | title | Minimize (-) | Maximize (+) on right
        // Layout: Close=28x24, Maximize=28x24, Minimize=28x24 (all full height, side-by-side)

        NSLog(@"Drawing side-by-side edge buttons for theme: %@", [theme name]);

        CGFloat titlebarWidth = titlebarSize.width;
        CGFloat buttonHeight = titlebarSize.height;  // Full height for close button
        NSColor *iconColor = [self iconColorForActive:isActive highlighted:NO];

        BOOL hasMaximize = (styleMask & NSResizableWindowMask) != 0;
        BOOL hasMinimize = (styleMask & NSMiniaturizableWindowMask) != 0;

        // Check if this titlebar is being hovered
        xcb_window_t titlebarId = [titlebar window];
        BOOL isTitlebarHovered = (titlebarId == hoveredTitlebarWindow);
        NSInteger hoverIdx = isTitlebarHovered ? hoveredButtonIndex : -1;

        // Close button at left edge (full height)
        if (styleMask & NSClosableWindowMask) {
            NSRect closeFrame = NSMakeRect(0, 0, EDGE_BUTTON_WIDTH, buttonHeight);
            BOOL closeHovered = (hoverIdx == 0);

            // Draw button background
            [self drawEdgeButtonInRect:closeFrame
                              position:TitleBarButtonPositionLeft
                            buttonType:0
                                active:isActive
                               hovered:closeHovered];

            // Draw X icon (only on active windows)
            if (iconColor) {
                NSRect iconRect = NSInsetRect(closeFrame, ICON_INSET, ICON_INSET);
                [self drawCloseIconInRect:iconRect withColor:iconColor];
            }

            NSLog(@"Drew close button at: %@ hovered:%d", NSStringFromRect(closeFrame), closeHovered);
        }

        // Side-by-side buttons on right: Minimize (-) inner, Maximize (+) outer
        if (hasMinimize) {
            // Minimize button (inner right when maximize exists, far right alone)
            NSRect miniFrame;
            TitleBarButtonPosition miniPosition;
            BOOL miniHovered = (hoverIdx == 1);

            if (hasMaximize) {
                miniFrame = NSMakeRect(titlebarWidth - 2 * RIGHT_BUTTON_WIDTH,
                                       0,
                                       RIGHT_BUTTON_WIDTH,
                                       buttonHeight);
                miniPosition = TitleBarButtonPositionRightInner;
            } else {
                // No maximize: minimize takes far right alone
                miniFrame = NSMakeRect(titlebarWidth - RIGHT_BUTTON_WIDTH,
                                       0,
                                       RIGHT_BUTTON_WIDTH,
                                       buttonHeight);
                miniPosition = TitleBarButtonPositionRightFull;
            }

            // Draw button background
            [self drawEdgeButtonInRect:miniFrame
                              position:miniPosition
                            buttonType:1
                                active:isActive
                               hovered:miniHovered];

            // Draw minus icon (only on active windows)
            if (iconColor) {
                NSRect iconRect = NSInsetRect(miniFrame, ICON_INSET, ICON_INSET);
                [self drawMinimizeIconInRect:iconRect withColor:iconColor];
            }

            NSLog(@"Drew miniaturize button at: %@ hovered:%d", NSStringFromRect(miniFrame), miniHovered);
        }

        if (hasMaximize) {
            // Zoom button (far right, full height)
            TitleBarButtonPosition zoomPosition = hasMinimize ? TitleBarButtonPositionRightOuter : TitleBarButtonPositionRightFull;
            NSRect zoomFrame = NSMakeRect(titlebarWidth - RIGHT_BUTTON_WIDTH,
                                          0,
                                          RIGHT_BUTTON_WIDTH,
                                          buttonHeight);
            BOOL zoomHovered = (hoverIdx == 2);

            // Draw button background
            [self drawEdgeButtonInRect:zoomFrame
                              position:zoomPosition
                            buttonType:2
                                active:isActive
                               hovered:zoomHovered];

            // Draw plus icon (only on active windows)
            if (iconColor) {
                NSRect iconRect = NSInsetRect(zoomFrame, ICON_INSET, ICON_INSET);
                [self drawMaximizeIconInRect:iconRect withColor:iconColor];
            }

            NSLog(@"Drew zoom button at: %@ hovered:%d", NSStringFromRect(zoomFrame), zoomHovered);
        }

        // Top highlight across title area (connecting button highlights)
        // First paint 1px opaque base matching the button gradient top color so
        // the semi-transparent highlight blends identically to the buttons.
        CGFloat highlightLeft = EDGE_BUTTON_WIDTH;
        CGFloat highlightRight = (hasMaximize && hasMinimize) ? (titlebarWidth - 2 * RIGHT_BUTTON_WIDTH) :
                                 (hasMaximize || hasMinimize) ? (titlebarWidth - RIGHT_BUTTON_WIDTH) : titlebarWidth;
        NSColor *titleBaseColor = isActive
            ? [NSColor colorWithCalibratedWhite:0.82 alpha:1.0]
            : [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
        [titleBaseColor setStroke];
        NSBezierPath *titleBase = [NSBezierPath bezierPath];
        [titleBase moveToPoint:NSMakePoint(highlightLeft, buttonHeight - 0.5)];
        [titleBase lineToPoint:NSMakePoint(highlightRight, buttonHeight - 0.5)];
        [titleBase setLineWidth:1.0];
        [titleBase stroke];

        NSColor *titleHighlightColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.35];
        [titleHighlightColor setStroke];
        NSBezierPath *titleHighlight = [NSBezierPath bezierPath];
        [titleHighlight moveToPoint:NSMakePoint(highlightLeft, buttonHeight - 0.5)];
        [titleHighlight lineToPoint:NSMakePoint(highlightRight, buttonHeight - 0.5)];
        [titleHighlight setLineWidth:1.0];
        [titleHighlight stroke];

        // Bottom edge and button dividers (#979797)
        NSColor *separatorColor = [NSColor colorWithCalibratedWhite:0.592 alpha:1.0];
        [separatorColor setStroke];

        // Full-width bottom edge
        NSBezierPath *bottomEdge = [NSBezierPath bezierPath];
        [bottomEdge moveToPoint:NSMakePoint(0, 0.5)];
        [bottomEdge lineToPoint:NSMakePoint(titlebarWidth, 0.5)];
        [bottomEdge setLineWidth:1.0];
        [bottomEdge stroke];

        // Vertical dividers at button boundaries
        NSBezierPath *dividers = [NSBezierPath bezierPath];
        // Right edge of close button
        if (styleMask & NSClosableWindowMask) {
            [dividers moveToPoint:NSMakePoint(EDGE_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(EDGE_BUTTON_WIDTH, buttonHeight)];
        }
        if (hasMaximize) {
            // Left edge of zoom button
            [dividers moveToPoint:NSMakePoint(titlebarWidth - 2 * RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarWidth - 2 * RIGHT_BUTTON_WIDTH, buttonHeight)];
            // Between zoom and minimize
            [dividers moveToPoint:NSMakePoint(titlebarWidth - RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarWidth - RIGHT_BUTTON_WIDTH, buttonHeight)];
        } else if (hasMinimize) {
            // Left edge of minimize button
            [dividers moveToPoint:NSMakePoint(titlebarWidth - RIGHT_BUTTON_WIDTH, 0)];
            [dividers lineToPoint:NSMakePoint(titlebarWidth - RIGHT_BUTTON_WIDTH, buttonHeight)];
        }
        [dividers setLineWidth:1.0];
        [dividers stroke];

        [titlebarImage unlockFocus];

        // Transfer the image to the titlebar
        BOOL success = [self transferImage:titlebarImage toTitlebar:titlebar];

        if (success) {
            NSLog(@"Standalone GSTheme titlebar rendered successfully for: %@", title);
        } else {
            NSLog(@"Failed to transfer standalone GSTheme titlebar for: %@", title);
        }

        return success;

    } @catch (NSException *exception) {
        NSLog(@"Standalone GSTheme titlebar rendering failed: %@", exception.reason);
        return NO;
    }
}

#pragma mark - Titlebar Management

+ (void)refreshAllTitlebars {
    URSThemeIntegration *integration = [URSThemeIntegration sharedInstance];

    if (!integration.enabled) {
        return;
    }

    for (XCBTitleBar *titlebar in integration.managedTitlebars) {
        // Determine if window is active (simplified for now)
        BOOL isActive = YES; // TODO: Implement proper active window detection

        [self renderGSThemeTitlebar:titlebar
                              title:titlebar.windowTitle
                             active:isActive];
    }

    NSLog(@"Refreshed %lu titlebars with GSTheme decorations", (unsigned long)[integration.managedTitlebars count]);
}

#pragma mark - Event Handlers

- (void)handleWindowCreated:(XCBTitleBar*)titlebar {
    if (!self.enabled || !titlebar) {
        return;
    }

    // Add to managed windows list
    if (![self.managedTitlebars containsObject:titlebar]) {
        [self.managedTitlebars addObject:titlebar];
        NSLog(@"Added titlebar to GSTheme management: %@", titlebar.windowTitle);
    }

    // Render GSTheme decoration
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
        NSLog(@"GSTheme integration enabled - XCBKit will skip Cairo button drawing");
        // Don't call refreshAllTitlebars here - let the periodic timer handle it
    } else {
        NSLog(@"GSTheme integration disabled - falling back to Cairo rendering");
    }
}

#pragma mark - Cleanup

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (void)disableXCBTitleBarDrawing:(XCBTitleBar*)titlebar {
    // This method was declared but not used in our independent implementation
    NSLog(@"URSThemeIntegration: disableXCBTitleBarDrawing called (not needed for independent system)");
}

@end