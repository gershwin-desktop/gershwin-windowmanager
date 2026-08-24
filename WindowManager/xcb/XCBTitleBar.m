//
//  XCBTitleBar.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 06/08/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBTitleBar.h"
#import "URSThemeIntegration.h"
#import <AppKit/AppKit.h>
#import <math.h>

// Scale factor mirroring the eau theme's GSWScaleFactor(): reads the
// GSScaleFraction user default, falls back to the screen's backing scale.
static inline CGFloat ShadeScaleFactor(void)
{
    CGFloat s = [[NSUserDefaults standardUserDefaults] floatForKey:@"GSScaleFactor"];
    if (s <= 0.0)
        s = [[NSScreen mainScreen] backingScaleFactor];
    if (s <= 0.0)
        s = 1.0;
    return s;
}

// Loose typing for the compositor (kept out via NSClassFromString lookup
// elsewhere in the xcb layer); call sites guard with respondsToSelector.
@protocol URSCompositorShadeAPI <NSObject>
- (void)invalidateWindowPixmap:(xcb_window_t)windowId;
- (void)repairRegionForWindow:(xcb_window_t)windowId;
@end

@implementation XCBTitleBar

@synthesize hideWindowButton;
@synthesize minimizeWindowButton;
@synthesize maximizeWindowButton;
@synthesize arc;
@synthesize hideButtonColor;
@synthesize minimizeButtonColor;
@synthesize maximizeButtonColor;
@synthesize titleBarUpColor;
@synthesize titleBarDownColor;
@synthesize ewmhService;
@synthesize titleIsSet;
@synthesize spinnerPhase;
@synthesize spinnerGC;
@synthesize spinnerDrawn;
@synthesize spinnerRenderFrame;


- (id) initWithFrame:(XCBFrame *)aFrame withConnection:(XCBConnection *)aConnection
{
    self = [super init];

    if (self == nil)
        return nil;

    windowMask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    
    [super setConnection:aConnection];

    ewmhService = [EWMHService sharedInstanceWithConnection:[super connection]];
    titleIsSet = NO;
    
    return self;
}

- (void) drawArcsForColor:(TitleBarColor)aColor
{
    // GSTheme handles button rendering — legacy path removed.
}

- (void) drawTitleBarForColor:(TitleBarColor)aColor
{
    // GSTheme handles titlebar background rendering — legacy path removed.
}

