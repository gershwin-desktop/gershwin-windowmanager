/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWindowFlowController.h"
#import "URSFlowLayout.h"
#import "URSOverviewTitleLabel.h"
#import "URSPresentationTransition.h"
#import "URSScreenWindow.h"
#import "URSCompositingManager.h"
#import "URSWindowSwitcher.h"
#import "XCBConnection.h"
#import "XCBScreen.h"
#import "XCBFrame.h"

// As long as the window overview takes, so both modes feel alike.
static const NSTimeInterval URSFlowTransitionDuration = 0.3;
static const NSTimeInterval URSFlowSlideDuration = 0.25;
static const double URSFlowBackdropDimming = 0.6;

@interface URSFlowItem : URSScreenWindow
@property (assign, nonatomic) NSUInteger index;
@end

@implementation URSFlowItem
@end

@interface URSWindowFlowController ()
@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) URSWindowSwitcher *windowSwitcher;
// Items in row order while the flow is shown or closing, else nil.
@property (strong, nonatomic) NSArray *items;
@property (strong, nonatomic) NSDictionary *itemsByFrame;
@property (strong, nonatomic) NSSet *fadedWindows;
@property (assign, nonatomic) NSUInteger selectedIndex;
@property (assign, nonatomic) BOOL shown;
// From the windows' places (0) to the row (1).
@property (strong, nonatomic) URSPresentationTransition *transition;
// The row position: the index of the item in the middle, between two
// indexes while the row slides.
@property (strong, nonatomic) URSPresentationTransition *slide;
@property (strong, nonatomic) URSOverviewTitleLabel *titleLabel;
@end

@implementation URSWindowFlowController

- (instancetype)initWithConnection:(XCBConnection *)connection
                    windowSwitcher:(URSWindowSwitcher *)windowSwitcher {
    self = [super init];
    if (self) {
        _connection = connection;
        _windowSwitcher = windowSwitcher;
        _transition = [[URSPresentationTransition alloc] initWithDuration:URSFlowTransitionDuration
                                                                   target:self
                                                             closedAction:@selector(transitionClosed:)];
        // Reaching position 0 is not an end of anything.
        _slide = [[URSPresentationTransition alloc] initWithDuration:URSFlowSlideDuration
                                                              target:nil
                                                        closedAction:NULL];
    }
    return self;
}

- (void)setCompositingManager:(URSCompositingManager *)compositingManager {
    _compositingManager = compositingManager;
    self.transition.compositingManager = compositingManager;
    self.slide.compositingManager = compositingManager;
}

- (NSRect)screenArea {
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    return NSMakeRect(0, 0, [screen width], [screen height]);
}

#pragma mark - Showing

- (BOOL)isShown {
    return self.shown;
}

- (XCBFrame *)showFrames:(NSArray *)frames selectedIndex:(NSUInteger)index {
    if (![self.compositingManager compositingActive]) {
        return nil;
    }
    NSMutableDictionary *onScreen = [NSMutableDictionary dictionary];
    for (URSFlowItem *item in [URSFlowItem windowsOnScreenOfConnection:self.connection
                                                        windowSwitcher:self.windowSwitcher]) {
        onScreen[@([item.frame window])] = item;
    }
    // Minimized windows have no picture to fly; the row holds the others in
    // the switcher's order, and the choice starts at the first of them from
    // the switcher's choice on.
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger selected = NSNotFound;
    for (NSUInteger i = 0; i < [frames count]; i++) {
        XCBFrame *frame = [frames objectAtIndex:i];
        URSFlowItem *item = onScreen[@([frame window])];
        if (!item) {
            continue;
        }
        item.index = [items count];
        if (selected == NSNotFound && i >= index) {
            selected = item.index;
        }
        [items addObject:item];
    }
    if ([items count] < 2) {
        return nil;
    }
    if (selected == NSNotFound) {
        selected = 0;
    }

    NSMutableDictionary *byFrame = [NSMutableDictionary dictionary];
    for (URSFlowItem *item in items) {
        byFrame[@([item.frame window])] = item;
    }
    BOOL wasClosing = self.items != nil;
    self.items = items;
    self.itemsByFrame = byFrame;
    NSMutableSet *faded = [[URSScreenWindow dockWindowsOfConnection:self.connection] mutableCopy];
    [faded unionSet:[URSScreenWindow utilityPanelsOfConnection:self.connection]];
    self.fadedWindows = faded;
    self.selectedIndex = selected;
    self.shown = YES;
    [self.slide jumpTo:(double)selected];
    if (!wasClosing) {
        [self.compositingManager setPresentation:self];
    }
    [self.transition runTo:1.0];
    [self showTitle];
    URSFlowItem *chosen = [items objectAtIndex:selected];
    return chosen.frame;
}

