//
//  GSThemeTitleBar.m
//  uroswm - GSTheme-based TitleBar Replacement
//
//  Implementation of GSTheme-based titlebar that completely replaces
//  XCBTitleBar's Cairo rendering with authentic AppKit decorations.
//

#import "GSThemeTitleBar.h"
#import <cairo/cairo.h>
#import <cairo/cairo-xcb.h>
#import <XCBKit/services/ICCCMService.h>
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

    // Create Cairo surface from titlebar pixmap
    cairo_surface_t *x11Surface = cairo_xcb_surface_create(
        [[self connection] connection],
        [self pixmap],
        [[self visual] visualType],
        (int)image.size.width,
        (int)image.size.height
    );

    if (cairo_surface_status(x11Surface) != CAIRO_STATUS_SUCCESS) {
        NSLog(@"GSThemeTitleBar: Failed to create Cairo X11 surface");
        cairo_surface_destroy(x11Surface);
        return;
    }

    cairo_t *ctx = cairo_create(x11Surface);

    // Create Cairo image surface from bitmap data
    cairo_surface_t *imageSurface = cairo_image_surface_create_for_data(
        [bitmap bitmapData],
        CAIRO_FORMAT_ARGB32,
        [bitmap pixelsWide],
        [bitmap pixelsHigh],
        [bitmap bytesPerRow]
    );

    if (cairo_surface_status(imageSurface) != CAIRO_STATUS_SUCCESS) {
        NSLog(@"GSThemeTitleBar: Failed to create Cairo image surface");
        cairo_surface_destroy(imageSurface);
        cairo_destroy(ctx);
        cairo_surface_destroy(x11Surface);
        return;
    }

    // Clear and paint GSTheme image to X11 surface
    cairo_set_operator(ctx, CAIRO_OPERATOR_CLEAR);
    cairo_paint(ctx);
    cairo_set_operator(ctx, CAIRO_OPERATOR_OVER);
    cairo_set_source_surface(ctx, imageSurface, 0, 0);
    cairo_paint(ctx);
    cairo_surface_flush(x11Surface);

    // Cleanup
    cairo_surface_destroy(imageSurface);
    cairo_destroy(ctx);
    cairo_surface_destroy(x11Surface);

    // Flush connection
    [[self connection] flush];
    xcb_flush([[self connection] connection]);

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

// Edge button metrics (matching Eau theme)
static const CGFloat TB_HEIGHT = 24.0;
static const CGFloat TB_EDGE_BUTTON_WIDTH = 28.0;
static const CGFloat TB_RIGHT_BUTTON_WIDTH = 28.0;

- (GSThemeTitleBarButton)buttonAtPoint:(NSPoint)point {
    XCBRect titlebarRect = [self windowRect];
    CGFloat titlebarWidth = titlebarRect.size.width;
    NSUInteger styleMask = [self windowStyleMask];

    // Close button at left edge (full height)
    NSRect closeRect = NSMakeRect(0, 0, TB_EDGE_BUTTON_WIDTH, TB_HEIGHT);

    // Side-by-side buttons on right
    // Minimize button (inner right, full height)
    NSRect miniaturizeRect = NSMakeRect(titlebarWidth - 2 * TB_RIGHT_BUTTON_WIDTH, 0,
                                         TB_RIGHT_BUTTON_WIDTH, TB_HEIGHT);

    // Zoom button (far right, full height)
    NSRect zoomRect = NSMakeRect(titlebarWidth - TB_RIGHT_BUTTON_WIDTH, 0,
                                  TB_RIGHT_BUTTON_WIDTH, TB_HEIGHT);

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