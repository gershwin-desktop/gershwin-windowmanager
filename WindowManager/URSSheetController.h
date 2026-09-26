/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSAttachmentController.h"

// Document-modal sheets (WM_WINDOW_ROLE "sheet"; the Eau theme marks every
// NSApp/NSWindow -beginSheet:...).  A sheet hangs from the bottom of its
// parent's titlebar, centred on it, stays directly above the parent's
// frame, takes the focus the parent gets while it is up, and slides down
// out from under the titlebar when shown and back up when dismissed.
@interface URSSheetController : URSAttachmentController
@end
