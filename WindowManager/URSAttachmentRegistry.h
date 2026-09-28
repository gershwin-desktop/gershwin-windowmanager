/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Which windows hang from which window (sheets, drawers), and whether the
// window manager has hidden one along with its parent.  Window ids are
// plain X ids; 0 is no window.  Foundation only, so the bookkeeping is
// tested without an X server.
@interface URSAttachmentRegistry : NSObject

// exclusive: the parent can have only this one attached window (a sheet),
// so attaching it detaches any other; otherwise several can hang from one
// parent (drawers on different edges).
- (void)attachWindow:(uint32_t)window toParent:(uint32_t)parent exclusive:(BOOL)exclusive;
// The window is gone for good (dismissed or destroyed).
- (void)detachWindow:(uint32_t)window;
// A destroyed window takes its attached windows along, or leaves its parent.
- (void)forgetWindow:(uint32_t)window;

- (uint32_t)parentOfWindow:(uint32_t)window;
// The attached windows of a parent, in no particular order.
- (NSArray<NSNumber *> *)windowsOfParent:(uint32_t)parent;
// One of them (the only one for an exclusive attachment), or 0.
- (uint32_t)windowOfParent:(uint32_t)parent;
- (NSArray<NSNumber *> *)windows;

// A window the window manager unmapped because its parent was minimised
// or unmapped stays attached; its unmap is not a dismissal, and its next
// map is not a new window appearing.
- (void)setWindow:(uint32_t)window hiddenWithParent:(BOOL)hidden;
- (BOOL)isWindowHiddenWithParent:(uint32_t)window;

@end
