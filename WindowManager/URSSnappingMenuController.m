//
//  URSSnappingMenuController.m
//  uroswm - Titlebar Right-Click Snapping Context Menu
//
//  Manages the right-click context menu on titlebars for snapping operations
//  (center, maximize vertically/horizontally, snap to corners/sides).
//

#import "URSSnappingMenuController.h"
#import "XCBScreen.h"

@implementation URSSnappingMenuController

- (instancetype)initWithConnection:(XCBConnection *)aConnection
{
    self = [super init];
    if (!self) return nil;

    _connection = aConnection;

    return self;
}

#pragma mark - Menu Dismissal

- (BOOL)dismissIfActive
{
    if (!self.activeMenu) {
        return NO;
    }

    NSEvent *syntheticUp =
        [NSEvent mouseEventWithType:NSLeftMouseUp
                           location:NSMakePoint(-1, -1)
                      modifierFlags:0
                          timestamp:0
                       windowNumber:0
                            context:nil
                        eventNumber:0
                         clickCount:1
                           pressure:0];
    [NSApp postEvent:syntheticUp atStart:YES];
    return YES;
}

#pragma mark - Context Menu Display

- (void)showSnappingContextMenuForFrame:(XCBFrame *)frame
                            atX11Point:(NSPoint)x11Point
{
    if (!frame) return;
    if (self.activeMenu) return;  // Prevent double-open

    // Abort if right button already released
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    xcb_window_t root = [[screen rootWindow] window];
    xcb_query_pointer_cookie_t cookie =
        xcb_query_pointer([self.connection connection], root);
    xcb_query_pointer_reply_t *reply =
        xcb_query_pointer_reply([self.connection connection], cookie, NULL);
    if (reply) {
        BOOL rightButtonHeld = (reply->mask & XCB_KEY_BUT_MASK_BUTTON_3) != 0;
        free(reply);
        if (!rightButtonHeld) {
            return;
        }
    }

    // Convert X11 coordinates to GNUstep (Y-flipped)
    uint16_t screenHeight = [screen height];
    NSPoint gnustepPoint = NSMakePoint(x11Point.x, screenHeight - x11Point.y);

    NSMenu *menu = [self buildMenuForFrame:frame];

    NSLog(@"[SnappingMenu] Showing context menu at GNUstep (%.0f, %.0f) for frame %u",
          gnustepPoint.x, gnustepPoint.y, [frame window]);

    NSEvent *event =
        [NSEvent mouseEventWithType:NSRightMouseDown
                           location:gnustepPoint
                      modifierFlags:0
                          timestamp:0
                       windowNumber:0
                            context:nil
                        eventNumber:0
                         clickCount:1
                           pressure:0];
    self.activeMenu = menu;

    // Watchdog: poll button state during menu tracking
    NSTimer *watchdog =
        [NSTimer timerWithTimeInterval:0.05
                                target:self
                              selector:@selector(buttonWatchdog:)
                              userInfo:nil
                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:watchdog
                                 forMode:NSEventTrackingRunLoopMode];

    [NSMenu popUpContextMenu:menu withEvent:event forView:nil];

    [watchdog invalidate];
    self.activeMenu = nil;
}

#pragma mark - Menu Construction

- (NSMenu *)buildMenuForFrame:(XCBFrame *)frame
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Window"];

    struct { NSString *title; SEL action; } items[] = {
        { @"Center",                   @selector(snapMenuCenter:) },
        { @"Maximize Vertically",      @selector(snapMenuMaximizeVertically:) },
        { @"Maximize Horizontally",    @selector(snapMenuMaximizeHorizontally:) },
        { nil, nil },  // separator
        { @"Snap Left",                @selector(snapMenuSnapLeft:) },
        { @"Snap Right",               @selector(snapMenuSnapRight:) },
        { nil, nil },  // separator
        { @"Snap Top Left",            @selector(snapMenuSnapTopLeft:) },
        { @"Snap Top Right",           @selector(snapMenuSnapTopRight:) },
        { @"Snap Bottom Left",         @selector(snapMenuSnapBottomLeft:) },
        { @"Snap Bottom Right",        @selector(snapMenuSnapBottomRight:) },
    };

    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        if (!items[i].title) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:items[i].title
                                      action:items[i].action
                               keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:frame];
        [menu addItem:item];
    }

    return menu;
}

#pragma mark - Button Watchdog

- (void)buttonWatchdog:(NSTimer *)timer
{
    if (!self.activeMenu) {
        [timer invalidate];
        return;
    }

    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    xcb_window_t root = [[screen rootWindow] window];
    xcb_query_pointer_cookie_t cookie =
        xcb_query_pointer([self.connection connection], root);
    xcb_query_pointer_reply_t *reply =
        xcb_query_pointer_reply([self.connection connection], cookie, NULL);
    if (reply) {
        BOOL rightButtonHeld = (reply->mask & XCB_KEY_BUT_MASK_BUTTON_3) != 0;
        free(reply);
        if (!rightButtonHeld) {
            NSEvent *syntheticUp =
                [NSEvent mouseEventWithType:NSLeftMouseUp
                                   location:NSMakePoint(-1, -1)
                              modifierFlags:0
                                  timestamp:0
                               windowNumber:0
                                    context:nil
                                eventNumber:0
                                 clickCount:1
                                   pressure:0];
            [NSApp postEvent:syntheticUp atStart:YES];
            [timer invalidate];
        }
    }
}

#pragma mark - Snapping Actions

- (void)snapMenuCenter:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection centerFrame:frame];
    }
}

- (void)snapMenuMaximizeVertically:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection maximizeFrameVertically:frame];
    }
}

- (void)snapMenuMaximizeHorizontally:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection maximizeFrameHorizontally:frame];
    }
}

- (void)snapMenuSnapLeft:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneLeft frame:frame];
    }
}

- (void)snapMenuSnapRight:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneRight frame:frame];
    }
}

- (void)snapMenuSnapTopLeft:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneTopLeft frame:frame];
    }
}

- (void)snapMenuSnapTopRight:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneTopRight frame:frame];
    }
}

- (void)snapMenuSnapBottomLeft:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneBottomLeft frame:frame];
    }
}

- (void)snapMenuSnapBottomRight:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (frame && [self.connection windowForXCBId:[frame window]]) {
        [self.connection executeSnapForZone:SnapZoneBottomRight frame:frame];
    }
}

@end
