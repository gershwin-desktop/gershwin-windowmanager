//
//  URSWindowSwitcherOverlay.m
//  uroswm - Alt-Tab Window Switcher Overlay
//
//  Visual overlay showing application icons and names during Alt-Tab cycling
//  Displays a horizontal strip with rounded rect background, icons, and app name
//
//  The rounded corners are only transparent while this window manager's own
//  compositor runs: the GNUstep backend already gives the window a 32-bit
//  ARGB visual and the compositor redirects all windows.  Without compositing
//  the corners are drawn square instead.
//

#import "URSWindowSwitcherOverlay.h"
#import "URSCompositingManager.h"
#import <GNUstepGUI/GSDisplayServer.h>

// Constants for the switcher appearance
static const CGFloat kIconSize = 48.0;
static const CGFloat kIconSpacing = 20.0;
static const CGFloat kPadding = 24.0;
static const CGFloat kCornerRadius = 22.0;
static const CGFloat kTitleHeight = 20.0;
static const CGFloat kSelectionPadding = 6.0;

#pragma mark - URSWindowSwitcherOverlayView

@interface URSWindowSwitcherOverlayView : NSView
@property (strong, nonatomic) NSArray *titles;
@property (strong, nonatomic) NSArray *icons;  // Array of NSImage objects (or NSNull for missing icons)
@property (assign, nonatomic) NSInteger selectedIndex;
@property (assign, nonatomic) BOOL useRoundedCorners;  // Whether to use rounded corners
@end

@implementation URSWindowSwitcherOverlayView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    // Clear the background
    [[NSColor clearColor] set];
    NSRectFill(self.bounds);
    
    if (!self.titles || [self.titles count] == 0) {
        return;
    }
    
    NSInteger count = [self.titles count];
    
    // Draw the rounded or square rectangle background with translucency
    NSBezierPath *backgroundPath;
    if (self.useRoundedCorners) {
        backgroundPath = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                         xRadius:kCornerRadius
                                                         yRadius:kCornerRadius];
    } else {
        // Square corners when compositing is disabled
        backgroundPath = [NSBezierPath bezierPathWithRect:self.bounds];
    }
    
    // Light grey background
    [[NSColor colorWithCalibratedWhite:0.75 alpha:0.95] set];
    [backgroundPath fill];
    
    // Medium grey border
    [[NSColor colorWithCalibratedWhite:0.55 alpha:0.8] set];
    [backgroundPath setLineWidth:1.0];
    [backgroundPath stroke];
    
    // Calculate icon positions
    CGFloat totalWidth = count * kIconSize + (count - 1) * kIconSpacing;
    CGFloat startX = (self.bounds.size.width - totalWidth) / 2.0;
    CGFloat iconY = kPadding + kTitleHeight + 8;
    
    // Draw each icon slot
    for (NSInteger i = 0; i < count; i++) {
        CGFloat x = startX + i * (kIconSize + kIconSpacing);
        NSRect iconRect = NSMakeRect(x, iconY, kIconSize, kIconSize);
        
        // Draw selection highlight for the current item - always use rounded corners
        if (i == self.selectedIndex) {
            NSRect selectionRect = NSInsetRect(iconRect, -kSelectionPadding, -kSelectionPadding);
            NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:selectionRect
                                                                          xRadius:8.0
                                                                          yRadius:8.0];
            [[NSColor colorWithCalibratedWhite:0.35 alpha:0.6] set];
            [selectionPath fill];
            
            // Dark grey border for selection
            [[NSColor colorWithCalibratedWhite:0.25 alpha:0.8] set];
            [selectionPath setLineWidth:2.0];
            [selectionPath stroke];
        }
        
        // Try to get the actual app icon
        NSImage *appIcon = nil;
        if (self.icons && i < [self.icons count]) {
            id iconObject = [self.icons objectAtIndex:i];
            if ([iconObject isKindOfClass:[NSImage class]]) {
                appIcon = (NSImage *)iconObject;
            }
        }
        
        if (appIcon) {
            // Draw the actual application icon
            [appIcon drawInRect:iconRect
                       fromRect:NSZeroRect
                      operation:NSCompositeSourceOver
                       fraction:1.0];
        } else {
            // Fallback: Draw a placeholder icon with app initial (as before)
            NSBezierPath *iconPath = [NSBezierPath bezierPathWithRoundedRect:iconRect
                                                                     xRadius:12.0
                                                                     yRadius:12.0];
            
            // Generate a color based on the title
            NSString *title = [self.titles objectAtIndex:i];
            CGFloat hue = (CGFloat)(([title hash] % 100) / 100.0);
            NSColor *iconColor = [NSColor colorWithCalibratedHue:hue
                                                      saturation:0.6
                                                      brightness:0.7
                                                           alpha:1.0];
            [iconColor set];
            [iconPath fill];
            
            // Draw app initial in the icon
            NSString *initial = @"?";
            if (title && [title length] > 0) {
                initial = [[title substringToIndex:1] uppercaseString];
            }
            
            NSDictionary *initialAttrs = @{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:32],
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1.0]
            };
            
            NSSize initialSize = [initial sizeWithAttributes:initialAttrs];
            NSPoint initialPoint = NSMakePoint(x + (kIconSize - initialSize.width) / 2,
                                               iconY + (kIconSize - initialSize.height) / 2);
            [initial drawAtPoint:initialPoint withAttributes:initialAttrs];
        }
    }
    
    // Draw the selected app name centered at the bottom
    if (self.selectedIndex >= 0 && self.selectedIndex < count) {
        NSString *selectedTitle = [self.titles objectAtIndex:self.selectedIndex];
        
        // Truncate if too long
        if ([selectedTitle length] > 40) {
            selectedTitle = [[selectedTitle substringToIndex:37] stringByAppendingString:@"..."];
        }
        
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.15 alpha:1.0]
        };
        
        NSSize titleSize = [selectedTitle sizeWithAttributes:titleAttrs];
        NSPoint titlePoint = NSMakePoint((self.bounds.size.width - titleSize.width) / 2,
                                         kPadding);
        [selectedTitle drawAtPoint:titlePoint withAttributes:titleAttrs];
    }
}

