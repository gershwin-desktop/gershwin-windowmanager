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

// Constants for the snap preview appearance
static const CGFloat kCornerRadius = 8.0;
static const CGFloat kBorderWidth = 3.0;

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

    // Blue border outline only (no fill)
    [[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.9 alpha:0.9] set];
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

        // Create the content view
        URSSnapPreviewOverlayView *contentView =
            [[URSSnapPreviewOverlayView alloc] initWithFrame:contentRect];
        [self setContentView:contentView];

        NSLog(@"[SnapPreviewOverlay] Initialized");
    }

    return self;
}

- (void)showPreviewForRect:(NSValue *)rectValue {
    if (!rectValue) {
        [self hide];
        return;
    }

    NSRect targetRect = [rectValue rectValue];

    // Update window frame to match target snap area
    [self setFrame:targetRect display:NO];

    // Update content view frame
    URSSnapPreviewOverlayView *view = (URSSnapPreviewOverlayView *)[self contentView];
    [view setFrame:NSMakeRect(0, 0, targetRect.size.width, targetRect.size.height)];

    // Check if compositing is active to determine whether to use rounded corners
    URSCompositingManager *compositor = [URSCompositingManager sharedManager];
    view.useRoundedCorners = [compositor compositingActive];

    [view setNeedsDisplay:YES];

    // Show the overlay
    [self orderFront:nil];

    NSLog(@"[SnapPreviewOverlay] Showing preview at (%.0f, %.0f) size %.0f x %.0f, rounded: %d",
          targetRect.origin.x, targetRect.origin.y,
          targetRect.size.width, targetRect.size.height,
          view.useRoundedCorners);
}

- (void)hide {
    [self orderOut:self];
    NSLog(@"[SnapPreviewOverlay] Hidden");
}

@end
