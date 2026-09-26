/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSWobblyWindowsController.h"
#import "URSWobblyModel.h"
#import "URSAttachedDeformation.h"
#import "URSCompositingManager.h"
#import "XCBFrame.h"

NSString * const URSWobblyWindowsKey = @"URSWobblyWindows";

@interface URSWobblyWindowsController ()
@property (strong, nonatomic) URSWobblyModel *model;
@property (assign, nonatomic) xcb_window_t draggedFrame;
@end

@implementation URSWobblyWindowsController

- (void)frameDragged:(XCBFrame *)frame pointer:(NSPoint)pointer {
    xcb_window_t frameId = [frame window];
    if (self.model && self.draggedFrame == frameId &&
        [self.compositingManager deformationForWindow:frameId] == self.model) {
        return;
    }
    // Read on every drag so the setting applies at once.  Off unless the user
    // asks for it: a moving window that bends is not to everyone's taste.
    if (![[NSUserDefaults standardUserDefaults] boolForKey:URSWobblyWindowsKey] ||
        ![self.compositingManager compositingActive]) {
        return;
    }
    XCBRect rect = [frame windowRect];
    URSWobblyModel *model =
        [[URSWobblyModel alloc] initWithWindowRect:NSMakeRect(rect.position.x, rect.position.y,
                                                              rect.size.width, rect.size.height)
                                         grabPoint:pointer
                                              time:[NSDate timeIntervalSinceReferenceDate]];
    [self.compositingManager setDeformation:model forWindow:frameId];
    if (self.attachedWindowsOfFrame && [self.compositingManager deformationForWindow:frameId] == model) {
        for (NSNumber *attached in self.attachedWindowsOfFrame(frameId)) {
            [self.compositingManager setDeformation:[[URSAttachedDeformation alloc] initWithParent:model]
                                          forWindow:[attached unsignedIntValue]];
        }
    }
    // The compositor declines while the window plays an animation; the drag
    // then stays flat rather than retrying on every motion.
    self.model = model;
    self.draggedFrame = frameId;
}

- (void)dragEnded {
    // The compositor keeps the model until it has wobbled back into shape.
    [self.model releaseGrab];
    self.model = nil;
    self.draggedFrame = XCB_NONE;
}

@end