@end

#pragma mark - URSWindowSwitcherOverlay

@implementation URSWindowSwitcherOverlay

+ (instancetype)sharedOverlay {
    static URSWindowSwitcherOverlay *sharedOverlay = nil;
    @synchronized(self) {
        if (!sharedOverlay) {
            sharedOverlay = [[URSWindowSwitcherOverlay alloc] init];
        }
    }
    return sharedOverlay;
}

- (instancetype)init {
    // Start with a reasonable default size
    NSRect contentRect = NSMakeRect(0, 0, 400, 140);
    
    self = [super initWithContentRect:contentRect
                            styleMask:NSBorderlessWindowMask
                              backing:NSBackingStoreBuffered
                                defer:NO];
    
    if (self) {
        // Configure window appearance
        // Use NSPopUpMenuWindowLevel + 1 to ensure it's above all windows including menus
        // NSStatusWindowLevel (25) or NSPopUpMenuWindowLevel (101) are good choices
        [self setLevel:NSPopUpMenuWindowLevel + 10];  // Above everything
        [self setHasShadow:YES];
        [self setOpaque:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setIgnoresMouseEvents:YES];
        [self setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary];
        [self setReleasedWhenClosed:NO];  // Keep window alive for reuse
        
        // Create the content view
        URSWindowSwitcherOverlayView *contentView = 
            [[URSWindowSwitcherOverlayView alloc] initWithFrame:contentRect];
        [self setContentView:contentView];
    }
    
    return self;
}

// Where the panel of the given size belongs, in the device pixels window
// frames use.  Derived from the screen every time and never from the panel's
// current frame: whenever something else moves the window - the window manager
// keeping it out of a strut, for instance - folding that position back into
// the next one would let the offset accumulate and walk the panel across the
// screen.
- (NSRect)frameForSize:(NSSize)size {
    NSScreen *mainScreen = [NSScreen mainScreen];
    if (!mainScreen) {
        mainScreen = [[NSScreen screens] firstObject];
    }
    if (!mainScreen) {
        return NSMakeRect(0, 0, size.width, size.height);
    }

    NSRect screenFrame = [mainScreen frame];

    // Center horizontally
    CGFloat x = screenFrame.origin.x + (screenFrame.size.width - size.width) / 2;

    // Position at golden ratio (flipped) - more space at TOP than bottom
    // Golden ratio: 1 / phi ≈ 0.618, so place at 1 - 0.618 = 0.382 from top
    // This leaves ~38.2% space above, ~61.8% below
    CGFloat goldenRatioY = screenFrame.origin.y + (screenFrame.size.height * 0.382) - (size.height / 2);

    return NSMakeRect(x, goldenRatioY, size.width, size.height);
}

