//
//  URSWorkareaManager.m
//  uroswm - ICCCM/EWMH Strut and Workarea Management
//
//  Tracks _NET_WM_STRUT and _NET_WM_STRUT_PARTIAL properties from dock windows,
//  calculates the usable workarea, and updates _NET_WORKAREA on the root window.
//

#import "URSWorkareaManager.h"
#import "XCBScreen.h"
#import "XCBWindow.h"
#import "XCBFrame.h"
#import "EWMHService.h"
#import "XCBAtomService.h"

@interface URSWorkareaManager ()
@property (strong, nonatomic) NSMutableDictionary *windowStruts;
@property (assign, nonatomic) int32_t cachedWorkareaX;
@property (assign, nonatomic) int32_t cachedWorkareaY;
@property (assign, nonatomic) uint32_t cachedWorkareaWidth;
@property (assign, nonatomic) uint32_t cachedWorkareaHeight;
@end

@implementation URSWorkareaManager

- (instancetype)initWithConnection:(XCBConnection *)aConnection
{
    self = [super init];
    if (!self) return nil;

    _connection = aConnection;
    _windowStruts = [[NSMutableDictionary alloc] init];
    _cachedWorkareaX = INT32_MIN;
    _cachedWorkareaY = INT32_MIN;
    _cachedWorkareaWidth = UINT32_MAX;
    _cachedWorkareaHeight = UINT32_MAX;

    return self;
}

#pragma mark - Strut Property Changes

- (void)handleStrutPropertyChange:(xcb_property_notify_event_t *)event
{
    if (!event) return;

    XCBAtomService *atomService =
        [XCBAtomService sharedInstanceWithConnection:self.connection];
    EWMHService *ewmhService =
        [EWMHService sharedInstanceWithConnection:self.connection];

    NSString *atomName = [atomService atomNameFromAtom:event->atom];

    if (![atomName isEqualToString:[ewmhService EWMHWMStrut]] &&
        ![atomName isEqualToString:[ewmhService EWMHWMStrutPartial]]) {
        return;
    }

    BOOL needsRecalc = NO;
    if (event->state == XCB_PROPERTY_DELETE) {
        needsRecalc = [self removeStrutForWindow:event->window];
    } else {
        needsRecalc = [self readAndRegisterStrutForWindow:event->window];
    }

    if (needsRecalc) {
        [self recalculateWorkarea];

        /* The strut changed while windows were already mapped: re-layout the
         * existing windows so they too dodge the new workarea (e.g. a menu
         * bar that was resized/repositioned after a resolution change). */
        [self pushExistingWindowsBelowWorkarea];
    }
}

#pragma mark - Re-layout of existing windows

/* Move already-mapped normal windows that overlap the new workarea top (i.e.
   their frame top edge is above the workarea, e.g. under the menu bar) down
   so they respect the strut that was just applied.  Only framed top-level
   windows are moved; special window types and fullscreen windows are left
   alone. */
- (void)pushExistingWindowsBelowWorkarea
{
    @try {
        EWMHService *ewmhService =
            [EWMHService sharedInstanceWithConnection:self.connection];
        NSRect workarea = [self currentWorkarea];
        int32_t waY = (int32_t)workarea.origin.y;
        NSDictionary *windows = [self.connection windowsMap];

        for (NSString *key in windows) {
            XCBWindow *win = [windows objectForKey:key];
            if (!win || ![win isKindOfClass:[XCBFrame class]]) {
                continue;
            }
            if ([win fullScreen]) {
                continue;
            }

            /* Normal windows have no windowType set - the WM only assigns a
             * type to special windows (Dock, Menu, Tooltip, ...) - so skip
             * only the explicitly special types; nil means a normal window. */
            NSString *type = [win windowType];
            if (type != nil) {
                if ([type isEqualToString:[ewmhService EWMHWMWindowTypeDesktop]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeDock]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeToolbar]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeMenu]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeDropdownMenu]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypePopupMenu]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeTooltip]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeNotification]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeSplash]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeCombo]] ||
                    [type isEqualToString:[ewmhService EWMHWMWindowTypeDnd]]) {
                    continue;
                }
            }

            xcb_get_geometry_cookie_t geomCookie =
                xcb_get_geometry([self.connection connection], [win window]);
            xcb_get_geometry_reply_t *geom =
                xcb_get_geometry_reply([self.connection connection], geomCookie, NULL);
            if (!geom) {
                continue;
            }

            if ((int32_t)geom->y < waY) {
                uint32_t values[] = {(uint32_t)((int32_t)geom->x < 0 ? 0 : geom->x),
                                     (uint32_t)waY};
                xcb_configure_window([self.connection connection], [win window],
                                     XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y,
                                     values);
                //NSLog(@"[ICCCM] Moved window %u below workarea top (y=%d -> %d)",
                //      [win window], geom->y, waY);
            }
            free(geom);
        }
        [self.connection flush];
    } @catch (NSException *exception) {
        NSLog(@"[ICCCM] Exception pushing existing windows below workarea: %@",
              exception.reason);
    }
}

