/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Where a sheet sits on its parent window and how far it has slid out.
// Pure geometry, so that the rules can be tested without an X server.
// Rects are root window pixels, y down.
@interface URSSheetLayout : NSObject

// The sheet hangs from the top edge of the parent's content (just below
// its titlebar), centred horizontally on it.  It is kept on the screen
// sideways; it never moves up over the parent's titlebar, since the
// titlebar is what it visibly hangs from.
+ (NSRect)frameForSheetSize:(NSSize)sheetSize
          parentContentRect:(NSRect)parentContent
                 screenRect:(NSRect)screen;

// The part of the sheet's height still tucked away under the titlebar at
// progress t of a slide: 1 is fully hidden, 0 fully out.  Coming out
// decelerates (it lands softly), going back accelerates.
+ (double)hiddenFractionAtProgress:(double)t appearing:(BOOL)appearing;

@end
