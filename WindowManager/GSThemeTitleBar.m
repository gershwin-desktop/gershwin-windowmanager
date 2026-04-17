//
//  GSThemeTitleBar.m
//  uroswm - GSTheme-based TitleBar Replacement
//
//  Implementation of GSTheme-based titlebar that completely replaces
//  XCBTitleBar's legacy rendering with authentic AppKit decorations.
//

#import "GSThemeTitleBar.h"
#import "ICCCMService.h"
#import "XCBScreen.h"
#import "URSThemeIntegration.h"

@implementation GSThemeTitleBar

#pragma mark - XCBTitleBar Method Overrides

- (void)drawTitleBarForColor:(TitleBarColor)aColor {
    NSLog(@"GSThemeTitleBar: drawTitleBarForColor called - using GSTheme");

    BOOL isActive = (aColor == TitleBarUpColor);
    [self renderWithGSTheme:isActive];
}

- (void)drawArcsForColor:(TitleBarColor)aColor {
    NSLog(@"GSThemeTitleBar: drawArcsForColor called - using GSTheme");

    BOOL isActive = (aColor == TitleBarUpColor);
    [self renderWithGSTheme:isActive];
}

- (void)drawTitleBarComponents {
    NSLog(@"GSThemeTitleBar: drawTitleBarComponents called - using GSTheme");

    [self renderWithGSTheme:YES]; // Default to active
}

- (void)drawTitleBarComponentsPixmaps {
    NSLog(@"GSThemeTitleBar: drawTitleBarComponentsPixmaps called - using GSTheme");

    [self renderWithGSTheme:YES]; // Default to active
}

#pragma mark - GSTheme Rendering Implementation

- (void)renderWithGSTheme:(BOOL)isActive {
    @try {
        GSTheme *theme = [self currentTheme];
        if (!theme) {
            NSLog(@"GSThemeTitleBar: No theme available, skipping rendering");
            return;
        }

        // Get titlebar dimensions
        XCBRect titlebarRect = [self windowRect];
        NSSize titlebarSize = NSMakeSize(titlebarRect.size.width, titlebarRect.size.height);

        NSLog(@"GSThemeTitleBar: Rendering %dx%d titlebar with GSTheme",
              (int)titlebarSize.width, (int)titlebarSize.height);

        // Create GSTheme image
        NSImage *titlebarImage = [self createGSThemeImage:titlebarSize
                                                    title:[self windowTitle]
                                                   active:isActive];

        if (titlebarImage) {
            // Transfer GSTheme image to X11 pixmap
            [self transferGSThemeImageToPixmap:titlebarImage];
            NSLog(@"GSThemeTitleBar: Successfully rendered with GSTheme");
        } else {
            NSLog(@"GSThemeTitleBar: Failed to create GSTheme image");
        }

    } @catch (NSException *exception) {
        NSLog(@"GSThemeTitleBar: Exception during rendering: %@", exception.reason);
    }
}

- (NSImage*)createGSThemeImage:(NSSize)size title:(NSString*)title active:(BOOL)isActive {
    GSTheme *theme = [self currentTheme];
    if (!theme) {
        return nil;
    }

    // Create NSImage for GSTheme rendering
    NSImage *image = [[NSImage alloc] initWithSize:size];

    [image lockFocus];

    // Clear background
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));

    // Use GSTheme to draw window titlebar
    NSRect drawRect = NSMakeRect(0, 0, size.width, size.height);
    NSUInteger styleMask = [self windowStyleMask];
    GSThemeControlState state = [self themeStateForActive:isActive];

    [theme drawWindowBorder:drawRect
                  withFrame:drawRect
               forStyleMask:styleMask
                      state:state
                   andTitle:title ?: @""];

    // Edge buttons are drawn by the theme itself through standardWindowButton calls
    // The actual button drawing is handled in the theme's button cells

    [image unlockFocus];

    NSLog(@"GSThemeTitleBar: Created GSTheme image for title: %@", title ?: @"(untitled)");
    return image;
}

