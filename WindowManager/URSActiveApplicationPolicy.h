/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef URS_ACTIVE_APPLICATION_POLICY_H
#define URS_ACTIVE_APPLICATION_POLICY_H

#import <Foundation/Foundation.h>

/* EWMH _NET_ACTIVE_WINDOW source indication of a pager, a task list or a
 * test driver: the user picked that window directly. */
#define URS_ACTIVATION_SOURCE_PAGER 2

/* Whether a window that becomes the active one makes its application the
 * frontmost one (_ACTIVE_APPLICATION).  The desktop also gets the focus
 * when the active window went away (its application's last window closed
 * or was minimized) and when a click into the Dock activates Workspace;
 * the frontmost application has to stay then, or a windowless application
 * loses its menu.  A pager asking for the desktop is the user choosing it,
 * like a click on it, so Workspace becomes frontmost and Menu.app shows its
 * menu. */
static inline BOOL
URSActiveWindowMakesItsApplicationFrontmost(BOOL isDesktop,
                                            BOOL requestedByPager)
{
  return !isDesktop || requestedByPager;
}

#endif
