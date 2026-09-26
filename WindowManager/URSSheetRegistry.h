/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Which sheet hangs from which window, and whether the window manager has
// hidden a sheet along with its parent.  Window ids are plain X ids; 0 is
// no window.  Foundation only, so the bookkeeping is tested without an X
// server.
@interface URSSheetRegistry : NSObject

// A window has at most one sheet: attaching another replaces the first.
- (void)attachSheet:(uint32_t)sheet toParent:(uint32_t)parent;
// The sheet is gone for good (dismissed or destroyed).
- (void)detachSheet:(uint32_t)sheet;
// A destroyed window takes its sheet along, or leaves its parent.
- (void)forgetWindow:(uint32_t)window;

- (uint32_t)parentOfSheet:(uint32_t)sheet;
- (uint32_t)sheetOfParent:(uint32_t)parent;
- (NSArray<NSNumber *> *)sheets;

// A sheet the window manager unmapped because its parent was minimised or
// unmapped stays attached; its unmap is not a dismissal, and its next map
// is not a new sheet appearing.
- (void)setSheet:(uint32_t)sheet hiddenWithParent:(BOOL)hidden;
- (BOOL)isSheetHiddenWithParent:(uint32_t)sheet;

@end
