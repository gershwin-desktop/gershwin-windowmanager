//
//  XCBTitleBar.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 06/08/19.
//  Copyright (c) 2019 alex. All rights reserved.
//

#import "XCBTitleBar.h"
#import "URSThemeIntegration.h"

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
        NSLog(@"XCBTitleBar: Skipping XCB button generation - GSTheme will handle buttons");
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
        else
            NSLog(@"Shape extension not supported for window: %u", [hideWindowButton window]);

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
        else
            NSLog(@"Shape extension not supported for window: %u", [minimizeWindowButton window]);

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
        else
            NSLog(@"Shape extension not supported for window: %u", [maximizeWindowButton window]);
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

@end
