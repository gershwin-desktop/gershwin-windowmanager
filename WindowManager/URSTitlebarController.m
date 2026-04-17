//
//  URSTitlebarController.m
//  uroswm - Titlebar Interaction Controller
//
//  Handles titlebar button hit-testing, hover state, button press actions
//  (close/minimize/maximize), and resize-during-motion rendering updates.
//

#import "URSTitlebarController.h"
#import "URSProfiler.h"
#import "URSThemeIntegration.h"
#import "URSCompositingManager.h"

@implementation URSTitlebarController

- (instancetype)initWithConnection:(XCBConnection *)aConnection
{
    self = [super init];
    if (!self) return nil;

    _connection = aConnection;

    return self;
}

#pragma mark - Button Hit Detection

- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point
                          forTitlebar:(XCBTitleBar *)titlebar
{
    static const CGFloat ORB_SIZE = 15.0;
    static const CGFloat ORB_PAD_LEFT = 10.5;
    static const CGFloat ORB_SPACING = 4.0;

    XCBRect titlebarRect = [titlebar windowRect];
    CGFloat titlebarWidth = titlebarRect.size.width;
    CGFloat titlebarHeight = titlebarRect.size.height;

    XCBFrame *frame = nil;
    if ([[titlebar parentWindow] isKindOfClass:[XCBFrame class]]) {
        frame = (XCBFrame *)[titlebar parentWindow];
    }

    XCBWindow *clientWindow = frame ? [frame childWindowForKey:ClientWindow] : nil;
    xcb_window_t clientWindowId = clientWindow ? [clientWindow window] : 0;
    BOOL isFixedSize = clientWindowId &&
        [URSThemeIntegration isFixedSizeWindow:clientWindowId];
    BOOL hasMaximize = !isFixedSize;

    if ([URSThemeIntegration isOrbButtonStyle]) {
        CGFloat buttonY = (titlebarHeight - ORB_SIZE) / 2.0;
        CGFloat closeX = ORB_PAD_LEFT;
        CGFloat miniX = closeX + ORB_SIZE + ORB_SPACING;
        CGFloat zoomX = miniX + ORB_SIZE + ORB_SPACING;

        if (NSPointInRect(point, NSMakeRect(closeX, buttonY, ORB_SIZE, ORB_SIZE))) {
            return GSThemeTitleBarButtonClose;
        }
        if (NSPointInRect(point, NSMakeRect(miniX, buttonY, ORB_SIZE, ORB_SIZE))) {
            return GSThemeTitleBarButtonMiniaturize;
        }
        if (hasMaximize &&
            NSPointInRect(point, NSMakeRect(zoomX, buttonY, ORB_SIZE, ORB_SIZE))) {
            return GSThemeTitleBarButtonZoom;
        }

        return GSThemeTitleBarButtonNone;
    }

    // Edge layout: Close at left | title | Minimize | Maximize at right
    if (NSPointInRect(point, NSMakeRect(0, 0, titlebarHeight, titlebarHeight))) {
        return GSThemeTitleBarButtonClose;
    }

    if (hasMaximize) {
        NSRect miniRect = NSMakeRect(titlebarWidth - 2 * titlebarHeight, 0,
                                     titlebarHeight, titlebarHeight);
        if (NSPointInRect(point, miniRect)) {
            return GSThemeTitleBarButtonMiniaturize;
        }

        NSRect zoomRect = NSMakeRect(titlebarWidth - titlebarHeight, 0,
                                     titlebarHeight, titlebarHeight);
        if (NSPointInRect(point, zoomRect)) {
            return GSThemeTitleBarButtonZoom;
        }
    } else {
        NSRect miniRect = NSMakeRect(titlebarWidth - titlebarHeight, 0,
                                     titlebarHeight, titlebarHeight);
        if (NSPointInRect(point, miniRect)) {
            return GSThemeTitleBarButtonMiniaturize;
        }
    }

    return GSThemeTitleBarButtonNone;
}

#pragma mark - Button Press Handling

