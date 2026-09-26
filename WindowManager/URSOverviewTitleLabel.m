/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSOverviewTitleLabel.h"
#import "URSCompositingManager.h"
#import <GNUstepGUI/GSDisplayServer.h>

static const CGFloat URSLabelHorizontalPadding = 12.0;
static const CGFloat URSLabelHeight = 24.0;
static const CGFloat URSLabelMaxWidth = 480.0;

@interface URSOverviewTitleLabelView : NSView
@property (copy, nonatomic) NSString *title;
@end

@implementation URSOverviewTitleLabelView

+ (NSDictionary *)titleAttributes {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByTruncatingMiddle];
    [style setAlignment:NSCenterTextAlignment];
    return @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:13.0],
              NSForegroundColorAttributeName: [NSColor whiteColor],
              NSParagraphStyleAttributeName: style };
}

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    // Cleared, not filled with clear colour: a fill composites over what the
    // backing held, and the compositor showed that through the corners.
    NSRectFillUsingOperation([self bounds], NSCompositeClear);

    CGFloat radius = NSHeight([self bounds]) * 0.5;
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:[self bounds]
                                                         xRadius:radius
                                                         yRadius:radius];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.7] set];
    [pill fill];

    NSDictionary *attributes = [[self class] titleAttributes];
    NSFont *font = [attributes objectForKey:NSFontAttributeName];
    CGFloat textHeight = [font ascender] - [font descender];
    NSRect textRect = NSInsetRect([self bounds], URSLabelHorizontalPadding, 0);
    textRect.origin.y = floor((NSHeight([self bounds]) - textHeight) * 0.5);
    textRect.size.height = textHeight;
    [self.title drawInRect:textRect withAttributes:attributes];
}

@end

@implementation URSOverviewTitleLabel

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 100, URSLabelHeight);
    self = [super initWithContentRect:frame
                            styleMask:NSBorderlessWindowMask
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        // Above the Dock and the menu bar, which the overview leaves in place.
        [self setLevel:NSPopUpMenuWindowLevel + 10];
        [self setOpaque:NO];
        [self setHasShadow:NO];
        [self setBackgroundColor:[NSColor clearColor]];
        [self setIgnoresMouseEvents:YES];
        [self setReleasedWhenClosed:NO];
        [self setContentView:[[URSOverviewTitleLabelView alloc] initWithFrame:frame]];
    }
    return self;
}

- (void)showTitle:(NSString *)title centeredOnBottomOfSlot:(NSRect)slot {
    URSOverviewTitleLabelView *view = (URSOverviewTitleLabelView *)[self contentView];
    view.title = title;

    // Window frames are in device pixels, the view draws in points.
    CGFloat scale = [self userSpaceScaleFactor];
    NSSize textSize = [title sizeWithAttributes:[URSOverviewTitleLabelView titleAttributes]];
    CGFloat width = MIN(ceil(textSize.width) + 2 * URSLabelHorizontalPadding, URSLabelMaxWidth);
    NSSize size = NSMakeSize(width * scale, URSLabelHeight * scale);

    // The label straddles the slot's bottom edge.  Root pixels count down
    // from the top, window frames up from the bottom.
    NSScreen *screen = [NSScreen mainScreen] ?: [[NSScreen screens] firstObject];
    CGFloat screenHeight = NSHeight([screen frame]);
    CGFloat labelTop = NSMaxY(slot) - size.height * 0.5;
    NSRect frame = NSMakeRect(round(NSMidX(slot) - size.width * 0.5),
                              round(screenHeight - labelTop - size.height),
                              size.width, size.height);
    [self setFrame:frame display:NO];
    // A rectangular drop shadow leaves unshadowed notches around the pill's
    // ends.  -windowNumber is the backend's tag, not the X window id.
    xcb_window_t xid = (xcb_window_t)(uintptr_t)[GSCurrentServer() windowDevice:[self windowNumber]];
    [[URSCompositingManager sharedManager] setShadowCornerRadius:size.height * 0.5
                                                       forWindow:xid];
    [view setFrame:NSMakeRect(0, 0, width, URSLabelHeight)];
    [view setNeedsDisplay:YES];
    [self orderFrontRegardless];
}

- (void)hide {
    [self orderOut:nil];
}

@end
