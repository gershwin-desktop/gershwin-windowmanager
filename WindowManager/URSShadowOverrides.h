/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// What the compositor has been told, or found out, about the drop shadow of
// individual top-level windows, by X window id.  X hands a destroyed
// window's id to later, unrelated windows, so whatever is recorded here is
// only valid until -forgetWindow:.
@interface URSShadowOverrides : NSObject

- (void)setSkipsShadow:(BOOL)skips forWindow:(uint32_t)windowId;
- (BOOL)skipsShadowForWindow:(uint32_t)windowId;

// Returns YES when the radius differs from the one recorded before, so a
// shadow built for the old corners has to be rebuilt.  0 means square.
- (BOOL)setCornerRadius:(double)radius forWindow:(uint32_t)windowId;
- (double)cornerRadiusForWindow:(uint32_t)windowId;

// The window is gone; its id may come back as a different window.
- (void)forgetWindow:(uint32_t)windowId;

@end