- (BOOL)handleTitlebarButtonPress:(xcb_button_press_event_t *)pressEvent
{
    @try {
        XCBWindow *window = [self.connection windowForXCBId:pressEvent->event];
        if (!window || ![window isKindOfClass:[XCBTitleBar class]]) {
            return NO;
        }

        XCBTitleBar *titlebar = (XCBTitleBar *)window;

        // Right-click is handled by the tiling menu controller, not here
        if (pressEvent->detail == 3) {
            return NO;
        }

        NSPoint clickPoint = NSMakePoint(pressEvent->event_x, pressEvent->event_y);
        GSThemeTitleBarButton button = [self buttonAtPoint:clickPoint
                                             forTitlebar:titlebar];

        if (button == GSThemeTitleBarButtonNone) {
            return NO;
        }

        // Release the implicit grab
        xcb_allow_events([self.connection connection],
                         XCB_ALLOW_ASYNC_POINTER, pressEvent->time);

        XCBFrame *frame = (XCBFrame *)[titlebar parentWindow];
        if (!frame || ![frame isKindOfClass:[XCBFrame class]]) {
            NSLog(@"GSTheme: Could not find frame for titlebar button action");
            return NO;
        }

        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];

        switch (button) {
            case GSThemeTitleBarButtonClose:
                NSLog(@"GSTheme: Close button clicked");
                if (clientWindow) {
                    [clientWindow close];
                    [frame setNeedDestroy:YES];
                }
                break;

            case GSThemeTitleBarButtonMiniaturize:
                NSLog(@"GSTheme: Minimize button clicked");
                [frame minimize];
                break;

            case GSThemeTitleBarButtonZoom:
                [self handleZoomForFrame:frame
                                titlebar:titlebar
                            clientWindow:clientWindow];
                break;

            default:
                return NO;
        }

        // Clean up grab/drag state
        [titlebar ungrabPointer];
        self.connection.dragState = NO;
        self.connection.resizeState = NO;

        [self.connection flush];
        return YES;

    } @catch (NSException *exception) {
        NSLog(@"Exception handling titlebar button press: %@", exception.reason);
        return NO;
    }
}

- (void)handleZoomForFrame:(XCBFrame *)frame
                  titlebar:(XCBTitleBar *)titlebar
              clientWindow:(XCBWindow *)clientWindow
{
    NSLog(@"GSTheme: Zoom button clicked, frame isMaximized: %d",
          [frame isMaximized]);

    if ([frame isMaximized]) {
        // Restore from maximized
        NSLog(@"GSTheme: Restoring window from maximized state");
        XCBRect startRect = [frame windowRect];
        XCBRect restoredRect = [frame oldRect];

        [frame programmaticResizeToRect:restoredRect];
        [frame setFullScreen:NO];
        [titlebar setFullScreen:NO];
        if (clientWindow) {
            [clientWindow setFullScreen:NO];
        }
        [frame setIsMaximized:NO];

        [titlebar destroyPixmap];
        [titlebar createPixmap];

        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:[titlebar windowTitle]
                                            active:YES];

        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];

        [frame updateAllResizeZonePositions];
        [frame applyRoundedCornersShapeMask];

        [self animateTransition:frame
                       fromRect:startRect
                         toRect:[frame windowRect]];

        NSLog(@"GSTheme: Restore complete, titlebar redrawn");
    } else {
        // Maximize
        NSLog(@"GSTheme: Maximizing window");
        XCBRect startRect = [frame windowRect];

        [frame setOldRect:startRect];
        [titlebar setOldRect:[titlebar windowRect]];
        if (clientWindow) {
            [clientWindow setOldRect:[clientWindow windowRect]];
        }

        NSRect workarea = [self.workareaManager currentWorkarea];
        XCBRect targetRect = XCBMakeRect(
            XCBMakePoint((int32_t)workarea.origin.x,
                         (int32_t)workarea.origin.y),
            XCBMakeSize((uint32_t)workarea.size.width,
                        (uint32_t)workarea.size.height));

        [frame programmaticResizeToRect:targetRect];
        [frame setFullScreen:YES];
        [frame setIsMaximized:YES];
        [titlebar setFullScreen:YES];
        if (clientWindow) {
            [clientWindow setFullScreen:YES];
        }

        [titlebar destroyPixmap];
        [titlebar createPixmap];

        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:[titlebar windowTitle]
                                            active:YES];

        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];

        [frame updateAllResizeZonePositions];
        [frame applyRoundedCornersShapeMask];

        [self animateTransition:frame
                       fromRect:startRect
                         toRect:[frame windowRect]];

        NSLog(@"GSTheme: Maximize complete, titlebar redrawn at new size");
    }
}

