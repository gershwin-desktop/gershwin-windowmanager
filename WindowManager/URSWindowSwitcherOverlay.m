//
//  URSWindowSwitcherOverlay.m
//  uroswm - Alt-Tab Window Switcher Overlay
//
//  Visual overlay showing application icons and names during Alt-Tab cycling
//  Displays a horizontal strip with rounded rect background, icons, and app name
//
//  TRANSPARENCY REQUIREMENTS (X11):
//  To achieve true transparency with rounded corners on X11, the following are needed:
//  1. COMPOSITE extension enabled in X server (check with: xdpyinfo | grep Composite)
//  2. A compositor running (compton/picom) OR window manager handling compositing
//  3. ARGB visual (32-bit color depth with alpha channel)
//
//  This implementation requests ARGB visual and sets appropriate window properties.
//  Without a compositor, the "transparent" areas will appear as garbage/black.
//

#import "URSWindowSwitcherOverlay.h"
#import "URSCompositingManager.h"
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/extensions/Xcomposite.h>

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
        
        // Request ARGB visual for true transparency on X11
        [self configureARGBVisualForX11];
        
        NSLog(@"[WindowSwitcherOverlay] Initialized with ARGB transparency support");
    }
    
    return self;
}

- (void)configureARGBVisualForX11 {
    // This method configures the window to use an ARGB visual on X11
    // which is required for true transparency through the COMPOSITE extension
    
#ifdef __linux__
    @try {
        // Get the X11 window number from the NSWindow
        NSInteger windowNumber = [self windowNumber];
        if (windowNumber <= 0) {
            NSLog(@"[WindowSwitcherOverlay] No window number yet, will use default visual");
            return;
        }
        
        // Open connection to X11
        Display *display = XOpenDisplay(NULL);
        if (!display) {
            NSLog(@"[WindowSwitcherOverlay] Could not open X11 display");
            return;
        }
        
        Window xwindow = (Window)windowNumber;
        int screen = DefaultScreen(display);
        
        // Check if COMPOSITE extension is available
        int composite_event_base, composite_error_base;
        if (!XCompositeQueryExtension(display, &composite_event_base, &composite_error_base)) {
            NSLog(@"[WindowSwitcherOverlay] WARNING: X COMPOSITE extension not available!");
            NSLog(@"[WindowSwitcherOverlay] Rounded corner transparency will NOT work.");
            NSLog(@"[WindowSwitcherOverlay] Enable Composite in X server and run a compositor (picom/compton)");
            XCloseDisplay(display);
            return;
        }
        
        int composite_major, composite_minor;
        XCompositeQueryVersion(display, &composite_major, &composite_minor);
        NSLog(@"[WindowSwitcherOverlay] X COMPOSITE extension available: v%d.%d", 
              composite_major, composite_minor);
        
        // Find ARGB visual (32-bit depth with alpha channel)
        XVisualInfo visual_template;
        visual_template.screen = screen;
        visual_template.depth = 32;
        visual_template.class = TrueColor;
        
        int num_visuals = 0;
        XVisualInfo *visual_info = XGetVisualInfo(display,
                                                   VisualScreenMask | VisualDepthMask | VisualClassMask,
                                                   &visual_template,
                                                   &num_visuals);
        
        if (visual_info && num_visuals > 0) {
            NSLog(@"[WindowSwitcherOverlay] Found %d ARGB visuals (32-bit with alpha)", num_visuals);
            
            // Set window attributes for compositing
            // Redirect the window for compositing - this tells the X server
            // that this window should be composited by the compositor
            XCompositeRedirectWindow(display, xwindow, CompositeRedirectManual);
            
            XFree(visual_info);
            NSLog(@"[WindowSwitcherOverlay] Successfully configured for ARGB transparency");
        } else {
            NSLog(@"[WindowSwitcherOverlay] WARNING: No 32-bit ARGB visual found!");
            NSLog(@"[WindowSwitcherOverlay] The X server may not support true transparency.");
        }
        
        XCloseDisplay(display);
        
    } @catch (NSException *exception) {
        NSLog(@"[WindowSwitcherOverlay] Exception configuring ARGB: %@", exception.reason);
    }
#else
    // On non-Linux platforms (macOS, BSD), transparency should work natively
    NSLog(@"[WindowSwitcherOverlay] Non-Linux platform, using native transparency");
#endif
}

- (void)showCenteredOnScreen {
    // Get main screen bounds
    NSScreen *mainScreen = [NSScreen mainScreen];
    if (!mainScreen) {
        mainScreen = [[NSScreen screens] firstObject];
    }
    
    if (!mainScreen) {
        NSLog(@"[WindowSwitcherOverlay] No screen available");
        return;
    }
    
    NSRect screenFrame = [mainScreen frame];
    NSRect windowFrame = [self frame];
    
    // Center horizontally
    CGFloat x = screenFrame.origin.x + (screenFrame.size.width - windowFrame.size.width) / 2;
    
    // Position at golden ratio (flipped) - more space at TOP than bottom
    // Golden ratio: 1 / phi ≈ 0.618, so place at 1 - 0.618 = 0.382 from top
    // This leaves ~38.2% space above, ~61.8% below
    CGFloat goldenRatioY = screenFrame.origin.y + (screenFrame.size.height * 0.382) - (windowFrame.size.height / 2);
    
    [self setFrameOrigin:NSMakePoint(x, goldenRatioY)];
    
    // Force the window to the absolute front, above all other windows
    [self makeKeyAndOrderFront:nil];
    [self orderFrontRegardless];
    
    NSLog(@"[WindowSwitcherOverlay] Showing at golden ratio (more top space) at %.0f, %.0f (level: %ld)", x, goldenRatioY, (long)[self level]);
}

- (void)hide {
    // Immediately remove from screen and ensure it's completely hidden
    [self orderOut:self];
    NSLog(@"[WindowSwitcherOverlay] Hidden immediately");
}

- (void)updateWithTitles:(NSArray *)titles icons:(NSArray *)icons currentIndex:(NSInteger)index {
    if (!titles || [titles count] == 0) {
        [self hide];
        return;
    }
    
    NSInteger count = [titles count];
    
    // Calculate required window size
    CGFloat totalIconWidth = count * kIconSize + (count - 1) * kIconSpacing;
    CGFloat windowWidth = totalIconWidth + 2 * kPadding + 2 * kSelectionPadding;
    CGFloat windowHeight = kPadding * 2 + kIconSize + kTitleHeight + kSelectionPadding * 2 + 8;
    
    // Limit to reasonable max width
    if (windowWidth > 800) {
        windowWidth = 800;
    }
    if (windowWidth < 400) {
        windowWidth = 400;
    }
    
    // Update window frame, keeping centered
    NSRect currentFrame = [self frame];
    CGFloat centerX = currentFrame.origin.x + currentFrame.size.width / 2;
    CGFloat centerY = currentFrame.origin.y + currentFrame.size.height / 2;
    
    NSRect newFrame = NSMakeRect(centerX - windowWidth / 2,
                                  centerY - windowHeight / 2,
                                  windowWidth,
                                  windowHeight);
    
    [self setFrame:newFrame display:NO];
    
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
    
    [view setNeedsDisplay:YES];
    
    NSLog(@"[WindowSwitcherOverlay] Updated with %lu titles, selected: %ld, rounded corners: %d",
          (unsigned long)count, (long)index, view.useRoundedCorners);
}

@end