- (XCBFrame *)moveSelectionBy:(NSInteger)step {
    if (!self.shown) {
        return nil;
    }
    self.selectedIndex = [URSFlowLayout indexFrom:self.selectedIndex step:step count:[self.items count]];
    [self.slide runTo:(double)self.selectedIndex];
    [self showTitle];
    URSFlowItem *chosen = [self.items objectAtIndex:self.selectedIndex];
    return chosen.frame;
}

- (void)close {
    if (!self.shown) {
        return;
    }
    self.shown = NO;
    [self.titleLabel hide];
    [self.transition runTo:0.0];
}

- (void)transitionClosed:(URSPresentationTransition *)transition {
    [self forget];
    [self.compositingManager removePresentation:self];
}

- (void)forget {
    self.items = nil;
    self.itemsByFrame = nil;
    self.fadedWindows = nil;
    self.shown = NO;
}

// The title goes under the middle of the row, where the chosen window
// ends up.
- (void)showTitle {
    URSFlowItem *item = [self.items objectAtIndex:self.selectedIndex];
    NSRect slot = [URSFlowLayout slotForWindowSize:item.windowRect.size
                                           atIndex:item.index
                                          position:(double)item.index
                                            inArea:[self screenArea]];
    if (!self.titleLabel) {
        self.titleLabel = [[URSOverviewTitleLabel alloc] init];
    }
    [self.titleLabel showTitle:item.title centeredOnBottomOfSlot:slot];
}

#pragma mark - URSWindowPresentation

- (BOOL)getPaintRect:(NSRect *)paintRect
           forWindow:(xcb_window_t)windowId
          windowRect:(NSRect)windowRect {
    URSFlowItem *item = self.itemsByFrame[@(windowId)];
    if (!item) {
        return NO;
    }
    NSRect slot = [URSFlowLayout slotForWindowSize:item.windowRect.size
                                           atIndex:item.index
                                          position:[self.slide progress]
                                            inArea:[self screenArea]];
    *paintRect = URSInterpolateRect(windowRect, slot, [self.transition progress]);
    return YES;
}

- (NSArray *)paintOrderForWindows:(NSArray *)windowIds {
    // Near their places the windows keep their stacking; the row's order
    // takes over half way, while they are apart and moving, so no window
    // jumps in front of another at rest.
    if ([self.transition progress] < 0.5) {
        return windowIds;
    }
    NSSet *painted = [NSSet setWithArray:windowIds];
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:[self.items count]];
    for (NSNumber *index in [URSFlowLayout paintOrderForCount:[self.items count]
                                                     position:[self.slide progress]]) {
        URSFlowItem *item = [self.items objectAtIndex:[index unsignedIntegerValue]];
        NSNumber *frameId = @([item.frame window]);
        // A window closed or unmapped meanwhile is not painted at all.
        if ([painted containsObject:frameId]) {
            [order addObject:frameId];
        }
    }
    return [URSFlowLayout stack:windowIds reorderedAs:order];
}

- (double)opacityForWindow:(xcb_window_t)windowId {
    // The Menu bar, the Dock and palettes give the row the whole screen.
    return [self.fadedWindows containsObject:@(windowId)] ? 1.0 - [self.transition progress] : 1.0;
}

- (double)backdropDimming {
    return URSFlowBackdropDimming * [self.transition progress];
}

- (BOOL)isAnimating {
    return [self.transition isAnimating] || [self.slide isAnimating];
}

- (void)presentationWasReplaced {
    [self.transition cancel];
    [self.slide cancel];
    [self.titleLabel hide];
    [self forget];
}

@end