- (void)animateTransition:(XCBFrame *)frame
                 fromRect:(XCBRect)startRect
                   toRect:(XCBRect)endRect
{
    if (self.compositingManager &&
        [self.compositingManager compositingActive] &&
        [self.compositingManager respondsToSelector:
            @selector(animateWindowTransition:fromRect:toRect:duration:fade:)]) {
        [self.compositingManager animateWindowTransition:[frame window]
                                               fromRect:startRect
                                                 toRect:endRect
                                               duration:0.22
                                                   fade:NO];
    }
}

#pragma mark - Hover Handling

- (void)handleHoverDuringMotion:(xcb_motion_notify_event_t *)motionEvent
{
    URS_PROFILE_BEGIN(titlebarHover);
    @try {
        if ([self.connection dragState] || [self.connection resizeState]) {
            return;
        }

        XCBWindow *window = [self.connection windowForXCBId:motionEvent->event];
        if (!window) return;

        if (![window isKindOfClass:[XCBTitleBar class]]) {
            if ([URSThemeIntegration hoveredTitlebarWindow] != 0) {
                xcb_window_t prevTitlebar =
                    [URSThemeIntegration hoveredTitlebarWindow];
                [URSThemeIntegration clearHoverState];
                [self redrawTitlebarById:prevTitlebar];
            }
            return;
        }

        XCBTitleBar *titlebar = (XCBTitleBar *)window;
        xcb_window_t titlebarId = [titlebar window];
        XCBFrame *frame = (XCBFrame *)[titlebar parentWindow];
        if (!frame) return;

        // Reset cursor to normal arrow when over titlebar
        if (![[frame cursor] leftPointerSelected]) {
            [frame showLeftPointerCursor];
        }

        XCBRect frameRect = [frame windowRect];
        XCBRect titlebarRect = [titlebar windowRect];
        CGFloat titlebarWidth = frameRect.size.width;
        CGFloat titlebarHeight = titlebarRect.size.height;

        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        xcb_window_t clientWindowId = clientWindow ? [clientWindow window] : 0;
        BOOL hasMaximize = clientWindowId ?
            ![URSThemeIntegration isFixedSizeWindow:clientWindowId] : YES;

        CGFloat mouseX = motionEvent->event_x;
        CGFloat mouseY = motionEvent->event_y;
        NSInteger newButtonIndex =
            [URSThemeIntegration buttonIndexAtX:mouseX
                                              y:mouseY
                                       forWidth:titlebarWidth
                                         height:titlebarHeight
                                    hasMaximize:hasMaximize];

        xcb_window_t prevTitlebar = [URSThemeIntegration hoveredTitlebarWindow];
        NSInteger prevButtonIndex = [URSThemeIntegration hoveredButtonIndex];

        if (titlebarId != prevTitlebar || newButtonIndex != prevButtonIndex) {
            [URSThemeIntegration setHoveredTitlebar:titlebarId
                                        buttonIndex:newButtonIndex];

            [self redrawTitlebar:titlebar inFrame:frame];

            if (prevTitlebar != 0 && prevTitlebar != titlebarId) {
                [self redrawTitlebarById:prevTitlebar];
            }
        }

    } @catch (NSException *exception) {
        // Silently ignore exceptions during hover handling
    }
    URS_PROFILE_END(titlebarHover);
}

- (void)handleTitlebarLeave:(xcb_leave_notify_event_t *)leaveEvent
{
    @try {
        xcb_window_t leavingWindow = leaveEvent->event;
        xcb_window_t hoveredTitlebar =
            [URSThemeIntegration hoveredTitlebarWindow];

        if (leavingWindow == hoveredTitlebar && hoveredTitlebar != 0) {
            [URSThemeIntegration clearHoverState];
            [self redrawTitlebarById:leavingWindow];
        }
    } @catch (NSException *exception) {
        // Silently ignore
    }
}

#pragma mark - Titlebar Redraw

- (void)redrawTitlebar:(XCBTitleBar *)titlebar inFrame:(XCBFrame *)frame
{
    if (!titlebar || !frame) return;

    XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
    NSString *title = [titlebar windowTitle];
    BOOL isActive = [titlebar isAbove];

    [URSThemeIntegration renderGSThemeToWindow:clientWindow
                                         frame:frame
                                         title:title
                                        active:isActive];

    XCBRect rect = [titlebar windowRect];
    [titlebar drawArea:rect];
    [self.connection flush];
}

- (void)redrawTitlebarById:(xcb_window_t)titlebarId
{
    @try {
        XCBWindow *window = [self.connection windowForXCBId:titlebarId];
        if (!window || ![window isKindOfClass:[XCBTitleBar class]]) return;
        XCBTitleBar *titlebar = (XCBTitleBar *)window;
        XCBFrame *frame = (XCBFrame *)[titlebar parentWindow];
        [self redrawTitlebar:titlebar inFrame:frame];
    } @catch (NSException *exception) {
        // Silently ignore
    }
}