- (void) generateButtons
{
    // Check if GSTheme is active - if so, skip XCB button generation entirely
    if ([self isGSThemeActive]) {
        //NSLog(@"XCBTitleBar: Skipping XCB button generation - GSTheme will handle buttons");
        return;
    }

    XCBWindow *rootWindow = [parentWindow parentWindow];
    XCBScreen *screen = [rootWindow screen];
    XCBVisual *rootVisual = [[XCBVisual alloc] initWithVisualId:[screen screen]->root_visual];

    [rootVisual setVisualTypeForScreen:screen];
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t values[2];
    values[0] = [screen screen]->white_pixel;
    values[1] = XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_BUTTON_PRESS;

    BOOL shapeExtensionSupported;

    XCBFrame* frame = (XCBFrame*)parentWindow;

    if ([[frame childWindowForKey:ClientWindow] canClose])
    {
        hideWindowButton = [[super connection] createWindowWithDepth:XCB_COPY_FROM_PARENT
                                                    withParentWindow:self
                                                       withXPosition:5
                                                       withYPosition:5
                                                           withWidth:14
                                                          withHeight:14
                                                    withBorrderWidth:0
                                                        withXCBClass:XCB_WINDOW_CLASS_INPUT_OUTPUT
                                                        withVisualId:rootVisual
                                                       withValueMask:mask
                                                       withValueList:values
                                                      registerWindow:YES];

        [hideWindowButton setWindowMask:mask];
        [hideWindowButton setCanMove:NO];
        [hideWindowButton setIsCloseButton:YES];

        hideButtonColor = XCBMakeColor(0.411, 0.176, 0.673, 1); //original: 0.7 0.427 1 1

        shapeExtensionSupported = [[hideWindowButton shape] checkSupported];
        [[hideWindowButton shape] calculateDimensionsFromGeometries:[hideWindowButton geometries]];

        if (shapeExtensionSupported)
        {
            [[hideWindowButton shape] createPixmapsAndGCs];
            [[hideWindowButton shape] createArcsWithRadius:7];
        }
        //else
        //    NSLog(@"Shape extension not supported for window: %u", [hideWindowButton window]);

    }

    if ([[frame childWindowForKey:ClientWindow] canMinimize])
    {
        minimizeWindowButton = [[super connection] createWindowWithDepth:XCB_COPY_FROM_PARENT
                                                        withParentWindow:self
                                                           withXPosition:24
                                                           withYPosition:5
                                                               withWidth:14
                                                              withHeight:14
                                                        withBorrderWidth:0
                                                            withXCBClass:XCB_WINDOW_CLASS_INPUT_OUTPUT
                                                            withVisualId:rootVisual
                                                           withValueMask:mask
                                                           withValueList:values
                                                          registerWindow:YES];

        [minimizeWindowButton setWindowMask:mask];
        [minimizeWindowButton setCanMove:NO];
        [minimizeWindowButton setIsMinimizeButton:YES];

        minimizeButtonColor = XCBMakeColor(0.9,0.7,0.3,1);

        shapeExtensionSupported = [[minimizeWindowButton shape] checkSupported];
        [[minimizeWindowButton shape] calculateDimensionsFromGeometries:[minimizeWindowButton geometries]];

        if (shapeExtensionSupported)
        {
            [[minimizeWindowButton shape] createPixmapsAndGCs];
            [[minimizeWindowButton shape] createArcsWithRadius:7];
        }
        //else
        //    NSLog(@"Shape extension not supported for window: %u", [minimizeWindowButton window]);

    }

    if ([[frame childWindowForKey:ClientWindow] canFullscreen])
    {
        maximizeWindowButton = [[super connection] createWindowWithDepth:XCB_COPY_FROM_PARENT
                                                        withParentWindow:self
                                                           withXPosition:44
                                                           withYPosition:5
                                                               withWidth:14
                                                              withHeight:14
                                                        withBorrderWidth:0
                                                            withXCBClass:XCB_WINDOW_CLASS_INPUT_OUTPUT
                                                            withVisualId:rootVisual
                                                           withValueMask:mask
                                                           withValueList:values
                                                          registerWindow:YES];

        [maximizeWindowButton setWindowMask:mask];
        [maximizeWindowButton setCanMove:NO];
        [maximizeWindowButton setIsMaximizeButton:YES];

        maximizeButtonColor = XCBMakeColor(0,0.74,1,1);

        shapeExtensionSupported = [[maximizeWindowButton shape] checkSupported];
        [[maximizeWindowButton shape] calculateDimensionsFromGeometries:[maximizeWindowButton geometries]];

        if (shapeExtensionSupported)
        {
            [[maximizeWindowButton shape] createPixmapsAndGCs];
            [[maximizeWindowButton shape] createArcsWithRadius:7];
        }
        //else
        //    NSLog(@"Shape extension not supported for window: %u", [maximizeWindowButton window]);
    }

    [[super connection] mapWindow:hideWindowButton];
    [[super connection] mapWindow:minimizeWindowButton];
    [[super connection] mapWindow:maximizeWindowButton];
    [hideWindowButton onScreen];
    [minimizeWindowButton onScreen];
    [maximizeWindowButton onScreen];
    [hideWindowButton updateAttributes];
    [minimizeWindowButton updateAttributes];
    [maximizeWindowButton updateAttributes];
    [hideWindowButton createPixmap];
    [minimizeWindowButton createPixmap];
    [maximizeWindowButton createPixmap];

    screen = nil;
    rootVisual = nil;
    rootWindow = nil;
    frame = nil;
}