- (void)transferGSThemeImageToPixmap:(NSImage*)image {
    // Convert NSImage to bitmap representation
    NSBitmapImageRep *bitmap = nil;
    for (NSImageRep *rep in [image representations]) {
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            bitmap = (NSBitmapImageRep*)rep;
            break;
        }
    }

    if (!bitmap) {
        NSData *imageData = [image TIFFRepresentation];
        bitmap = [NSBitmapImageRep imageRepWithData:imageData];
    }

    if (!bitmap) {
        NSLog(@"GSThemeTitleBar: Failed to create bitmap from GSTheme image");
        return;
    }

    // Convert NSBitmapImageRep pixels to premultiplied BGRA for xcb_put_image.
    int width = (int)[bitmap pixelsWide];
    int height = (int)[bitmap pixelsHigh];
    int bytesPerRow = (int)[bitmap bytesPerRow];
    unsigned char *bitmapData = [bitmap bitmapData];

    if (!bitmapData) {
        NSLog(@"GSThemeTitleBar: Failed to get bitmap data");
        return;
    }

    NSBitmapFormat bitmapFormat = [bitmap bitmapFormat];
    BOOL alphaFirst = (bitmapFormat & NSAlphaFirstBitmapFormat) != 0;

    for (int y = 0; y < height; y++) {
        uint32_t *rowPtr = (uint32_t *)(bitmapData + y * bytesPerRow);
        for (int x = 0; x < width; x++) {
            uint32_t pixel = rowPtr[x];
            uint32_t r, g, b, a;
            if (alphaFirst) {
                a = (pixel >> 0) & 0xFF;
                r = (pixel >> 8) & 0xFF;
                g = (pixel >> 16) & 0xFF;
                b = (pixel >> 24) & 0xFF;
            } else {
                r = (pixel >> 0) & 0xFF;
                g = (pixel >> 8) & 0xFF;
                b = (pixel >> 16) & 0xFF;
                a = (pixel >> 24) & 0xFF;
            }
            if (a < 255) {
                r = (r * a) / 255;
                g = (g * a) / 255;
                b = (b * a) / 255;
            }
            rowPtr[x] = b | (g << 8) | (r << 16) | (a << 24);
        }
    }

    // Upload pixels directly to the XCB pixmap.
    // xcb_put_image expects tightly-packed rows (no extra stride/padding).
    // NSBitmapImageRep may pad each row beyond width*4, so we repack first.
    xcb_connection_t *conn = [[self connection] connection];
    uint8_t depth = 24;
    XCBScreen *screen = [self onScreen];
    if (!screen) screen = [self screen];
    if (screen) depth = [screen screen]->root_depth;

    int packedBytesPerRow = width * 4;
    uint8_t *packed = (uint8_t *)malloc((size_t)height * (size_t)packedBytesPerRow);
    if (!packed) {
        NSLog(@"GSThemeTitleBar: Failed to allocate packed pixel buffer");
        return;
    }
    for (int row = 0; row < height; row++) {
        memcpy(packed + row * packedBytesPerRow,
               bitmapData + row * bytesPerRow,
               (size_t)packedBytesPerRow);
    }

    xcb_gcontext_t gc = xcb_generate_id(conn);
    xcb_create_gc(conn, gc, [self pixmap], 0, NULL);
    xcb_put_image(conn, XCB_IMAGE_FORMAT_Z_PIXMAP,
                  [self pixmap], gc,
                  (uint16_t)width, (uint16_t)height,
                  0, 0, 0, depth,
                  (uint32_t)((size_t)height * (size_t)packedBytesPerRow),
                  packed);
    free(packed);
    xcb_free_gc(conn, gc);

    // Flush connection
    [[self connection] flush];
    xcb_flush(conn);

    NSLog(@"GSThemeTitleBar: Successfully transferred GSTheme image to X11 pixmap");
}

#pragma mark - Helper Methods

- (GSTheme*)currentTheme {
    return [GSTheme theme];
}

