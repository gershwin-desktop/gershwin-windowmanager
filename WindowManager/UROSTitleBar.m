//
//  UROSTitleBar.m
//  uroswm - Independent GSTheme Titlebar
//
//  Implementation of completely independent titlebar using only GSTheme.
//  No XCBKit titlebar dependency at all.
//

#import "UROSTitleBar.h"
#import <cairo/cairo.h>
#import <cairo/cairo-xcb.h>
#import <xcb/xcb.h>
#import <XCBKit/services/EWMHService.h>

@implementation UROSTitleBar

- (instancetype)initWithConnection:(XCBConnection*)connection
                             frame:(NSRect)frame
                      parentWindow:(xcb_window_t)parentWindow {
    self = [super init];
    if (self) {
        self.connection = connection;
        self.frame = frame;
        self.isActive = YES;
        self.title = @"";

        // Create our own X11 window for the titlebar
        [self createTitlebarWindow:parentWindow];

        // Create pixmap for rendering
        [self createPixmap];

        NSLog(@"UROSTitleBar: Created independent titlebar %u", self.windowId);
    }
    return self;
}

- (void)createTitlebarWindow:(xcb_window_t)parentWindow {
    // Get the screen info
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];

    // Create our titlebar window
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t values[2];
    values[0] = [screen screen]->white_pixel;
    values[1] = XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_BUTTON_PRESS |
                XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION |
                XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW;

    self.windowId = xcb_generate_id([self.connection connection]);

    xcb_create_window([self.connection connection],
                      XCB_COPY_FROM_PARENT,
                      self.windowId,
                      parentWindow,
                      (int16_t)self.frame.origin.x,
                      (int16_t)self.frame.origin.y,
                      (uint16_t)self.frame.size.width,
                      (uint16_t)self.frame.size.height,
                      0, // border width
                      XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      [screen screen]->root_visual,
                      mask,
                      values);

    // Set up visual
    self.visual = [[XCBVisual alloc] initWithVisualId:[screen screen]->root_visual];
    [self.visual setVisualTypeForScreen:screen];

    NSLog(@"UROSTitleBar: Created X11 window %u", self.windowId);
}

- (void)createPixmap {
    self.pixmap = xcb_generate_id([self.connection connection]);

    xcb_create_pixmap([self.connection connection],
                      24, // depth
                      self.pixmap,
                      self.windowId,
                      (uint16_t)self.frame.size.width,
                      (uint16_t)self.frame.size.height);

    NSLog(@"UROSTitleBar: Created pixmap %u", self.pixmap);
}

- (void)renderWithGSTheme {
    @try {
        GSTheme *theme = [GSTheme theme];
        if (!theme) {
            NSLog(@"UROSTitleBar: No GSTheme available");
            return;
        }

        NSLog(@"UROSTitleBar: Rendering with GSTheme - title: %@, active: %d",
              self.title, self.isActive);

        // Create NSImage for GSTheme rendering
        NSImage *titlebarImage = [[NSImage alloc] initWithSize:self.frame.size];

        [titlebarImage lockFocus];

        // Clear background
        [[NSColor clearColor] set];
        NSRectFill(NSMakeRect(0, 0, self.frame.size.width, self.frame.size.height));

        // Use GSTheme to draw titlebar
        NSRect drawRect = NSMakeRect(0, 0, self.frame.size.width, self.frame.size.height);
        NSUInteger styleMask = NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask;
        GSThemeControlState state = self.isActive ? GSThemeNormalState : GSThemeSelectedState;

        [theme drawWindowBorder:drawRect
                      withFrame:drawRect
                   forStyleMask:styleMask
                          state:state
                       andTitle:self.title];

        [titlebarImage unlockFocus];

        // Transfer to X11 pixmap
        [self transferImageToPixmap:titlebarImage];

        // Copy pixmap to window
        [self copyPixmapToWindow];

        [self.connection flush];

        NSLog(@"UROSTitleBar: GSTheme rendering completed successfully");

    } @catch (NSException *exception) {
        NSLog(@"UROSTitleBar: Exception during GSTheme rendering: %@", exception.reason);
    }
}

