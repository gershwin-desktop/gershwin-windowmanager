//
//  URSSnappingMenuController.m
//  uroswm - Titlebar Right-Click Snapping Context Menu
//
//  Manages the right-click context menu on titlebars for snapping operations
//  (center, maximize vertically/horizontally, snap to corners/sides).
//

#import "URSSnappingMenuController.h"
#import "XCBScreen.h"
#import "XCBWindow.h"

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
        { nil, nil },  // separator
        { @"Window Properties",        @selector(snapMenuInformation:) },
        { @"Close",                    @selector(snapMenuClose:) },
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

- (void)snapMenuInformation:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (!frame) {
        NSLog(@"[SnapMenu] Information: no frame");
        return;
    }
    XCBWindow *clientWin = [frame childWindowForKey:ClientWindow];
    if (!clientWin) {
        NSLog(@"[SnapMenu] Information: no client window");
        return;
    }

    xcb_window_t winId = [clientWin window];
    NSLog(@"[SnapMenu] Information requested for window 0x%x", (unsigned int)winId);

    [self performSelector:@selector(deferredShowPropertiesForWindow:)
               withObject:@((unsigned int)winId)
               afterDelay:0.0];
}

// Format a single property value into a human-readable string.
// Handles ATOM type (resolves to name), CARDINAL, WINDOW, STRING, UTF8_STRING.
- (NSString *)formatPropertyValue:(xcb_get_property_reply_t *)reply conn:(xcb_connection_t *)conn
{
    if (!reply || reply->length == 0) return @"(empty)";
    if (reply->type == XCB_ATOM_STRING || reply->format == 8) {
        char *bytes = (char *)xcb_get_property_value(reply);
        int len = xcb_get_property_value_length(reply);
        if (len <= 0) return @"(empty)";
        BOOL printable = YES;
        for (int i = 0; i < len && i < 4096; i++) {
            if (bytes[i] < 0x20 && bytes[i] != '\t' && bytes[i] != '\n' && bytes[i] != '\r') {
                printable = NO;
                break;
            }
        }
        if (printable) {
            NSString *s = [[NSString alloc] initWithBytes:bytes length:len
                                                 encoding:NSISOLatin1StringEncoding];
            // Replace embedded newlines with visible markers
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return s ?: @"(invalid string)";
        } else {
            // Show hex dump
            NSMutableString *hex = [NSMutableString stringWithString:@"0x"];
            int showLen = MIN(len, 256);
            for (int i = 0; i < showLen; i++) {
                [hex appendFormat:@"%02x", (unsigned char)bytes[i]];
            }
            if (len > 256) [hex appendString:@"..."];
            return hex;
        }
    }

    uint32_t *vals = (uint32_t *)xcb_get_property_value(reply);
    uint32_t len = reply->length;
    if (!vals || len == 0) return @"(empty)";

    if (reply->type == XCB_ATOM_ATOM) {
        NSMutableString *s = [NSMutableString string];
        for (uint32_t i = 0; i < len; i++) {
            if (i > 0) [s appendString: @", "];
            xcb_atom_t a = (xcb_atom_t)vals[i];
            xcb_get_atom_name_cookie_t nc = xcb_get_atom_name(conn, a);
            xcb_get_atom_name_reply_t *nr = xcb_get_atom_name_reply(conn, nc, NULL);
            if (nr) {
                int nl = xcb_get_atom_name_name_length(nr);
                char *nn = xcb_get_atom_name_name(nr);
                [s appendFormat:@"%.*s", nl, nn];
                free(nr);
            } else {
                [s appendFormat:@"%u", a];
            }
        }
        return s;
    }

    if (reply->type == XCB_ATOM_WINDOW) {
        NSMutableString *s = [NSMutableString string];
        for (uint32_t i = 0; i < len; i++) {
            if (i > 0) [s appendString:@", "];
            [s appendFormat:@"0x%x", (unsigned int)vals[i]];
        }
        return s;
    }

    if (reply->type == XCB_ATOM_CARDINAL) {
        if (len == 1) {
            return [NSString stringWithFormat:@"%u", (unsigned int)vals[0]];
        }
        NSMutableString *s = [NSMutableString string];
        for (uint32_t i = 0; i < len; i++) {
            if (i > 0) [s appendString:@", "];
            [s appendFormat:@"%u", (unsigned int)vals[i]];
        }
        return s;
    }

    // Fallback: hex dump
    {
        int byteLen = xcb_get_property_value_length(reply);
        unsigned char *bytes = (unsigned char *)xcb_get_property_value(reply);
        int showLen = MIN(byteLen, 128);
        NSMutableString *hex = [NSMutableString stringWithString:@"0x"];
        for (int i = 0; i < showLen; i++) {
            [hex appendFormat:@"%02x", bytes[i]];
        }
        if (byteLen > 128) [hex appendString:@"..."];
        return hex;
    }
}