#pragma mark - Strut Registration

- (BOOL)readAndRegisterStrutForWindow:(xcb_window_t)windowId
{
    EWMHService *ewmhService =
        [EWMHService sharedInstanceWithConnection:self.connection];
    NSNumber *key = @(windowId);
    NSDictionary *existingStrut = [self.windowStruts objectForKey:key];

    XCBWindow *window = [[XCBWindow alloc] initWithXCBWindow:windowId
                                               andConnection:self.connection];
    if (!window) {
        NSLog(@"[ICCCM] Cannot create window object for %u", windowId);
        return NO;
    }

    // Try _NET_WM_STRUT_PARTIAL first (more precise)
    uint32_t strutPartial[12] = {0};
    if ([ewmhService readStrutPartialForWindow:window strut:strutPartial]) {
        NSMutableDictionary *strutData = [NSMutableDictionary dictionary];
        [strutData setObject:@(strutPartial[0])  forKey:@"left"];
        [strutData setObject:@(strutPartial[1])  forKey:@"right"];
        [strutData setObject:@(strutPartial[2])  forKey:@"top"];
        [strutData setObject:@(strutPartial[3])  forKey:@"bottom"];
        [strutData setObject:@(strutPartial[4])  forKey:@"left_start_y"];
        [strutData setObject:@(strutPartial[5])  forKey:@"left_end_y"];
        [strutData setObject:@(strutPartial[6])  forKey:@"right_start_y"];
        [strutData setObject:@(strutPartial[7])  forKey:@"right_end_y"];
        [strutData setObject:@(strutPartial[8])  forKey:@"top_start_x"];
        [strutData setObject:@(strutPartial[9])  forKey:@"top_end_x"];
        [strutData setObject:@(strutPartial[10]) forKey:@"bottom_start_x"];
        [strutData setObject:@(strutPartial[11]) forKey:@"bottom_end_x"];
        [strutData setObject:@(YES)              forKey:@"isPartial"];

        if ([existingStrut isEqualToDictionary:strutData]) {
            return NO;
        }

        [self.windowStruts setObject:strutData forKey:key];
        //NSLog(@"[ICCCM] Registered strut partial for window %u: left=%u, right=%u, top=%u, bottom=%u",
        //      windowId, strutPartial[0], strutPartial[1], strutPartial[2], strutPartial[3]);
        return YES;
    }

    // Fallback to _NET_WM_STRUT
    uint32_t strut[4] = {0};
    if ([ewmhService readStrutForWindow:window strut:strut]) {
        NSMutableDictionary *strutData = [NSMutableDictionary dictionary];
        [strutData setObject:@(strut[0]) forKey:@"left"];
        [strutData setObject:@(strut[1]) forKey:@"right"];
        [strutData setObject:@(strut[2]) forKey:@"top"];
        [strutData setObject:@(strut[3]) forKey:@"bottom"];
        [strutData setObject:@(NO)       forKey:@"isPartial"];

        if ([existingStrut isEqualToDictionary:strutData]) {
            return NO;
        }

        [self.windowStruts setObject:strutData forKey:key];
        //NSLog(@"[ICCCM] Registered strut for window %u: left=%u, right=%u, top=%u, bottom=%u",
        //      windowId, strut[0], strut[1], strut[2], strut[3]);
        return YES;
    }

    return NO;
}

