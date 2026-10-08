/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentController.h"

// Drawers (WM_WINDOW_ROLE "drawer"; the Eau theme marks every NSDrawer's
// window).  A drawer hangs from the edge of its parent that its client put
// it next to, keeping the offsets and the thickness the client gave it; it
// stays directly below the parent's frame, so the parent's shadow falls on
// it, moves and resizes with the parent, bends with it when it wobbles,
// and slides out from under the parent's edge when opened and back when
// closed.  Unlike a sheet it leaves the parent its focus.
@interface URSDrawerController : URSAttachmentController
@end