- (void)showCenteredOnScreen {
    [self setFrame:[self frameForSize:[self frame].size] display:NO];
    
    // Force the window to the absolute front, above all other windows
    [self makeKeyAndOrderFront:nil];
    [self orderFrontRegardless];
    
    //NSLog(@"[WindowSwitcherOverlay] Showing at golden ratio (more top space) at %.0f, %.0f (level: %ld)", x, goldenRatioY, (long)[self level]);
}

- (void)hide {
    // Immediately remove from screen and ensure it's completely hidden
    [self orderOut:self];
    //NSLog(@"[WindowSwitcherOverlay] Hidden immediately");
}

- (void)updateWithTitles:(NSArray *)titles icons:(NSArray *)icons currentIndex:(NSInteger)index {
    if (!titles || [titles count] == 0) {
        [self hide];
        return;
    }
    
    NSInteger count = [titles count];

    // Window frames are in device pixels while the view draws in points, so at
    // GSScaleFactor 2 this layout needs a window twice its size - otherwise the
    // panel is half as large as its contents and clips them.
    CGFloat scale = [self userSpaceScaleFactor];
    
    // Calculate required window size
    CGFloat totalIconWidth = count * kIconSize + (count - 1) * kIconSpacing;
    CGFloat windowWidth = totalIconWidth + 2 * kPadding + 2 * kSelectionPadding;
    CGFloat windowHeight = kPadding * 2 + kIconSize + kTitleHeight + kSelectionPadding * 2 + 8;
    
    // Limit to reasonable max width.  The screen frame is in device pixels, so
    // it has to be brought back to points before it can bound this layout.
    NSScreen *screen = [NSScreen mainScreen] ?: [[NSScreen screens] firstObject];
    CGFloat maxWidth = 800;
    if (screen) {
        CGFloat screenWidthInPoints = [screen frame].size.width / scale;
        maxWidth = MIN(maxWidth, screenWidthInPoints - 2 * kPadding);
    }
    if (windowWidth > maxWidth) {
        windowWidth = maxWidth;
    }
    if (windowWidth < 400) {
        windowWidth = 400;
    }
    
    // Re-place the panel for its new size
    [self setFrame:[self frameForSize:NSMakeSize(windowWidth * scale,
                                                 windowHeight * scale)]
           display:NO];
    
    // Update content view frame
    URSWindowSwitcherOverlayView *view = (URSWindowSwitcherOverlayView *)[self contentView];
    [view setFrame:NSMakeRect(0, 0, windowWidth, windowHeight)];
    view.titles = titles;
    view.icons = icons;  // May be nil for fallback to letter icons
    view.selectedIndex = index;
    
    // Check if compositing is active to determine whether to use rounded corners
    // Import the compositing manager header at the top if needed
    URSCompositingManager *compositor = [URSCompositingManager sharedManager];
    view.useRoundedCorners = [compositor compositingActive];
    if (view.useRoundedCorners) {
        // A rectangular drop shadow leaves unshadowed square notches around
        // the arcs, so the compositor has to know the radius.  -windowNumber
        // is the backend's window tag, not the X window id.
        xcb_window_t xid = (xcb_window_t)(uintptr_t)
            [GSCurrentServer() windowDevice:[self windowNumber]];
        [compositor setShadowCornerRadius:kCornerRadius * scale
                                forWindow:xid];
    }

    [view setNeedsDisplay:YES];
    // Force synchronous redraw so the highlight updates immediately.
    // On GNUstep/X11 with the hybrid event loop, -setNeedsDisplay: is
    // asynchronous and can be delayed until the next NSRunLoop iteration,
    // which may not happen until after more XCB events are processed.
    // A fast typist pressing Tab repeatedly can thus see a stale highlight.
    [view displayIfNeeded];
    
    //NSLog(@"[WindowSwitcherOverlay] Updated with %lu titles, selected: %ld, rounded corners: %d",
//          (unsigned long)count, (long)index, view.useRoundedCorners);
}

@end
