/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlowLayout.h"

// Where the Alt-Tab deck shows each window: the windows stand one behind the
// other, head on, the chosen one in front and large, each further back
// smaller and higher, so that only the top strip of the ones behind shows.
// Moving the choice sends the front window down and past the viewer, off the
// bottom of the screen, while every other window comes one place forward.
// Like the flow it is only geometry, the rectangles the compositor paints
// the windows into, and it takes the flow's API so that the same controller
// can show either; the row position here is the place in the deck.
// The deck goes round without end: a window that has left at the bottom
// comes back at the far end of the deck, so the position is not limited to
// the item indexes; going on past the last one brings the first one to the
// front again.  Rects are in root pixels, y down.
@interface URSDeckLayout : URSFlowLayout
@end
