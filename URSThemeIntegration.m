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
    // Load default GSTheme
    @try {
        [GSTheme loadThemeNamed:nil];
        GSTheme *theme = [GSTheme theme];
        NSLog(@"GSTheme loaded: %@", [theme name] ?: @"Default");
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

        // Use GSTheme to draw titlebar decoration
        NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask;
        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:titlebarRect
                      withFrame:titlebarRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

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
    cairo_surface_t *imageSurface = cairo_image_surface_create_for_data(
        [bitmap bitmapData],
        CAIRO_FORMAT_ARGB32,
        [bitmap pixelsWide],
        [bitmap pixelsHigh],
        [bitmap bytesPerRow]
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

        // Use GSTheme to draw titlebar decoration
        NSRect drawRect = NSMakeRect(0, 0, titlebarSize.width, titlebarSize.height);
        NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask;
        GSThemeControlState state = isActive ? GSThemeNormalState : GSThemeSelectedState;

        // Draw the window titlebar using GSTheme
        [theme drawWindowBorder:drawRect
                      withFrame:drawRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:title ?: @""];

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

    if (enabled) {
        NSLog(@"GSTheme integration enabled");
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