- (NSString *)readX11PropertiesForWindow:(xcb_window_t)winId
{
    xcb_connection_t *conn = [self.connection connection];
    if (!conn || !winId) return nil;

    // Get list of property atoms set on the window
    xcb_list_properties_cookie_t lp_c = xcb_list_properties(conn, winId);
    xcb_list_properties_reply_t *lp_r = xcb_list_properties_reply(conn, lp_c, NULL);
    if (!lp_r) return @"(could not list properties)";

    int count = xcb_list_properties_atoms_length(lp_r);
    xcb_atom_t *atoms = xcb_list_properties_atoms(lp_r);

    NSMutableString *result = [NSMutableString string];

    for (int i = 0; i < count; i++) {
        xcb_atom_t propAtom = atoms[i];

        // Get atom name
        xcb_get_atom_name_cookie_t nc = xcb_get_atom_name(conn, propAtom);
        xcb_get_atom_name_reply_t *nr = xcb_get_atom_name_reply(conn, nc, NULL);
        NSString *propName;
        if (nr) {
            int nl = xcb_get_atom_name_name_length(nr);
            char *nn = xcb_get_atom_name_name(nr);
            propName = [[NSString alloc] initWithBytes:nn length:nl
                                              encoding:NSISOLatin1StringEncoding];
            free(nr);
        } else {
            propName = [NSString stringWithFormat:@"<atom %u>", propAtom];
        }

        // Read property value (try up to 4096 32-bit entries)
        xcb_get_property_cookie_t pc = xcb_get_property(conn, 0, winId,
                                                        propAtom, XCB_ATOM_ANY, 0, 4096);
        xcb_get_property_reply_t *pr = xcb_get_property_reply(conn, pc, NULL);
        if (!pr) {
            [result appendFormat:@"%@ = (read error)\n", propName];
            continue;
        }

        // Try to resolve type atom to a name
        NSString *typeName = nil;
        if (pr->type != XCB_ATOM_NONE) {
            xcb_get_atom_name_cookie_t tnc = xcb_get_atom_name(conn, pr->type);
            xcb_get_atom_name_reply_t *tnr = xcb_get_atom_name_reply(conn, tnc, NULL);
            if (tnr) {
                int tnl = xcb_get_atom_name_name_length(tnr);
                char *tnn = xcb_get_atom_name_name(tnr);
                typeName = [[NSString alloc] initWithBytes:tnn length:tnl
                                                  encoding:NSISOLatin1StringEncoding];
                free(tnr);
            }
        }

        NSString *valueStr = [self formatPropertyValue:pr conn:conn];

        if (typeName) {
            [result appendFormat:@"%@ (%@) = %@\n", propName, typeName, valueStr];
        } else {
            [result appendFormat:@"%@ = %@\n", propName, valueStr];
        }

        free(pr);
    }

    free(lp_r);

    // Add geometry info
    {
        xcb_get_geometry_cookie_t gc = xcb_get_geometry(conn, winId);
        xcb_get_geometry_reply_t *gr = xcb_get_geometry_reply(conn, gc, NULL);
        if (gr) {
            [result appendFormat:@"\nGeometry: %dx%d+%d+%d (border: %d, depth: %d)\n",
             gr->width, gr->height, gr->x, gr->y,
             gr->border_width, gr->depth];
            free(gr);
        }
    }

    // Add window attributes
    {
        xcb_get_window_attributes_cookie_t ac = xcb_get_window_attributes(conn, winId);
        xcb_get_window_attributes_reply_t *ar = xcb_get_window_attributes_reply(conn, ac, NULL);
        if (ar) {
            [result appendFormat:@"Map state: %d  Class: %d  Visual: 0x%x\n",
             ar->map_state, ar->_class, ar->visual];
            free(ar);
        }
    }

    return result;
}

- (NSString *)writePropertiesToTempFile:(NSString *)text
{
    NSString *dir = NSTemporaryDirectory();
    if (!dir) dir = @"/tmp";
    NSString *path = [dir stringByAppendingPathComponent:@"wm-properties.txt"];

    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        NSLog(@"[SnapMenu] Failed to write properties file: %@", error);
        return nil;
    }
    return path;
}

- (void)showPropertiesWindow:(NSString *)text
{
    NSString *path = [self writePropertiesToTempFile:text];
    if (!path) {
        NSRunAlertPanel(@"Error", @"Could not write properties to file.", @"OK", nil, nil);
        return;
    }

    [[NSWorkspace sharedWorkspace] openFile:path];
}

- (void)deferredShowPropertiesForWindow:(NSNumber *)winIdNum
{
    xcb_window_t winId = (xcb_window_t)[winIdNum unsignedIntValue];
    NSLog(@"[SnapMenu] deferredShowPropertiesForWindow: 0x%x", (unsigned int)winId);

    @try {
        NSString *info = [self readX11PropertiesForWindow:winId];
        if (!info) info = @"(no properties)";
        [self showPropertiesWindow:info];
        NSLog(@"[SnapMenu] Properties window shown for 0x%x", (unsigned int)winId);
    } @catch (NSException *e) {
        NSLog(@"[SnapMenu] EXCEPTION in deferredShowPropertiesForWindow: %@", e.reason);
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Error reading window properties"];
        [alert setInformativeText:e.reason];
        [alert runModal];
    }
}

- (void)snapMenuClose:(NSMenuItem *)sender
{
    XCBFrame *frame = [sender representedObject];
    if (!frame) return;
    XCBWindow *clientWin = [frame childWindowForKey:ClientWindow];
    if (clientWin) {
        [clientWin close];
    }
}

@end
