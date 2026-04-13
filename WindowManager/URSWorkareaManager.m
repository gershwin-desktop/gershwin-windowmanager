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
        NSLog(@"[ICCCM] Registered strut partial for window %u: left=%u, right=%u, top=%u, bottom=%u",
              windowId, strutPartial[0], strutPartial[1], strutPartial[2], strutPartial[3]);
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
        NSLog(@"[ICCCM] Registered strut for window %u: left=%u, right=%u, top=%u, bottom=%u",
              windowId, strut[0], strut[1], strut[2], strut[3]);
        return YES;
    }

    return NO;
}

- (BOOL)removeStrutForWindow:(xcb_window_t)windowId
{
    NSNumber *key = @(windowId);
    if ([self.windowStruts objectForKey:key]) {
        [self.windowStruts removeObjectForKey:key];
        NSLog(@"[ICCCM] Removed strut for window %u", windowId);
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

        uint32_t screenWidth  = [screen screen]->width_in_pixels;
        uint32_t screenHeight = [screen screen]->height_in_pixels;

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

        NSLog(@"[ICCCM] Recalculated workarea: x=%d, y=%d, width=%u, height=%u "
              @"(struts: left=%u, right=%u, top=%u, bottom=%u)",
              workareaX, workareaY, workareaWidth, workareaHeight,
              maxLeft, maxRight, maxTop, maxBottom);

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
    uint32_t screenWidth  = [screen screen]->width_in_pixels;
    uint32_t screenHeight = [screen screen]->height_in_pixels;

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
