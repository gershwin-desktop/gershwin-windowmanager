//
//  URSSnapPreviewOverlay.m
//  uroswm - Window Snap Preview Overlay
//
//  Shows a semi-transparent blue-tinted preview rectangle showing where
//  a window will snap when the mouse button is released.
//
//  This overlay uses a similar pattern to URSWindowSwitcherOverlay:
//  - Singleton for reuse
//  - Semi-transparent with rounded corners (when compositor is available)
//  - Above all windows during drag operations
//

#import "URSSnapPreviewOverlay.h"
#import "URSCompositingManager.h"
#import "URSSnapPreviewFrame.h"
#import "XCBConnection.h"
#import <xcb/shape.h>
#import <GNUstepGUI/GSDisplayServer.h>

// Constants for the snap preview appearance
static const CGFloat kCornerRadius = 8.0;
static const CGFloat kBorderWidth = 3.0;

// Private interface
@interface URSSnapPreviewOverlay ()
@property (assign, nonatomic) xcb_window_t overlayX11Window;
@end

#pragma mark - URSSnapPreviewOverlayView

@interface URSSnapPreviewOverlayView : NSView
@property (assign, nonatomic) BOOL useRoundedCorners;
@end

@implementation URSSnapPreviewOverlayView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    // Clear the background
    [[NSColor clearColor] set];
    NSRectFill(self.bounds);

    // Draw just the outline so the window beneath is visible
    NSBezierPath *previewPath;
    NSRect insetBounds = NSInsetRect(self.bounds, kBorderWidth / 2, kBorderWidth / 2);

    if (self.useRoundedCorners) {
        previewPath = [NSBezierPath bezierPathWithRoundedRect:insetBounds
                                                      xRadius:kCornerRadius
                                                      yRadius:kCornerRadius];
    } else {
        previewPath = [NSBezierPath bezierPathWithRect:insetBounds];
    }

    // Blue border outline only (no fill). Without a compositor the alpha is
    // not blended, so the frame must be fully opaque to keep its colour.
    [[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.9
                               alpha:self.useRoundedCorners ? 0.9 : 1.0] set];
    [previewPath setLineWidth:kBorderWidth];
    [previewPath stroke];
}

@end

#pragma mark - URSSnapPreviewOverlay

@implementation URSSnapPreviewOverlay

+ (instancetype)sharedOverlay {
    static URSSnapPreviewOverlay *sharedOverlay = nil;
    @synchronized(self) {
        if (!sharedOverlay) {
            sharedOverlay = [[URSSnapPreviewOverlay alloc] init];
        }
    }
    return sharedOverlay;
}

- (instancetype)init {
    // Start with a default size (will be updated when showing)
    NSRect contentRect = NSMakeRect(0, 0, 400, 300);

    self = [super initWithContentRect:contentRect
                            styleMask:NSBorderlessWindowMask
                              backing:NSBackingStoreBuffered
                                defer:NO];

    if (self) {
        // Configure window appearance
        // Use a high level to be above dragged windows
        [self setLevel:NSFloatingWindowLevel];
        [self setHasShadow:NO];
        [self setOpaque:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setIgnoresMouseEvents:YES];  // Don't intercept drag events
        [self setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary];
        [self setReleasedWhenClosed:NO];  // Keep window alive for reuse
        // A name lets tests and diagnostic tools find the preview among the
        // window manager's otherwise anonymous windows.
        [self setTitle:@"Snap Preview"];

        // Create the content view
        URSSnapPreviewOverlayView *contentView =
            [[URSSnapPreviewOverlayView alloc] initWithFrame:contentRect];
        [self setContentView:contentView];

        // The compositor keys its no-shadow set by X window id; -windowNumber
        // is the backend's window tag, not the X window id.
        _overlayX11Window = (xcb_window_t)(uintptr_t)
            [GSCurrentServer() windowDevice:[self windowNumber]];

        // Register with compositor to skip shadows (if compositing is active)
        URSCompositingManager *compositor = [URSCompositingManager sharedManager];
        [compositor setSkipShadowForWindow:_overlayX11Window];

        //NSLog(@"[SnapPreviewOverlay] Initialized (X11 window: %u)", _overlayX11Window);
    }

    return self;
}

// Without a compositor the ARGB window is shown with its undrawn interior as
// opaque black, so the window is shaped down to its outline instead.
- (void)applyFrameShapeForSize:(NSSize)size scale:(CGFloat)scale
                   compositing:(BOOL)compositing {
    xcb_connection_t *conn =
        [[XCBConnection sharedConnectionAsWindowManager:YES] connection];
    if (compositing) {
        // The shape of an earlier non-compositing preview must not linger
        xcb_shape_mask(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING,
                       _overlayX11Window, 0, 0, XCB_NONE);
        return;
    }
    URSSnapPreviewRect rects[4];
    int count = URSSnapPreviewFrameRects((uint32_t)size.width, (uint32_t)size.height,
                                         (uint32_t)ceil(kBorderWidth * scale), rects);
    xcb_rectangle_t xrects[4];
    for (int i = 0; i < count; i++) {
        xrects[i] = (xcb_rectangle_t){(int16_t)rects[i].x, (int16_t)rects[i].y,
                                      (uint16_t)rects[i].width,
                                      (uint16_t)rects[i].height};
    }
    xcb_shape_rectangles(conn, XCB_SHAPE_SO_SET, XCB_SHAPE_SK_BOUNDING,
                         XCB_CLIP_ORDERING_UNSORTED, _overlayX11Window, 0, 0,
                         count, xrects);
}

- (void)showPreviewForRect:(NSValue *)rectValue {
    if (!rectValue) {
        [self hide];
        return;
    }

    NSRect targetRect = [rectValue rectValue];

    // Update window frame to match target snap area
    [self setFrame:targetRect display:NO];

    // The window frame is in device pixels but the view is laid out in
    // points; at a GSScaleFactor other than 1 a view sized in pixels overhangs
    // the window, cutting off the right and bottom edges of the outline.
    CGFloat scale = [self userSpaceScaleFactor];
    URSSnapPreviewOverlayView *view = (URSSnapPreviewOverlayView *)[self contentView];
    [view setFrame:NSMakeRect(0, 0, targetRect.size.width / scale,
                              targetRect.size.height / scale)];

    // Check if compositing is active to determine whether to use rounded corners
    URSCompositingManager *compositor = [URSCompositingManager sharedManager];
    view.useRoundedCorners = [compositor compositingActive];

    [view setNeedsDisplay:YES];

    [self applyFrameShapeForSize:targetRect.size scale:scale
                      compositing:view.useRoundedCorners];

    // Ensure compositor skips shadows for this overlay window
    [compositor setSkipShadowForWindow:_overlayX11Window];

    // Show the overlay
    [self orderFront:nil];

    //NSLog(@"[SnapPreviewOverlay] Showing preview at (%.0f, %.0f) size %.0f x %.0f, rounded: %d",
//          targetRect.origin.x, targetRect.origin.y,
//          targetRect.size.width, targetRect.size.height,
//          view.useRoundedCorners);
}

- (void)hide {
    [self orderOut:self];

    // Clear the no-shadow flag (will be re-registered on next show)
    if (_overlayX11Window != XCB_NONE) {
        URSCompositingManager *compositor = [URSCompositingManager sharedManager];
        [compositor clearSkipShadowForWindow:_overlayX11Window];
    }

    //NSLog(@"[SnapPreviewOverlay] Hidden");
}

@end
