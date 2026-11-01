/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef URS_INPUT_FOCUS_POLICY_H
#define URS_INPUT_FOCUS_POLICY_H

#import <Foundation/Foundation.h>

/* ICCCM 4.1.7: a window that sets WM_HINTS input to False and does not
 * take part in WM_TAKE_FOCUS uses the "No Input" model, and the window
 * manager must never give it the focus.  Menu.app's bar is such a window:
 * focusing it on a click took the focus away from the frontmost
 * application, which then deactivated and hid its palettes.
 * inputHint is the WM_HINTS input value, YES when the hint is absent. */
static inline BOOL
URSWindowAcceptsInputFocus(BOOL inputHint, BOOL takesFocusProtocol)
{
  return inputHint || takesFocusProtocol;
}

#endif
