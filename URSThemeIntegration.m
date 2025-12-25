//
//  URSThemeIntegration.m
//  uroswm - GSTheme Window Decoration for Titlebars
//
//  Implementation of GSTheme window decoration rendering for X11 titlebars.
//

#import "URSThemeIntegration.h"
#import <XCBKit/XCBConnection.h>
#import <XCBKit/XCBFrame.h>
#import <cairo/cairo.h>
#import <cairo/cairo-xcb.h>
#import <objc/runtime.h>
#import "GSThemeTitleBar.h"

@implementation URSThemeIntegration

static URSThemeIntegration *sharedInstance = nil;

// Method to draw authentic Rik button balls using the exact gradient logic from RikWindowButtonCell
+ (void)drawRikButtonBall:(NSRect)frame withColor:(NSColor*)baseColor {
    // Replicate RikWindowButtonCell drawBallWithRect logic exactly
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

    // Drawing code from RikWindowButtonCell
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
        // Get titlebar dimensions
        XCBRect xcbRect = titlebar.windowRect;
        NSSize titlebarSize = NSMakeSize(xcbRect.size.width, xcbRect.size.height);

        // Create NSImage for GSTheme to render into
        NSImage *titlebarImage = [[NSImage alloc] initWithSize:titlebarSize];

        [titlebarImage lockFocus];

        // Clear background
        [[NSColor clearColor] set];
        NSRectFill(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height));

        // Define the titlebar rect
        NSRect titlebarRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);

        // Use GSTheme to draw titlebar decoration with all button types
        NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        NSLog(@"Drawing GSTheme titlebar with styleMask: 0x%lx, state: %d", (unsigned long)styleMask, (int)state);

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:titlebarRect
                      withFrame:titlebarRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

        // Add properly positioned buttons using Rik theme specifications
        // Based on Rik theme analysis: 17px spacing, LEFT-aligned (miniaturize first, then close)
        float buttonSize = 13.0;
        float buttonSpacing = 17.0;  // Rik theme uses 17px spacing per button
        float topMargin = 6.0;        // Center vertically in 24px titlebar
        float leftMargin = 2.0;       // Small margin from left edge

        if (styleMask & NSMiniaturizableWindowMask) {
            NSButton *miniButton = [theme standardWindowButton:NSWindowMiniaturizeButton forStyleMask:styleMask];
            if (miniButton) {
                // Rik positions miniaturize button at LEFT edge (causes title to move right by 17px)
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
                    NSLog(@"Drew miniaturize button at Rik LEFT position: %@", NSStringFromRect(miniFrame));
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
                    NSLog(@"Drew close button at Rik LEFT position: %@", NSStringFromRect(closeFrame));
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
                    NSLog(@"Drew zoom button at Rik LEFT position: %@", NSStringFromRect(zoomFrame));
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

    // Convert RGBA to BGRA for Cairo
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int offset = (y * bytesPerRow) + (x * 4);
            unsigned char r = bitmapPixels[offset];
            unsigned char g = bitmapPixels[offset + 1];
            unsigned char b = bitmapPixels[offset + 2];
            unsigned char a = bitmapPixels[offset + 3];

            // Swap R and B for BGRA format expected by Cairo
            bitmapPixels[offset] = b;     // Blue
            bitmapPixels[offset + 1] = g; // Green (unchanged)
            bitmapPixels[offset + 2] = r; // Red
            bitmapPixels[offset + 3] = a; // Alpha (unchanged)
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

    // Clear and paint GSTheme image to X11 surface
    cairo_set_operator(ctx, CAIRO_OPERATOR_CLEAR);
    cairo_paint(ctx);
    cairo_set_operator(ctx, CAIRO_OPERATOR_OVER);
    cairo_set_source_surface(ctx, imageSurface, 0, 0);
    cairo_paint(ctx);
    cairo_surface_flush(x11Surface);

    // Force immediate X11 update to ensure GSTheme is visible
    [titlebar.connection flush];
    xcb_flush([titlebar.connection connection]);

    NSLog(@"GSTheme image painted and surface flushed");

    // Cleanup
    cairo_surface_destroy(imageSurface);
    cairo_destroy(ctx);
    cairo_surface_destroy(x11Surface);
    [titlebar.connection flush];

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

        // Get titlebar dimensions
        XCBRect titlebarRect = [titlebar windowRect];
        NSSize titlebarSize = NSMakeSize(titlebarRect.size.width, titlebarRect.size.height);

        NSLog(@"Rendering standalone GSTheme titlebar: %dx%d for window %u",
              (int)titlebarSize.width, (int)titlebarSize.height, [window window]);

        // Create NSImage for GSTheme to render into
        NSImage *titlebarImage = [[NSImage alloc] initWithSize:titlebarSize];

        [titlebarImage lockFocus];

        // Clear background
        [[NSColor clearColor] set];
        NSRectFill(NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height));

        // Use GSTheme to draw titlebar decoration with all button types
        NSRect drawRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);
        NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask;
        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        NSLog(@"Drawing standalone GSTheme titlebar with styleMask: 0x%lx, state: %d", (unsigned long)styleMask, (int)state);

        // Log GSTheme padding and size values to verify Rik theme values
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
        NSLog(@"Expected Rik values: paddingLeft=2, paddingRight=2, paddingTop=6, buttonSize=13");

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:drawRect
                      withFrame:drawRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

        // Add properly positioned and styled buttons using direct theme image loading
        // Use manual Rik positioning since GSTheme methods return generic values
        NSLog(@"Standalone: Theme name: %@, class: %@", [theme name], [theme class]);

        BOOL isRikTheme = [[theme name] isEqualToString:@"Rik"];
        NSLog(@"Using %@ positioning for buttons", isRikTheme ? @"authentic Rik" : @"automatic GSTheme");

        // COMPARISON: Log what the actual Rik theme positioning methods return
        if (isRikTheme) {
            NSRect actualCloseFrame = [theme closeButtonFrameForBounds:drawRect];
            NSRect actualMiniFrame = [theme miniaturizeButtonFrameForBounds:drawRect];
            NSLog(@"COMPARISON - Actual Rik closeButtonFrame: %@", NSStringFromRect(actualCloseFrame));
            NSLog(@"COMPARISON - Actual Rik miniaturizeButtonFrame: %@", NSStringFromRect(actualMiniFrame));
        }

        if (styleMask & NSClosableWindowMask) {
            NSRect closeFrame;
            if (isRikTheme) {
                // Authentic Rik positioning from GSStandardDecorationView+Rik.m
                #define RIK_TITLEBAR_BUTTON_SIZE 15
                #define RIK_TITLEBAR_PADDING_LEFT 10.5
                #define RIK_TITLEBAR_PADDING_TOP 5.5

                closeFrame = NSMakeRect(
                    RIK_TITLEBAR_PADDING_LEFT,
                    drawRect.size.height - RIK_TITLEBAR_BUTTON_SIZE - RIK_TITLEBAR_PADDING_TOP,
                    RIK_TITLEBAR_BUTTON_SIZE, RIK_TITLEBAR_BUTTON_SIZE);
                NSLog(@"Standalone: Our Rik closeFrame: %@", NSStringFromRect(closeFrame));
                NSLog(@"COMPARISON - Using constants: left=%.1f, top=%.1f, size=%.1f",
                      RIK_TITLEBAR_PADDING_LEFT, RIK_TITLEBAR_PADDING_TOP, (float)RIK_TITLEBAR_BUTTON_SIZE);
            } else {
                closeFrame = [theme closeButtonFrameForBounds:drawRect];
                NSLog(@"Standalone: GSTheme closeButtonFrameForBounds returned: %@", NSStringFromRect(closeFrame));
            }

            // Load Rik theme specific button images
            NSImage *closeImage = nil;
            NSBundle *themeBundle = [theme bundle];

            if (themeBundle) {
                NSString *bundlePath = [themeBundle bundlePath];
                NSLog(@"Standalone: Rik theme bundle path: %@", bundlePath);

                // Try Rik-specific close button images
                NSArray *closeImageNames = @[@"CloseButton", @"close", @"Close", @"common_Close"];
                NSArray *imageExtensions = @[@"png", @"tiff", @"jpg", @"gif"];

                for (NSString *imageName in closeImageNames) {
                    for (NSString *ext in imageExtensions) {
                        NSString *imagePath = [themeBundle pathForResource:imageName ofType:ext];
                        if (imagePath) {
                            closeImage = [[NSImage alloc] initWithContentsOfFile:imagePath];
                            if (closeImage) {
                                NSLog(@"Standalone: Found Rik close button: %@", imagePath);
                                break;
                            }
                        }
                    }
                    if (closeImage) break;
                }
            }

            // Fallback to system image if no Rik-specific image found
            if (!closeImage) {
                closeImage = [NSImage imageNamed:@"common_Close"];
                NSLog(@"Standalone: Using fallback common_Close image");
            }

            NSLog(@"Standalone: Close button image: %@ (from %@)", closeImage, closeImage ? @"loaded" : @"failed to load");

            // Debug: Save the close button image to see what it looks like
            if (closeImage) {
                NSData *imageData = [closeImage TIFFRepresentation];
                if (imageData) {
                    [imageData writeToFile:@"/tmp/close_button_debug.tiff" atomically:YES];
                    NSLog(@"Saved close button image to /tmp/close_button_debug.tiff");
                }
            }

            if (closeImage) {
                // Draw authentic Rik close button using the exact color and method from NSWindow+Rik.m
                NSColor *closeButtonColor = [NSColor colorWithDeviceRed: 0.97 green: 0.26 blue: 0.23 alpha: 1.0];
                NSLog(@"Close button color - R:%.3f G:%.3f B:%.3f A:%.3f",
                      [closeButtonColor redComponent], [closeButtonColor greenComponent],
                      [closeButtonColor blueComponent], [closeButtonColor alphaComponent]);
                [URSThemeIntegration drawRikButtonBall:closeFrame withColor:closeButtonColor];
                NSLog(@"Standalone: Drew authentic Rik close button ball with red color");

                // Draw the 12x13 image centered in the 15x15 frame
                NSRect imageRect = NSMakeRect(
                    closeFrame.origin.x + (closeFrame.size.width - closeImage.size.width) / 2,
                    closeFrame.origin.y + (closeFrame.size.height - closeImage.size.height) / 2,
                    closeImage.size.width, closeImage.size.height);
                NSLog(@"Standalone: Close imageRect (centered %gx%g in %gx%g): %@",
                      closeImage.size.width, closeImage.size.height,
                      closeFrame.size.width, closeFrame.size.height,
                      NSStringFromRect(imageRect));

                [closeImage drawInRect:imageRect
                               fromRect:NSZeroRect
                              operation:NSCompositeSourceOver
                               fraction:1.0];
                NSLog(@"Standalone: Drew close button image with circular background at frame: %@", NSStringFromRect(closeFrame));
            } else {
                // Draw a simple close 'X' if no image available
                [[NSColor blackColor] set];
                NSBezierPath *xPath = [NSBezierPath bezierPath];
                [xPath moveToPoint:NSMakePoint(closeFrame.origin.x + 2, closeFrame.origin.y + 2)];
                [xPath lineToPoint:NSMakePoint(closeFrame.origin.x + closeFrame.size.width - 2, closeFrame.origin.y + closeFrame.size.height - 2)];
                [xPath moveToPoint:NSMakePoint(closeFrame.origin.x + closeFrame.size.width - 2, closeFrame.origin.y + 2)];
                [xPath lineToPoint:NSMakePoint(closeFrame.origin.x + 2, closeFrame.origin.y + closeFrame.size.height - 2)];
                [xPath setLineWidth:2.0];
                [xPath stroke];
                NSLog(@"Standalone: Drew fallback close 'X' at frame: %@", NSStringFromRect(closeFrame));
            }
        }

        if (styleMask & NSMiniaturizableWindowMask) {
            NSRect miniFrame;
            if (isRikTheme) {
                // Authentic Rik positioning: miniaturize button after close button with 4px spacing
                miniFrame = NSMakeRect(
                    RIK_TITLEBAR_PADDING_LEFT + RIK_TITLEBAR_BUTTON_SIZE + 4, // 4px padding between buttons
                    drawRect.size.height - RIK_TITLEBAR_BUTTON_SIZE - RIK_TITLEBAR_PADDING_TOP,
                    RIK_TITLEBAR_BUTTON_SIZE, RIK_TITLEBAR_BUTTON_SIZE);
                NSLog(@"Standalone: Our Rik miniFrame: %@", NSStringFromRect(miniFrame));
                NSLog(@"COMPARISON - Mini calc: x=%.1f+%.1f+4=%.1f, y=%.1f-%.1f-%.1f=%.1f",
                      RIK_TITLEBAR_PADDING_LEFT, (float)RIK_TITLEBAR_BUTTON_SIZE,
                      RIK_TITLEBAR_PADDING_LEFT + RIK_TITLEBAR_BUTTON_SIZE + 4,
                      drawRect.size.height, (float)RIK_TITLEBAR_BUTTON_SIZE, RIK_TITLEBAR_PADDING_TOP,
                      drawRect.size.height - RIK_TITLEBAR_BUTTON_SIZE - RIK_TITLEBAR_PADDING_TOP);
            } else {
                miniFrame = [theme miniaturizeButtonFrameForBounds:drawRect];
                NSLog(@"Standalone: GSTheme miniaturizeButtonFrameForBounds returned: %@", NSStringFromRect(miniFrame));
            }

            // Load Rik theme specific miniaturize button images
            NSImage *miniImage = nil;
            NSBundle *themeBundle = [theme bundle];

            if (themeBundle) {
                // Try Rik-specific miniaturize button images
                NSArray *miniImageNames = @[@"MiniaturizeButton", @"minimize", @"Minimize", @"common_Miniaturize"];
                NSArray *imageExtensions = @[@"png", @"tiff", @"jpg", @"gif"];

                for (NSString *imageName in miniImageNames) {
                    for (NSString *ext in imageExtensions) {
                        NSString *imagePath = [themeBundle pathForResource:imageName ofType:ext];
                        if (imagePath) {
                            miniImage = [[NSImage alloc] initWithContentsOfFile:imagePath];
                            if (miniImage) {
                                NSLog(@"Standalone: Found Rik miniaturize button: %@", imagePath);
                                break;
                            }
                        }
                    }
                    if (miniImage) break;
                }
            }

            // Fallback to system image if no Rik-specific image found
            if (!miniImage) {
                miniImage = [NSImage imageNamed:@"common_Miniaturize"];
                NSLog(@"Standalone: Using fallback common_Miniaturize image");
            }

            NSLog(@"Standalone: Miniaturize button image: %@ (from %@)", miniImage, miniImage ? @"loaded" : @"failed to load");

            // Debug: Save the miniaturize button image to see what it looks like
            if (miniImage) {
                NSData *imageData = [miniImage TIFFRepresentation];
                if (imageData) {
                    [imageData writeToFile:@"/tmp/miniaturize_button_debug.tiff" atomically:YES];
                    NSLog(@"Saved miniaturize button image to /tmp/miniaturize_button_debug.tiff");
                }
            }

            if (miniImage) {
                // Draw authentic Rik miniaturize button using the exact color from NSWindow+Rik.m
                NSColor *miniButtonColor = [NSColor colorWithDeviceRed: 0.9 green: 0.7 blue: 0.3 alpha: 1];
                NSLog(@"Mini button color - R:%.3f G:%.3f B:%.3f A:%.3f",
                      [miniButtonColor redComponent], [miniButtonColor greenComponent],
                      [miniButtonColor blueComponent], [miniButtonColor alphaComponent]);
                [URSThemeIntegration drawRikButtonBall:miniFrame withColor:miniButtonColor];
                NSLog(@"Standalone: Drew authentic Rik miniaturize button ball with yellow color");

                // Draw the 12x13 image centered in the 15x15 frame
                NSRect imageRect = NSMakeRect(
                    miniFrame.origin.x + (miniFrame.size.width - miniImage.size.width) / 2,
                    miniFrame.origin.y + (miniFrame.size.height - miniImage.size.height) / 2,
                    miniImage.size.width, miniImage.size.height);
                NSLog(@"Standalone: Mini imageRect (centered %gx%g in %gx%g): %@",
                      miniImage.size.width, miniImage.size.height,
                      miniFrame.size.width, miniFrame.size.height,
                      NSStringFromRect(imageRect));

                [miniImage drawInRect:imageRect
                              fromRect:NSZeroRect
                             operation:NSCompositeSourceOver
                             fraction:1.0];
                NSLog(@"Standalone: Drew miniaturize button image with circular background at frame: %@", NSStringFromRect(miniFrame));
            } else {
                // Draw a simple minimize line if no image available
                [[NSColor blackColor] set];
                NSRect lineRect = NSMakeRect(miniFrame.origin.x + 2,
                                           miniFrame.origin.y + miniFrame.size.height/2 - 1,
                                           miniFrame.size.width - 4, 2);
                NSRectFill(lineRect);
                NSLog(@"Standalone: Drew fallback minimize line at frame: %@", NSStringFromRect(miniFrame));
            }
        }

        if (styleMask & NSResizableWindowMask) {
            NSButton *zoomButton = [theme standardWindowButton:NSWindowZoomButton forStyleMask:styleMask];
            if (zoomButton) {
                NSRect zoomFrame;
                if (isRikTheme) {
                    // Authentic Rik positioning: zoom button after miniaturize button
                    zoomFrame = NSMakeRect(
                        RIK_TITLEBAR_PADDING_LEFT + (RIK_TITLEBAR_BUTTON_SIZE + 4) * 2, // After miniaturize button
                        drawRect.size.height - RIK_TITLEBAR_BUTTON_SIZE - RIK_TITLEBAR_PADDING_TOP,
                        RIK_TITLEBAR_BUTTON_SIZE, RIK_TITLEBAR_BUTTON_SIZE);
                    NSLog(@"Standalone: Authentic Rik zoomFrame: %@", NSStringFromRect(zoomFrame));
                } else {
                    // Calculate zoom button position based on miniaturize button + some spacing
                    NSRect miniFrame = [theme miniaturizeButtonFrameForBounds:drawRect];
                    float buttonSpacing = 2.0; // Small gap between buttons

                    zoomFrame = NSMakeRect(
                        miniFrame.origin.x + miniFrame.size.width + buttonSpacing,
                        miniFrame.origin.y,
                        miniFrame.size.width,
                        miniFrame.size.height
                    );
                    NSLog(@"Standalone: Calculated zoom frame based on miniaturize: %@", NSStringFromRect(zoomFrame));
                }

                NSImage *buttonImage = [zoomButton image];
                if (buttonImage) {
                    // Draw authentic Rik zoom button using the exact color from NSWindow+Rik.m
                    NSColor *zoomButtonColor = [NSColor colorWithDeviceRed: 0.322 green: 0.778 blue: 0.244 alpha: 1];
                    NSLog(@"Zoom button color - R:%.3f G:%.3f B:%.3f A:%.3f",
                          [zoomButtonColor redComponent], [zoomButtonColor greenComponent],
                          [zoomButtonColor blueComponent], [zoomButtonColor alphaComponent]);
                    [URSThemeIntegration drawRikButtonBall:zoomFrame withColor:zoomButtonColor];
                    NSLog(@"Standalone: Drew authentic Rik zoom button ball with green color");

                    // Draw the image centered in the 15x15 frame (most zoom images are also 12x13)
                    NSRect imageRect = NSMakeRect(
                        zoomFrame.origin.x + (zoomFrame.size.width - buttonImage.size.width) / 2,
                        zoomFrame.origin.y + (zoomFrame.size.height - buttonImage.size.height) / 2,
                        buttonImage.size.width, buttonImage.size.height);
                    [buttonImage drawInRect:imageRect
                                   fromRect:NSZeroRect
                                  operation:NSCompositeSourceOver
                                   fraction:1.0];
                    NSLog(@"Standalone: Drew zoom button with circular background at frame: %@", NSStringFromRect(zoomFrame));
                } else {
                    NSLog(@"Standalone: No zoom button image available");
                }
            }
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