- (void)drawTitleBarComponents
{
    [super drawArea:[super windowRect]];

    // Check if GSTheme is active - if so, skip legacy button drawing
    if ([self isGSThemeActive]) {
        return;
    }

    XCBRect area = [hideWindowButton windowRect];
    area.position.x = 0;
    area.position.y = 0;
    [hideWindowButton drawArea:area];
    [maximizeWindowButton drawArea:area];
    [minimizeWindowButton drawArea:area];
    //TODO: window title??
}

- (void) drawTitleBarComponentsPixmaps
{
    // Check if GSTheme is active - if so, skip legacy titlebar and button drawing
    if ([self isGSThemeActive]) {
        return;
    }

    [self drawTitleBarForColor:TitleBarUpColor];
    [self drawTitleBarForColor:TitleBarDownColor];
    [self drawArcsForColor:TitleBarUpColor];
    [self drawArcsForColor:TitleBarDownColor];
    [self setWindowTitle:windowTitle];
}

- (void) setButtonsAbove:(BOOL)aValue
{
    [hideWindowButton setIsAbove:aValue];
    [minimizeWindowButton setIsAbove:aValue];
    [maximizeWindowButton setIsAbove:aValue];
}

- (void)putButtonsBackgroundPixmaps:(BOOL)aValue
{
    // Check if GSTheme is active - if so, skip legacy button background setup
    if ([self isGSThemeActive]) {
        return;
    }

    [hideWindowButton clearArea:[hideWindowButton windowRect] generatesExposure:NO];
    [minimizeWindowButton clearArea:[minimizeWindowButton windowRect] generatesExposure:NO];
    [hideWindowButton clearArea:[maximizeWindowButton windowRect] generatesExposure:NO];

    if (aValue)
    {
        [hideWindowButton putWindowBackgroundWithPixmap:[hideWindowButton pixmap]];
        [minimizeWindowButton putWindowBackgroundWithPixmap:[minimizeWindowButton pixmap]];
        [maximizeWindowButton putWindowBackgroundWithPixmap:[maximizeWindowButton pixmap]];
    }
    else
    {
        [hideWindowButton putWindowBackgroundWithPixmap:[hideWindowButton dPixmap]];
        [minimizeWindowButton putWindowBackgroundWithPixmap:[minimizeWindowButton dPixmap]];
        [maximizeWindowButton putWindowBackgroundWithPixmap:[maximizeWindowButton dPixmap]];
    }
}

- (void) setWindowTitle:(NSString *) title
{
    if (titleIsSet && windowTitle && [windowTitle isEqualToString:title])
        return;

    windowTitle = title;

    if ([title length] == 0)
        return;

    // GSTheme handles title text rendering — legacy path removed.
    titleIsSet = YES;
}

// OPTIMIZATION: Set internal title without legacy rendering
// Used when GSTheme will handle the actual titlebar rendering
- (void) setInternalTitle:(NSString *) title
{
    windowTitle = title;
    // Don't set titleIsSet here - allows setWindowTitle to work if needed later
}

- (NSString*) windowTitle
{
    return windowTitle;
}

- (xcb_arc_t*) arcs
{
    return arcs;
}

- (void) dealloc
{
    hideWindowButton = nil;
    minimizeWindowButton = nil;
    maximizeWindowButton = nil;
    ewmhService = nil;
}


- (BOOL)isGSThemeActive
{
    // Check current runtime state of GSTheme integration instead of relying on persisted
    // preferences. The window manager may not have a preferences file yet on first run.
    BOOL gsthemeEnabled = [[URSThemeIntegration sharedInstance] enabled];
    return gsthemeEnabled;
}

#pragma mark - Content-Activity Spinner

