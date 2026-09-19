/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class XCBFrame;
@class URSCompositingManager;

// Defaults key (BOOL, default NO): windows wobble like jelly while they are
// dragged and when they are let go.
extern NSString * const URSWobblyWindowsKey;

// Bends a window dragged by its titlebar over a URSWobblyModel.
@interface URSWobblyWindowsController : NSObject

@property (weak, nonatomic) URSCompositingManager *compositingManager;

// The drag moved the frame; the pointer is at pointer (root pixels).
- (void)frameDragged:(XCBFrame *)frame pointer:(NSPoint)pointer;
- (void)dragEnded;

@end