- (void)transferImageToPixmap:(NSImage*)image {
    // Convert NSImage to bitmap
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
        NSLog(@"UROSTitleBar: Failed to create bitmap from GSTheme image");
        return;
    }

    // Create Cairo surface for pixmap
    cairo_surface_t *pixmapSurface = cairo_xcb_surface_create(
        [self.connection connection],
        self.pixmap,
        [self.visual visualType],
        (int)self.frame.size.width,
        (int)self.frame.size.height
    );

    if (cairo_surface_status(pixmapSurface) != CAIRO_STATUS_SUCCESS) {
        NSLog(@"UROSTitleBar: Failed to create Cairo pixmap surface");
        cairo_surface_destroy(pixmapSurface);
        return;
    }

    cairo_t *ctx = cairo_create(pixmapSurface);

    // Create Cairo image surface from bitmap
    cairo_surface_t *imageSurface = cairo_image_surface_create_for_data(
        [bitmap bitmapData],
        CAIRO_FORMAT_ARGB32,
        [bitmap pixelsWide],
        [bitmap pixelsHigh],
        [bitmap bytesPerRow]
    );

    if (cairo_surface_status(imageSurface) != CAIRO_STATUS_SUCCESS) {
        NSLog(@"UROSTitleBar: Failed to create Cairo image surface");
        cairo_surface_destroy(imageSurface);
        cairo_destroy(ctx);
        cairo_surface_destroy(pixmapSurface);
        return;
    }

    // Paint image to pixmap
    cairo_set_operator(ctx, CAIRO_OPERATOR_OVER);
    cairo_set_source_surface(ctx, imageSurface, 0, 0);
    cairo_paint(ctx);
    cairo_surface_flush(pixmapSurface);

    // Cleanup
    cairo_surface_destroy(imageSurface);
    cairo_destroy(ctx);
    cairo_surface_destroy(pixmapSurface);
}

- (void)copyPixmapToWindow {
    xcb_copy_area([self.connection connection],
                  self.pixmap,
                  self.windowId,
                  xcb_generate_id([self.connection connection]), // GC
                  0, 0, // src x, y
                  0, 0, // dst x, y
                  (uint16_t)self.frame.size.width,
                  (uint16_t)self.frame.size.height);
}

- (void)setTitle:(NSString*)title {
    _title = title ?: @"";
    [self renderWithGSTheme];
}

- (void)setActive:(BOOL)active {
    if (self.isActive != active) {
        self.isActive = active;
        [self renderWithGSTheme];
    }
}

- (void)show {
    xcb_map_window([self.connection connection], self.windowId);
    [self.connection flush];
    NSLog(@"UROSTitleBar: Titlebar window mapped");
}

- (void)hide {
    xcb_unmap_window([self.connection connection], self.windowId);
    [self.connection flush];
}

- (void)updateFrame:(NSRect)newFrame {
    self.frame = newFrame;

    // Resize window
    uint32_t values[4];
    values[0] = (uint32_t)newFrame.origin.x;
    values[1] = (uint32_t)newFrame.origin.y;
    values[2] = (uint32_t)newFrame.size.width;
    values[3] = (uint32_t)newFrame.size.height;

    xcb_configure_window([self.connection connection],
                         self.windowId,
                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                         XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                         values);

    // Recreate pixmap with new size
    xcb_free_pixmap([self.connection connection], self.pixmap);
    [self createPixmap];

    // Re-render
    [self renderWithGSTheme];
}

- (void)handleButtonPress:(xcb_button_press_event_t*)event {
    NSLog(@"UROSTitleBar: Button press at %d,%d", event->event_x, event->event_y);

    // Define button areas (using standard macOS positions)
    NSRect closeButtonRect = NSMakeRect(6, 6, 13, 13);
    NSRect minimizeButtonRect = NSMakeRect(26, 6, 13, 13);
    NSRect maximizeButtonRect = NSMakeRect(46, 6, 13, 13);

    NSPoint clickPoint = NSMakePoint(event->event_x, event->event_y);

    if (NSPointInRect(clickPoint, closeButtonRect)) {
        [self handleCloseButton];
    } else if (NSPointInRect(clickPoint, minimizeButtonRect)) {
        [self handleMinimizeButton];
    } else if (NSPointInRect(clickPoint, maximizeButtonRect)) {
        [self handleMaximizeButton];
    } else {
        // Handle titlebar dragging
        [self beginWindowDrag:event];
    }
}

