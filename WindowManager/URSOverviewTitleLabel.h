/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// The title of the window under the pointer in the window overview, shown on
// the lower edge of its shrunk picture where the eye already is.
@interface URSOverviewTitleLabel : NSWindow

// slot is in root pixels, y down.
- (void)showTitle:(NSString *)title centeredOnBottomOfSlot:(NSRect)slot;
- (void)hide;

@end