// Layout constants matching the eau theme titlebar (see AppearanceMetrics.h
// and URSThemeIntegration's local defines): the theme centers the title
// between the left orb region and the right button region.
#define SPINNER_ORB_REGION_WIDTH (68.0 * ShadeScaleFactor())
#define SPINNER_TITLE_FONT_SIZE (13.0 * ShadeScaleFactor())

// 8 spokes, unit direction vectors in 1/1000 (45 degree steps)
static const int SPINNER_DIR[8][2] = {
    {1000, 0}, {707, 707}, {0, 1000}, {-707, 707},
    {-1000, 0}, {-707, -707}, {0, -1000}, {707, -707}
};

// X position just after the drawn title text.  Mirrors the eau theme's
// centered-title layout so the glyph hugs the text end without the theme
// needing to know about us.
- (CGFloat)spinnerTargetX
{
    CGFloat scale = ShadeScaleFactor();
    CGFloat tbW = [self windowRect].size.width;
    CGFloat tbH = [self windowRect].size.height;

    BOOL orbStyle = [URSThemeIntegration isOrbButtonStyle];
    // Edge layout reserves the square close button (width == bar height) on
    // the left; orb layout reserves the orb region.
    CGFloat left = orbStyle ? SPINNER_ORB_REGION_WIDTH : tbH;

    XCBFrame *frame = nil;
    if ([[self parentWindow] isKindOfClass:[XCBFrame class]])
        frame = (XCBFrame *)[self parentWindow];
    XCBWindow *clientWindow = frame ? [frame childWindowForKey:ClientWindow] : nil;
    BOOL hasMaximize = clientWindow ? [clientWindow canResize] : YES;

    CGFloat rightReserve = orbStyle ? (6.0 * scale)
                                    : ((hasMaximize ? 2.0 : 1.0) * tbH);

    NSString *title = windowTitle ?: @"";
    // Measure with the SAME font the theme renders titles with (theme
    // bundle NSFont/NSFontSize, falling back to system font) - a system-font
    // estimate runs short and the spinner overlaps the last characters.
    NSString *themeFontName = @"LuxiSans";
    CGFloat themeFontSize = 13.0;
    GSTheme *theme = [URSThemeIntegration currentTheme];
    if (theme && [theme bundle] && [[theme bundle] infoDictionary]) {
        NSString *fontName = [[theme bundle] infoDictionary][@"NSFont"];
        NSString *fontSize = [[theme bundle] infoDictionary][@"NSFontSize"];
        if (fontName) themeFontName = fontName;
        if (fontSize) themeFontSize = [fontSize floatValue];
    }
    NSFont *titleFont = [NSFont fontWithName:themeFontName
                                        size:themeFontSize * scale] ?:
                         [NSFont systemFontOfSize:SPINNER_TITLE_FONT_SIZE];
    CGFloat textW = [title sizeWithAttributes:
        @{ NSFontAttributeName: titleFont }].width;

    CGFloat workW = tbW - left - rightReserve;
    if (workW < 20.0)
        workW = 20.0;

    CGFloat centeredX = left + workW / 2.0 - textW / 2.0;
    CGFloat textLeft = MAX(centeredX, left);
    CGFloat textEnd = MIN(textLeft + textW, tbW - rightReserve);

    CGFloat x = textEnd + 8.0 * scale;
    return MIN(x, tbW - rightReserve - tbH);
}