- (void)handleCloseButton {
    NSLog(@"UROSTitleBar: Close button pressed");

    XCBFrame *frame = [self findAssociatedFrame];
    if (frame) {
        XCBWindow *clientWindow = [frame childWindowForKey:ClientWindow];
        if (clientWindow) {
            NSLog(@"UROSTitleBar: Closing client window via xcbkit");
            [clientWindow close];
            [self.connection flush];
        }
    }
}

- (void)handleMinimizeButton {
    NSLog(@"UROSTitleBar: Minimize button pressed");

    XCBFrame *frame = [self findAssociatedFrame];
    if (frame) {
        NSLog(@"UROSTitleBar: Minimizing frame via xcbkit");
        [frame minimize];
        [self.connection flush];
    }
}

- (void)handleMaximizeButton {
    NSLog(@"UROSTitleBar: Maximize/Zoom button pressed");

    XCBFrame *frame = [self findAssociatedFrame];
    if (frame) {
        if ([frame isMaximized]) {
            // Restore (unzoom) the window
            NSLog(@"UROSTitleBar: Restoring window from maximized state via xcbkit");
            [frame restoreDimensionAndPosition];
        } else {
            // Maximize (zoom) the window to workarea size (respects struts)
            NSLog(@"UROSTitleBar: Maximizing window via xcbkit");
            
            // Get workarea from root window to respect struts
            XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
            XCBWindow *rootWindow = [screen rootWindow];
            EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:self.connection];
            
            int32_t workareaX = 0, workareaY = 0;
            uint32_t workareaWidth = [screen width], workareaHeight = [screen height];
            
            if ([ewmhService readWorkareaForRootWindow:rootWindow 
                                                     x:&workareaX 
                                                     y:&workareaY 
                                                 width:&workareaWidth 
                                                height:&workareaHeight]) {
                NSLog(@"UROSTitleBar: Using workarea for maximize: x=%d, y=%d, w=%u, h=%u", 
                      workareaX, workareaY, workareaWidth, workareaHeight);
            } else {
                NSLog(@"UROSTitleBar: Failed to read workarea, using full screen");
                workareaX = 0;
                workareaY = 0;
                workareaWidth = [screen width];
                workareaHeight = [screen height];
            }
            
            // Save pre-maximize rect for restore
            [frame setOldRect:[frame windowRect]];

            // Use programmatic resize that follows the same code path as manual resize
            XCBRect targetRect = XCBMakeRect(XCBMakePoint(workareaX, workareaY),
                                              XCBMakeSize(workareaWidth, workareaHeight));
            [frame programmaticResizeToRect:targetRect];
            [frame setIsMaximized:YES];
            [frame setMaximizedHorizontally:YES];
            [frame setMaximizedVertically:YES];

            // Update resize zone positions and shape mask for new dimensions
            [frame updateAllResizeZonePositions];
            [frame applyRoundedCornersShapeMask];
        }
        [self.connection flush];
    }
}

- (void)beginWindowDrag:(xcb_button_press_event_t*)event {
    NSLog(@"UROSTitleBar: Beginning window drag");
    // TODO: Implement window dragging
}

- (XCBFrame*)findAssociatedFrame {
    // Search through connection's windows to find the frame associated with this titlebar
    NSDictionary *windowsMap = [self.connection windowsMap];

    for (NSString *windowIdString in windowsMap) {
        XCBWindow *window = [windowsMap objectForKey:windowIdString];

        if ([window isKindOfClass:[XCBFrame class]]) {
            XCBFrame *frame = (XCBFrame*)window;
            XCBWindow *titlebarWindow = [frame childWindowForKey:TitleBar];

            if (titlebarWindow && [titlebarWindow window] == self.windowId) {
                return frame;
            }
        }
    }
    return nil;
}

- (void)handleMotion:(xcb_motion_notify_event_t*)event {
    // TODO: Handle window dragging
}

- (void)destroy {
    if (self.pixmap) {
        xcb_free_pixmap([self.connection connection], self.pixmap);
    }
    if (self.windowId) {
        xcb_destroy_window([self.connection connection], self.windowId);
    }
    [self.connection flush];

    NSLog(@"UROSTitleBar: Titlebar destroyed");
}

- (void)dealloc {
    [self destroy];
}

@end