- (NSUInteger)windowStyleMask {
    // Determine style mask dynamically based on client window capabilities.
    XCBWindow *parentFrame = [self parentWindow];
    XCBWindow *clientWindow = nil;
    if (parentFrame && [parentFrame isKindOfClass:[XCBFrame class]]) {
        clientWindow = [(XCBFrame *)parentFrame childWindowForKey:ClientWindow];
    }

    NSUInteger styleMask = NSTitledWindowMask;

    if (clientWindow) {
        // If close is not supported or the client does not implement WM_DELETE_WINDOW,
        // do not render any control buttons (alerts/sheets and similar transient dialogs).
        ICCCMService *icccm = [ICCCMService sharedInstanceWithConnection:[self connection]];
        BOOL supportsDelete = [icccm hasProtocol:[icccm WMDeleteWindow] forWindow:clientWindow];

        if (![clientWindow canClose] || !supportsDelete) {
            NSLog(@"GSThemeTitleBar: Client %u reports canClose=NO or lacks WM_DELETE_WINDOW - omitting control buttons", [clientWindow window]);
            return styleMask; // Only title
        }

        // Close button supported
        styleMask |= NSClosableWindowMask;

        // Show minimize if client allows it
        if ([clientWindow respondsToSelector:@selector(canMinimize)] && [clientWindow canMinimize]) {
            styleMask |= NSMiniaturizableWindowMask;
        }

        // Show resize if client is not fixed-size
        xcb_window_t clientId = [clientWindow window];
        if (clientId == 0 || ![URSThemeIntegration isFixedSizeWindow:clientId]) {
            styleMask |= NSResizableWindowMask;
        }
    } else {
        // Fallback to default mask when client unknown
        styleMask |= NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
    }

    return styleMask;
}

- (GSThemeControlState)themeStateForActive:(BOOL)isActive {
    return isActive ? GSThemeNormalState : GSThemeSelectedState;
}

#pragma mark - Button Hit Detection

// Edge buttons are square: width == titlebarRect.size.height (queried at hit-test time)

// Orb button metrics
static const CGFloat TB_ORB_SIZE = 15.0;
static const CGFloat TB_ORB_PAD_LEFT = 10.5;
static const CGFloat TB_ORB_SPACING = 4.0;

- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point {
    XCBRect titlebarRect = [self windowRect];
    CGFloat titlebarWidth = titlebarRect.size.width;
    CGFloat titlebarHeight = titlebarRect.size.height;
    NSUInteger styleMask = [self windowStyleMask];

    if ([URSThemeIntegration isOrbButtonStyle]) {
        // Orb layout: all buttons on left, 15x15, vertically centered
        CGFloat buttonY = (titlebarHeight - TB_ORB_SIZE) / 2.0;
        CGFloat closeX = TB_ORB_PAD_LEFT;
        CGFloat miniX = closeX + TB_ORB_SIZE + TB_ORB_SPACING;
        CGFloat zoomX = miniX + TB_ORB_SIZE + TB_ORB_SPACING;

        NSRect closeRect = NSMakeRect(closeX, buttonY, TB_ORB_SIZE, TB_ORB_SIZE);
        NSRect miniRect = NSMakeRect(miniX, buttonY, TB_ORB_SIZE, TB_ORB_SIZE);
        NSRect zoomRect = NSMakeRect(zoomX, buttonY, TB_ORB_SIZE, TB_ORB_SIZE);

        if ((styleMask & NSClosableWindowMask) && NSPointInRect(point, closeRect)) {
            return GSThemeTitleBarButtonClose;
        }
        if ((styleMask & NSMiniaturizableWindowMask) && NSPointInRect(point, miniRect)) {
            return GSThemeTitleBarButtonMiniaturize;
        }
        if ((styleMask & NSResizableWindowMask) && NSPointInRect(point, zoomRect)) {
            return GSThemeTitleBarButtonZoom;
        }
        return GSThemeTitleBarButtonNone;
    }

    // Edge layout - buttons are square
    NSRect closeRect = NSMakeRect(0, 0, titlebarHeight, titlebarHeight);
    NSRect miniaturizeRect = NSMakeRect(titlebarWidth - 2 * titlebarHeight, 0,
                                         titlebarHeight, titlebarHeight);
    NSRect zoomRect = NSMakeRect(titlebarWidth - titlebarHeight, 0,
                                  titlebarHeight, titlebarHeight);

    if ((styleMask & NSClosableWindowMask) && NSPointInRect(point, closeRect)) {
        return GSThemeTitleBarButtonClose;
    }
    if ((styleMask & NSResizableWindowMask) && NSPointInRect(point, zoomRect)) {
        return GSThemeTitleBarButtonZoom;
    }
    if ((styleMask & NSMiniaturizableWindowMask) && NSPointInRect(point, miniaturizeRect)) {
        return GSThemeTitleBarButtonMiniaturize;
    }

    return GSThemeTitleBarButtonNone;
}

@end