- (void)rerenderTitlebarForFrame:(XCBFrame *)frame active:(BOOL)isActive
{
    if (!frame) return;

    @try {
        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow ||
            ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar *)titlebarWindow;

        [URSThemeIntegration renderGSThemeToWindow:frame
                                             frame:frame
                                             title:[titlebar windowTitle]
                                            active:isActive];

        [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
        [titlebar drawArea:[titlebar windowRect]];
        [self.connection flush];

    } @catch (NSException *exception) {
        NSLog(@"Exception in rerenderTitlebarForFrame: %@", exception.reason);
    }
}

#pragma mark - Resize Rendering

- (void)handleResizeDuringMotion:(xcb_motion_notify_event_t *)motionEvent
{
    URS_PROFILE_BEGIN(titlebarResize);
    @try {
        XCBWindow *window = [self.connection windowForXCBId:motionEvent->event];
        if (!window) return;

        XCBFrame *frame = nil;
        if ([window isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame *)window;
        }
        if (!frame) return;

        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow ||
            ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar *)titlebarWindow;

        XCBRect titlebarRect = [titlebar windowRect];
        XCBSize pixmapSize = [titlebar pixmapSize];

        if (pixmapSize.width != titlebarRect.size.width) {
            xcb_pixmap_t oldPixmap = [titlebar pixmap];
            xcb_pixmap_t oldDPixmap = [titlebar dPixmap];

            [titlebar createPixmap];

            [URSThemeIntegration renderGSThemeToWindow:frame
                                                 frame:frame
                                                 title:[titlebar windowTitle]
                                                active:YES];

            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];

            if (oldPixmap != 0) {
                xcb_free_pixmap([self.connection connection], oldPixmap);
            }
            if (oldDPixmap != 0) {
                xcb_free_pixmap([self.connection connection], oldDPixmap);
            }

            [titlebar drawArea:titlebarRect];

            if (self.compositingManager &&
                [self.compositingManager compositingActive]) {
                [self.compositingManager updateWindow:[frame window]];
            }
        } else {
            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
            [titlebar drawArea:titlebarRect];
        }
    } @catch (NSException *exception) {
        // Silently ignore exceptions during resize motion
    }
    URS_PROFILE_END(titlebarResize);
}

- (void)handleResizeComplete:(xcb_button_release_event_t *)releaseEvent
{
    @try {
        XCBWindow *window = [self.connection windowForXCBId:releaseEvent->event];
        if (!window) return;

        XCBFrame *frame = nil;
        if ([window isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame *)window;
        } else if ([window parentWindow] &&
                   [[window parentWindow] isKindOfClass:[XCBFrame class]]) {
            frame = (XCBFrame *)[window parentWindow];
        }
        if (!frame) return;

        XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];
        if (!titlebarWindow ||
            ![titlebarWindow isKindOfClass:[XCBTitleBar class]]) {
            return;
        }
        XCBTitleBar *titlebar = (XCBTitleBar *)titlebarWindow;

        XCBRect titlebarRect = [titlebar windowRect];
        XCBSize pixmapSize = [titlebar pixmapSize];

        if (pixmapSize.width != titlebarRect.size.width ||
            pixmapSize.height != titlebarRect.size.height) {
            NSLog(@"GSTheme: Titlebar size changed from %dx%d to %dx%d, recreating pixmap",
                  pixmapSize.width, pixmapSize.height,
                  titlebarRect.size.width, titlebarRect.size.height);

            [titlebar destroyPixmap];
            [titlebar createPixmap];

            [URSThemeIntegration renderGSThemeToWindow:frame
                                                 frame:frame
                                                 title:[titlebar windowTitle]
                                                active:YES];

            [titlebar putWindowBackgroundWithPixmap:[titlebar pixmap]];
            [titlebar drawArea:[titlebar windowRect]];
            [self.connection flush];

            if (self.compositingManager &&
                [self.compositingManager compositingActive]) {
                [self.compositingManager updateWindow:[frame window]];
                [self.compositingManager damageScreen];
                [self.compositingManager performRepairNow];
            }
            NSLog(@"GSTheme: Titlebar redrawn after resize");
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception in handleResizeComplete: %@", exception.reason);
    }
}

@end
