/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which sheet hangs from which window.  Headless.
// Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSSheetRegistry.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("attaching")
    URSSheetRegistry *r = [[URSSheetRegistry new] autorelease];
    [r attachSheet: 0x500 toParent: 0x100];
    PASS([r parentOfSheet: 0x500] == 0x100, "a sheet knows its parent");
    PASS([r sheetOfParent: 0x100] == 0x500,
         "a parent knows its sheet (a click on it gives the sheet the focus)");
    PASS([r sheetOfParent: 0x200] == 0, "another window has no sheet");
    PASS([r parentOfSheet: 0x100] == 0, "a parent is not a sheet");
    PASS([[r sheets] isEqual: @[ @0x500 ]], "the sheets are listed");

    [r attachSheet: 0x600 toParent: 0x100];
    PASS([r sheetOfParent: 0x100] == 0x600,
         "a second sheet on the same window replaces the first");
    PASS([r parentOfSheet: 0x500] == 0, "the replaced sheet is no longer attached");
  END_SET("attaching")

  START_SET("detaching")
    URSSheetRegistry *r = [[URSSheetRegistry new] autorelease];
    [r attachSheet: 0x500 toParent: 0x100];
    [r detachSheet: 0x500];
    PASS([r sheetOfParent: 0x100] == 0 && [r parentOfSheet: 0x500] == 0,
         "a dismissed sheet leaves its parent");

    [r attachSheet: 0x500 toParent: 0x100];
    [r forgetWindow: 0x100];
    PASS([r parentOfSheet: 0x500] == 0 && [[r sheets] count] == 0,
         "a destroyed parent takes its sheet's attachment along");

    [r attachSheet: 0x500 toParent: 0x100];
    [r forgetWindow: 0x500];
    PASS([r sheetOfParent: 0x100] == 0, "a destroyed sheet leaves its parent");
  END_SET("detaching")

  START_SET("hidden with the parent")
    URSSheetRegistry *r = [[URSSheetRegistry new] autorelease];
    [r attachSheet: 0x500 toParent: 0x100];
    PASS(![r isSheetHiddenWithParent: 0x500], "a new sheet is shown");
    [r setSheet: 0x500 hiddenWithParent: YES];
    PASS([r isSheetHiddenWithParent: 0x500],
         "a sheet hidden along with its minimised parent is marked so");
    PASS([r sheetOfParent: 0x100] == 0x500, "and stays attached while hidden");
    [r setSheet: 0x500 hiddenWithParent: NO];
    PASS(![r isSheetHiddenWithParent: 0x500], "it is shown again with its parent");

    [r setSheet: 0x500 hiddenWithParent: YES];
    [r detachSheet: 0x500];
    [r attachSheet: 0x500 toParent: 0x100];
    PASS(![r isSheetHiddenWithParent: 0x500],
         "a sheet shown again later does not inherit the old hidden mark");

    [r setSheet: 0x700 hiddenWithParent: YES];
    PASS(![r isSheetHiddenWithParent: 0x700],
         "only an attached sheet can be hidden with a parent");
  END_SET("hidden with the parent")

  [arp release];
  return 0;
}