- (BOOL)removeStrutForWindow:(xcb_window_t)windowId
{
    NSNumber *key = @(windowId);
    if ([self.windowStruts objectForKey:key]) {
        [self.windowStruts removeObjectForKey:key];
        //NSLog(@"[ICCCM] Removed strut for window %u", windowId);
        return YES;
    }
    return NO;
}

#pragma mark - Workarea Calculation

- (void)recalculateWorkarea
{
    @try {
        XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
        XCBWindow *rootWindow = [screen rootWindow];

        uint32_t screenWidth  = [screen width];
        uint32_t screenHeight = [screen height];

        uint32_t maxLeft = 0, maxRight = 0, maxTop = 0, maxBottom = 0;

        for (NSNumber *windowKey in self.windowStruts) {
            NSDictionary *strutData = [self.windowStruts objectForKey:windowKey];

            uint32_t left   = [[strutData objectForKey:@"left"]   unsignedIntValue];
            uint32_t right  = [[strutData objectForKey:@"right"]  unsignedIntValue];
            uint32_t top    = [[strutData objectForKey:@"top"]    unsignedIntValue];
            uint32_t bottom = [[strutData objectForKey:@"bottom"] unsignedIntValue];

            if (left   > maxLeft)   maxLeft = left;
            if (right  > maxRight)  maxRight = right;
            if (top    > maxTop)    maxTop = top;
            if (bottom > maxBottom) maxBottom = bottom;
        }

        int32_t  workareaX      = (int32_t)maxLeft;
        int32_t  workareaY      = (int32_t)maxTop;
        uint32_t workareaWidth  = (maxLeft + maxRight  < screenWidth)
                                  ? screenWidth  - maxLeft - maxRight : 0;
        uint32_t workareaHeight = (maxTop  + maxBottom < screenHeight)
                                  ? screenHeight - maxTop  - maxBottom : 0;

        if (workareaX     == self.cachedWorkareaX &&
            workareaY     == self.cachedWorkareaY &&
            workareaWidth == self.cachedWorkareaWidth &&
            workareaHeight == self.cachedWorkareaHeight) {
            return;
        }

        self.cachedWorkareaX      = workareaX;
        self.cachedWorkareaY      = workareaY;
        self.cachedWorkareaWidth  = workareaWidth;
        self.cachedWorkareaHeight = workareaHeight;

        //NSLog(@"[ICCCM] Recalculated workarea: x=%d, y=%d, width=%u, height=%u "
        //      @"(struts: left=%u, right=%u, top=%u, bottom=%u)",
        //      workareaX, workareaY, workareaWidth, workareaHeight,
        //      maxLeft, maxRight, maxTop, maxBottom);

        EWMHService *ewmhService =
            [EWMHService sharedInstanceWithConnection:self.connection];
        [ewmhService updateWorkareaForRootWindow:rootWindow
                                               x:workareaX
                                               y:workareaY
                                           width:workareaWidth
                                          height:workareaHeight];

        [self.connection flush];

    } @catch (NSException *exception) {
        NSLog(@"[ICCCM] Exception recalculating workarea: %@", exception.reason);
    }
}

- (NSRect)currentWorkarea
{
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    uint32_t screenWidth  = [screen width];
    uint32_t screenHeight = [screen height];

    uint32_t maxLeft = 0, maxRight = 0, maxTop = 0, maxBottom = 0;

    for (NSNumber *windowKey in self.windowStruts) {
        NSDictionary *strutData = [self.windowStruts objectForKey:windowKey];

        uint32_t left   = [[strutData objectForKey:@"left"]   unsignedIntValue];
        uint32_t right  = [[strutData objectForKey:@"right"]  unsignedIntValue];
        uint32_t top    = [[strutData objectForKey:@"top"]    unsignedIntValue];
        uint32_t bottom = [[strutData objectForKey:@"bottom"] unsignedIntValue];

        if (left   > maxLeft)   maxLeft = left;
        if (right  > maxRight)  maxRight = right;
        if (top    > maxTop)    maxTop = top;
        if (bottom > maxBottom) maxBottom = bottom;
    }

    return NSMakeRect((CGFloat)maxLeft,
                      (CGFloat)maxTop,
                      (CGFloat)(screenWidth  - maxLeft - maxRight),
                      (CGFloat)(screenHeight - maxTop  - maxBottom));
}

@end