// Draw the current spinner phase into the TITLEBAR's own pixmap and blit
// just the spinner rectangle through the normal drawArea pipeline.  No
// child window: the themed bar stays the single source of truth and the
// compositor sees an ordinary titlebar update.
- (void)drawSpinnerPhase:(int)phase
{
    if ([self isGSThemeActive])
    {
        // Theme path: let renderGSThemeToWindow overlay the theme spinner
        // frame (common_ProgressSpinning_N) after the title text.  Blending,
        // dPixmap sync and compositor notification stay in the existing
        // render pipeline.
        self.spinnerRenderFrame = phase % 8;
        XCBFrame *frame = nil;
        if ([[self parentWindow] isKindOfClass:[XCBFrame class]])
            frame = (XCBFrame *)[self parentWindow];
        if (frame)
            [URSThemeIntegration renderGSThemeToWindow:self
                                                frame:frame
                                                title:windowTitle
                                               active:[self isAbove]];
        return;
    }

    // Legacy (non-GSTheme) path: hand-drawn spokes straight into the pixmap.
    if (phase < 0)
        [self drawTitleBarComponents];
    xcb_pixmap_t pix = [self isAbove] ? [self pixmap] : [self dPixmap];
    if (!pix || !self.connection)
        return;

    xcb_connection_t *conn = [self.connection connection];

    if (self.spinnerGC == 0)
    {
        self.spinnerGC = xcb_generate_id(conn);
        xcb_create_gc(conn, self.spinnerGC, pix, 0, NULL);
    }

    CGFloat scale = ShadeScaleFactor();
    CGFloat originX = [self spinnerTargetX];
    CGFloat tbH = [self windowRect].size.height;
    int16_t rx = (int16_t)originX;
    int16_t ry = (int16_t)((tbH - 14.0 * scale) / 2.0);
    int16_t size = (int16_t)(14.0 * scale);
    if (size < 8) size = 8;
    int16_t center = size / 2;
    int16_t rOut = (int16_t)(size / 2 - 1.0 * scale);
    int16_t rIn = (int16_t)(rOut - 2.5 * scale);
    if (rIn < 1) rIn = 1;

    const uint32_t grays[8] = { 0xFF1a1a1a, 0xFF333333, 0xFF4d4d4d, 0xFF666666,
                                0xFF808080, 0xFF999999, 0xFFb3b3b3, 0xFFd0d0d0 };

    for (int i = 0; i < 8; i++)
    {
        int spoke = (phase + i) % 8;
        int dx = SPINNER_DIR[spoke][0];
        int dy = SPINNER_DIR[spoke][1];

        xcb_segment_t seg[1] = {{
            (int16_t)(center + rx + dx * rIn / 1000),
            (int16_t)(center + ry + dy * rIn / 1000),
            (int16_t)(center + rx + dx * rOut / 1000),
            (int16_t)(center + ry + dy * rOut / 1000)
        }};

        uint32_t fg = grays[i];
        xcb_change_gc(conn, self.spinnerGC, XCB_GC_FOREGROUND, &fg);
        xcb_poly_segment(conn, pix, self.spinnerGC, 1, seg);
    }

    XCBRect blit = XCBMakeRect(XCBMakePoint(rx, ry),
                               XCBMakeSize((uint16_t)size + 1, (uint16_t)size + 1));
    [self drawArea:blit];

    Class compositorClass = NSClassFromString(@"URSCompositingManager");
    if (compositorClass && [compositorClass respondsToSelector:@selector(sharedManager)])
    {
        id<URSCompositorShadeAPI> spinnerCompositor =
            [compositorClass performSelector:@selector(sharedManager)];
        if (spinnerCompositor)
        {
            if ([spinnerCompositor respondsToSelector:@selector(invalidateWindowPixmap:)])
                [spinnerCompositor invalidateWindowPixmap:[self window]];
            if ([spinnerCompositor respondsToSelector:@selector(repairRegionForWindow:)])
                [spinnerCompositor repairRegionForWindow:[self window]];
        }
    }

    xcb_flush(conn);
}

- (void)updateSpinnerForActivity:(BOOL)active
{
    if (active)
    {
        self.spinnerPhase = (self.spinnerPhase + 1) % 8;
        [self drawSpinnerPhase:self.spinnerPhase];
        self.spinnerDrawn = YES;
    }
    else if (self.spinnerDrawn)
    {
        // Activity window closed: render the clean bar once (spinner frame
        // -1 draws nothing).
        self.spinnerDrawn = NO;
        [self drawSpinnerPhase:-1];
    }
}

@end
