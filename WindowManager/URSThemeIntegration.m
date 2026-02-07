//
//  URSThemeIntegration.m
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Implementation of GSTheme window decoration rendering for X11 titlebars.
//

#import "URSThemeIntegration.h"
#import "URSRenderingContext.h"
#import <XCBKit/XCBConnection.h>
#import <XCBKit/XCBFrame.h>
#import <cairo/cairo.h>
#import <cairo/cairo-xcb.h>
#import <objc/runtime.h>
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

@implementation URSThemeIntegration

static URSThemeIntegration *sharedInstance = nil;
static NSMutableSet *fixedSizeWindows = nil;

#pragma mark - Fixed-size window tracking

+ (void)initialize {
    if (self == [URSThemeIntegration class]) {
        fixedSizeWindows = [[NSMutableSet alloc] init];
    }
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

// Method to draw authentic Eau button balls using the exact gradient logic from EauWindowButtonCell
+ (void)drawEauButtonBall:(NSRect)frame withColor:(NSColor*)baseColor {
    // Replicate EauWindowButtonCell drawBallWithRect logic exactly
    frame = NSInsetRect(frame, 0.5, 0.5);
    NSColor *bc = baseColor;
    float luminosity = 0.5;

    NSColor *gradientDownColor1 = [bc highlightWithLevel: luminosity];
    NSColor *gradientDownColor2 = [bc colorWithAlphaComponent: 0];
    NSColor *shadowColor1 = [bc shadowWithLevel: 0.4];
    NSColor *shadowColor2 = [bc shadowWithLevel: 0.6];
    NSColor *gradientStrokeColor2 = [shadowColor1 highlightWithLevel: luminosity];
    NSColor *gradientUpColor1 = [bc highlightWithLevel: luminosity+0.2];
    NSColor *gradientUpColor2 = [gradientUpColor1 colorWithAlphaComponent: 0.5];
    NSColor *gradientUpColor3 = [gradientUpColor1 colorWithAlphaComponent: 0];
    NSColor *light1 = [NSColor whiteColor];
    NSColor *light2 = [light1 colorWithAlphaComponent:0];

    // Gradient Declarations
    NSGradient *gradientUp = [[NSGradient alloc] initWithColorsAndLocations:
        gradientUpColor1, 0.1,
        gradientUpColor2, 0.3,
        gradientUpColor3, 1.0, nil];
    NSGradient *gradientDown = [[NSGradient alloc] initWithColorsAndLocations:
        gradientDownColor1, 0.0,
        gradientDownColor2, 1.0, nil];
    NSGradient *baseGradient = [[NSGradient alloc] initWithColorsAndLocations:
        bc, 0.0,
        shadowColor1, 0.80, nil];
    NSGradient *gradientStroke = [[NSGradient alloc] initWithColorsAndLocations:
        light1, 0.2,
        light2, 1.0, nil];
    NSGradient *gradientStroke2 = [[NSGradient alloc] initWithColorsAndLocations:
        shadowColor2, 0.47,
        gradientStrokeColor2, 1.0, nil];

    // Drawing code from EauWindowButtonCell
    NSRect baseCircleGradientStrokeRect = frame;
    NSRect baseCircleGradientStrokeRect2 = NSInsetRect(baseCircleGradientStrokeRect, 0.5, 0.5);
    frame = NSInsetRect(frame, 1, 1);

    NSRect baseCircleRect = NSMakeRect(NSMinX(frame) + floor(NSWidth(frame) * 0.06667 + 0.5), NSMinY(frame) + floor(NSHeight(frame) * 0.06667 + 0.5), floor(NSWidth(frame) * 0.93333 + 0.5) - floor(NSWidth(frame) * 0.06667 + 0.5), floor(NSHeight(frame) * 0.93333 + 0.5) - floor(NSHeight(frame) * 0.06667 + 0.5));
    NSRect basecircle2Rect = NSMakeRect(NSMinX(frame) + floor(NSWidth(frame) * 0.06667 + 0.5), NSMinY(frame) + floor(NSHeight(frame) * 0.06667 + 0.5), floor(NSWidth(frame) * 0.93333 + 0.5) - floor(NSWidth(frame) * 0.06667 + 0.5), floor(NSHeight(frame) * 0.93333 + 0.5) - floor(NSHeight(frame) * 0.06667 + 0.5));

    // BaseCircleGradientStroke Drawing
    NSBezierPath *baseCircleGradientStrokePath = [NSBezierPath bezierPathWithOvalInRect: baseCircleGradientStrokeRect];
    [gradientStroke drawInBezierPath: baseCircleGradientStrokePath angle: 90];
    NSBezierPath *baseCircleGradientStrokePath2 = [NSBezierPath bezierPathWithOvalInRect: baseCircleGradientStrokeRect2];
    [gradientStroke2 drawInBezierPath: baseCircleGradientStrokePath2 angle: -90];

    // BaseCircle Drawing
    NSBezierPath *baseCirclePath = [NSBezierPath bezierPathWithOvalInRect: baseCircleRect];
    CGFloat baseCircleResizeRatio = MIN(NSWidth(baseCircleRect) / 13, NSHeight(baseCircleRect) / 13);
    [NSGraphicsContext saveGraphicsState];
    [baseCirclePath addClip];
    [baseGradient drawFromCenter: NSMakePoint(NSMidX(baseCircleRect) + 0 * baseCircleResizeRatio, NSMidY(baseCircleRect) + 0 * baseCircleResizeRatio) radius: 2.85 * baseCircleResizeRatio
        toCenter: NSMakePoint(NSMidX(baseCircleRect) + 0 * baseCircleResizeRatio, NSMidY(baseCircleRect) + 0 * baseCircleResizeRatio) radius: 7.32 * baseCircleResizeRatio
        options: NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
    [NSGraphicsContext restoreGraphicsState];

    // basecircle2 Drawing
    NSBezierPath *basecircle2Path = [NSBezierPath bezierPathWithOvalInRect: basecircle2Rect];
    CGFloat basecircle2ResizeRatio = MIN(NSWidth(basecircle2Rect) / 13, NSHeight(basecircle2Rect) / 13);
    [NSGraphicsContext saveGraphicsState];
    [basecircle2Path addClip];
    [gradientDown drawFromCenter: NSMakePoint(NSMidX(basecircle2Rect) + -0.98 * basecircle2ResizeRatio, NSMidY(basecircle2Rect) + -6.5 * basecircle2ResizeRatio) radius: 1.54 * basecircle2ResizeRatio
        toCenter: NSMakePoint(NSMidX(basecircle2Rect) + -1.86 * basecircle2ResizeRatio, NSMidY(basecircle2Rect) + -8.73 * basecircle2ResizeRatio) radius: 8.65 * basecircle2ResizeRatio
        options: NSGradientDrawsBeforeStartingLocation | NSGradientDrawsAfterEndingLocation];
    [NSGraphicsContext restoreGraphicsState];

    // halfcircle Drawing
    NSBezierPath *halfcirclePath = [NSBezierPath bezierPath];
    [halfcirclePath moveToPoint: NSMakePoint(NSMinX(frame) + 0.93316 * NSWidth(frame), NSMinY(frame) + 0.46157 * NSHeight(frame))];
    [halfcirclePath curveToPoint: NSMakePoint(NSMinX(frame) + 0.78652 * NSWidth(frame), NSMinY(frame) + 0.81548 * NSHeight(frame)) controlPoint1: NSMakePoint(NSMinX(frame) + 0.93316 * NSWidth(frame), NSMinY(frame) + 0.46157 * NSHeight(frame)) controlPoint2: NSMakePoint(NSMinX(frame) + 0.94476 * NSWidth(frame), NSMinY(frame) + 0.66376 * NSHeight(frame))];
    [halfcirclePath curveToPoint: NSMakePoint(NSMinX(frame) + 0.21348 * NSWidth(frame), NSMinY(frame) + 0.81548 * NSHeight(frame)) controlPoint1: NSMakePoint(NSMinX(frame) + 0.62828 * NSWidth(frame), NSMinY(frame) + 0.96721 * NSHeight(frame)) controlPoint2: NSMakePoint(NSMinX(frame) + 0.37172 * NSWidth(frame), NSMinY(frame) + 0.96721 * NSHeight(frame))];
    [halfcirclePath curveToPoint: NSMakePoint(NSMinX(frame) + 0.06684 * NSWidth(frame), NSMinY(frame) + 0.46157 * NSHeight(frame)) controlPoint1: NSMakePoint(NSMinX(frame) + 0.05524 * NSWidth(frame), NSMinY(frame) + 0.66376 * NSHeight(frame)) controlPoint2: NSMakePoint(NSMinX(frame) + 0.06684 * NSWidth(frame), NSMinY(frame) + 0.46157 * NSHeight(frame))];
    [halfcirclePath lineToPoint: NSMakePoint(NSMinX(frame) + 0.93316 * NSWidth(frame), NSMinY(frame) + 0.46157 * NSHeight(frame))];
    [halfcirclePath closePath];
    [halfcirclePath setLineCapStyle: NSRoundLineCapStyle];
    [halfcirclePath setLineJoinStyle: NSRoundLineJoinStyle];
    [gradientUp drawInBezierPath: halfcirclePath angle: -90];
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

        // Clear background with titlebar background color (not transparent!)
        // Using transparent would leave garbage pixels from uninitialized pixmap
        [[NSColor lightGrayColor] set];
        NSRectFill(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height));

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

        // Add properly positioned buttons using Eau theme specifications
        // Based on Eau theme analysis: 17px spacing, LEFT-aligned (miniaturize first, then close)
        float buttonSize = 13.0;
        float buttonSpacing = 17.0;  // Eau theme uses 17px spacing per button
        float topMargin = 6.0;        // Center vertically in 24px titlebar
        float leftMargin = 2.0;       // Small margin from left edge

        if (styleMask & NSMiniaturizableWindowMask) {
            NSButton *miniButton = [theme standardWindowButton:NSWindowMiniaturizeButton forStyleMask:styleMask];
            if (miniButton) {
                // Eau positions miniaturize button at LEFT edge (causes title to move right by 17px)
                NSRect miniFrame = NSMakeRect(
                    leftMargin,  // At left edge
                    topMargin,
                    buttonSize,
                    buttonSize
                );

                NSImage *buttonImage = [miniButton image];
                if (buttonImage) {
                    [buttonImage drawInRect:miniFrame
                                   fromRect:NSZeroRect
                                  operation:NSCompositeSourceOver
                                   fraction:1.0];
                    NSLog(@"Drew miniaturize button at Eau LEFT position: %@", NSStringFromRect(miniFrame));
                }
            }
        }

        if (styleMask & NSClosableWindowMask) {
            NSButton *closeButton = [theme standardWindowButton:NSWindowCloseButton forStyleMask:styleMask];
            if (closeButton) {
                // Position close button next to miniaturize button (causes title width to reduce by 17px)
                NSRect closeFrame = NSMakeRect(
                    leftMargin + buttonSpacing,  // 17px from left edge (after miniaturize)
                    topMargin,
                    buttonSize,
                    buttonSize
                );

                NSImage *buttonImage = [closeButton image];
                if (buttonImage) {
                    [buttonImage drawInRect:closeFrame
                                   fromRect:NSZeroRect
                                  operation:NSCompositeSourceOver
                                   fraction:1.0];
                    NSLog(@"Drew close button at Eau LEFT position: %@", NSStringFromRect(closeFrame));
                }
            }
        }

        if (styleMask & NSResizableWindowMask) {
            NSButton *zoomButton = [theme standardWindowButton:NSWindowZoomButton forStyleMask:styleMask];
            if (zoomButton) {
                // Position zoom button after close button
                NSRect zoomFrame = NSMakeRect(
                    leftMargin + (2 * buttonSpacing),  // 34px from left edge
                    topMargin,
                    buttonSize,
                    buttonSize
                );

                NSImage *buttonImage = [zoomButton image];
                if (buttonImage) {
                    [buttonImage drawInRect:zoomFrame
                                   fromRect:NSZeroRect
                                  operation:NSCompositeSourceOver
                                   fraction:1.0];
                    NSLog(@"Drew zoom button at Eau LEFT position: %@", NSStringFromRect(zoomFrame));
                }
            }
        }

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

    NSLog(@"Creating Cairo surface for titlebar pixmap: %u, size: %dx%d",
          titlebar.pixmap, (int)image.size.width, (int)image.size.height);

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
    cairo_surface_t *x11Surface = cairo_xcb_surface_create(
        [titlebar.connection connection],
        titlebar.pixmap,
        titlebar.visual.visualType,
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
    // NOTE: NSBitmapImageRep uses RGBA but Cairo ARGB32 expects BGRA, so we need to convert
    unsigned char *bitmapPixels = [bitmap bitmapData];
    int width = [bitmap pixelsWide];
    int height = [bitmap pixelsHigh];
    int bytesPerRow = [bitmap bytesPerRow];

    // OPTIMIZATION: Convert RGBA to BGRA using 32-bit word operations (4x faster)
    // Process entire rows at once, handling stride properly
    int rowPixels = width;
    for (int y = 0; y < height; y++) {
        uint32_t *rowPtr = (uint32_t *)(bitmapPixels + (y * bytesPerRow));
        for (int x = 0; x < rowPixels; x++) {
            uint32_t pixel = rowPtr[x];
            // RGBA (little-endian memory: A B G R) -> BGRA (little-endian: A R G B)
            // Extract channels and reassemble
            uint32_t r = (pixel >> 0) & 0xFF;
            uint32_t g = (pixel >> 8) & 0xFF;
            uint32_t b = (pixel >> 16) & 0xFF;
            uint32_t a = (pixel >> 24) & 0xFF;
            // BGRA format: B in lowest byte, then G, R, A
            rowPtr[x] = (a << 24) | (r << 16) | (g << 8) | b;
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
    // SOURCE completely replaces destination pixels (no compositing)
    // This prevents old pixmap garbage from showing through
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

                // OPTIMIZATION: Convert RGBA to BGRA using 32-bit word operations
                for (int y = 0; y < dimmedHeight; y++) {
                    uint32_t *rowPtr = (uint32_t *)(dimmedPixels + (y * dimmedBytesPerRow));
                    for (int x = 0; x < dimmedWidth; x++) {
                        uint32_t pixel = rowPtr[x];
                        uint32_t r = (pixel >> 0) & 0xFF;
                        uint32_t g = (pixel >> 8) & 0xFF;
                        uint32_t b = (pixel >> 16) & 0xFF;
                        uint32_t a = (pixel >> 24) & 0xFF;
                        rowPtr[x] = (a << 24) | (r << 16) | (g << 8) | b;
                    }
                }

                cairo_surface_t *dSurface = cairo_xcb_surface_create(
                    [titlebar.connection connection],
                    dPixmap,
                    titlebar.visual.visualType,
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
        
        // Pre-fill the entire rect with the theme's border/control stroke color
        // This ensures no black pixels remain at edges where the theme may not draw
        // (e.g., Eau's drawTitleBarBackground insets by 1 pixel)
        NSColor *prefillColor = [NSColor colorWithCalibratedWhite:0.4 alpha:1.0]; // Grey40 #666666 - matches Eau border
        [prefillColor set];
        NSRectFill(titleBarRect);
        
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
        // Get button positions using theme's methods, then draw using theme-appropriate style
        // Eau theme positions buttons on LEFT: Close, Mini, Zoom
        // Base GSTheme positions Close on RIGHT
        
        BOOL isEauTheme = [[theme name] isEqualToString:@"Eau"];
        NSLog(@"Drawing buttons for theme: %@ (isEau=%d)", [theme name], isEauTheme);
        
        // Button size and spacing for Eau
        CGFloat buttonSize = 15.0;
        CGFloat buttonSpacing = 4.0;
        CGFloat leftPadding = 10.5;
        CGFloat topPadding = 5.5;
        
        // Eau button colors
        NSColor *closeColor = [NSColor colorWithCalibratedRed:0.97 green:0.26 blue:0.23 alpha:1.0];
        NSColor *miniColor = [NSColor colorWithCalibratedRed:0.9 green:0.7 blue:0.3 alpha:1.0];
        NSColor *zoomColor = [NSColor colorWithCalibratedRed:0.322 green:0.778 blue:0.244 alpha:1.0];

        if (styleMask & NSClosableWindowMask) {
            NSRect closeFrame;
            if (isEauTheme) {
                // Eau: Close button is first on LEFT
                closeFrame = NSMakeRect(leftPadding, 
                                        titleBarRect.size.height - buttonSize - topPadding,
                                        buttonSize, buttonSize);
            } else {
                closeFrame = [theme closeButtonFrameForBounds:drawRect];
            }
            
            // Draw button ball (Eau-style) or just the image (other themes)
            if (isEauTheme) {
                [URSThemeIntegration drawEauButtonBall:closeFrame withColor:closeColor];
            }
            
            // Draw button icon
            NSImage *closeImage = [NSImage imageNamed:@"common_Close"];
            if (closeImage) {
                NSRect imageRect = NSMakeRect(
                    closeFrame.origin.x + (closeFrame.size.width - closeImage.size.width) / 2,
                    closeFrame.origin.y + (closeFrame.size.height - closeImage.size.height) / 2,
                    closeImage.size.width, closeImage.size.height);
                [closeImage drawInRect:imageRect fromRect:NSZeroRect 
                             operation:NSCompositeSourceOver fraction:1.0];
            }
            NSLog(@"Drew close button at: %@", NSStringFromRect(closeFrame));
        }

        if (styleMask & NSMiniaturizableWindowMask) {
            NSRect miniFrame;
            if (isEauTheme) {
                // Eau: Mini button is second on LEFT
                miniFrame = NSMakeRect(leftPadding + buttonSize + buttonSpacing,
                                       titleBarRect.size.height - buttonSize - topPadding,
                                       buttonSize, buttonSize);
            } else {
                miniFrame = [theme miniaturizeButtonFrameForBounds:drawRect];
            }
            
            if (isEauTheme) {
                [URSThemeIntegration drawEauButtonBall:miniFrame withColor:miniColor];
            }
            
            NSImage *miniImage = [NSImage imageNamed:@"common_Miniaturize"];
            if (miniImage) {
                NSRect imageRect = NSMakeRect(
                    miniFrame.origin.x + (miniFrame.size.width - miniImage.size.width) / 2,
                    miniFrame.origin.y + (miniFrame.size.height - miniImage.size.height) / 2,
                    miniImage.size.width, miniImage.size.height);
                [miniImage drawInRect:imageRect fromRect:NSZeroRect
                            operation:NSCompositeSourceOver fraction:1.0];
            }
            NSLog(@"Drew miniaturize button at: %@", NSStringFromRect(miniFrame));
        }

        if (styleMask & NSResizableWindowMask) {
            NSRect zoomFrame;
            if (isEauTheme) {
                // Eau: Zoom button is third on LEFT
                zoomFrame = NSMakeRect(leftPadding + (buttonSize + buttonSpacing) * 2,
                                       titleBarRect.size.height - buttonSize - topPadding,
                                       buttonSize, buttonSize);
            } else {
                // Calculate based on miniaturize button
                NSRect miniFrame = [theme miniaturizeButtonFrameForBounds:drawRect];
                zoomFrame = NSMakeRect(miniFrame.origin.x + miniFrame.size.width + 4,
                                       miniFrame.origin.y, miniFrame.size.width, miniFrame.size.height);
            }
            
            if (isEauTheme) {
                [URSThemeIntegration drawEauButtonBall:zoomFrame withColor:zoomColor];
            }
            
            NSImage *zoomImage = [NSImage imageNamed:@"common_Zoom"];
            if (zoomImage) {
                NSRect imageRect = NSMakeRect(
                    zoomFrame.origin.x + (zoomFrame.size.width - zoomImage.size.width) / 2,
                    zoomFrame.origin.y + (zoomFrame.size.height - zoomImage.size.height) / 2,
                    zoomImage.size.width, zoomImage.size.height);
                [zoomImage drawInRect:imageRect fromRect:NSZeroRect
                            operation:NSCompositeSourceOver fraction:1.0];
            }
            NSLog(@"Drew zoom button at: %@", NSStringFromRect(zoomFrame));
        }

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