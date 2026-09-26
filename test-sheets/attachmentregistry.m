/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Which sheet or drawer hangs from which window.  Headless.
// Run with:  gnustep-tests test-sheets

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSAttachmentRegistry.m"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("attaching")
    URSAttachmentRegistry *r = [[URSAttachmentRegistry new] autorelease];
    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    PASS([r parentOfWindow: 0x500] == 0x100, "a sheet knows its parent");
    PASS([r windowOfParent: 0x100] == 0x500,
         "a parent knows its sheet (a click on it gives the sheet the focus)");
    PASS([r windowOfParent: 0x200] == 0, "another window has no sheet");
    PASS([r parentOfWindow: 0x100] == 0, "a parent is not a sheet");
    PASS([[r windows] isEqual: @[ @0x500 ]], "the sheets are listed");

    [r attachWindow: 0x600 toParent: 0x100 exclusive: YES];
    PASS([r windowOfParent: 0x100] == 0x600,
         "a second sheet on the same window replaces the first");
    PASS([r parentOfWindow: 0x500] == 0, "the replaced sheet is no longer attached");
  END_SET("attaching")

  START_SET("detaching")
    URSAttachmentRegistry *r = [[URSAttachmentRegistry new] autorelease];
    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    [r detachWindow: 0x500];
    PASS([r windowOfParent: 0x100] == 0 && [r parentOfWindow: 0x500] == 0,
         "a dismissed sheet leaves its parent");

    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    [r forgetWindow: 0x100];
    PASS([r parentOfWindow: 0x500] == 0 && [[r windows] count] == 0,
         "a destroyed parent takes its sheet's attachment along");

    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    [r forgetWindow: 0x500];
    PASS([r windowOfParent: 0x100] == 0, "a destroyed sheet leaves its parent");
  END_SET("detaching")

  START_SET("several per parent")
    URSAttachmentRegistry *r = [[URSAttachmentRegistry new] autorelease];
    [r attachWindow: 0x500 toParent: 0x100 exclusive: NO];
    [r attachWindow: 0x600 toParent: 0x100 exclusive: NO];
    PASS([[r windowsOfParent: 0x100] count] == 2,
         "drawers on two edges both hang from the parent");
    [r forgetWindow: 0x100];
    PASS([[r windows] count] == 0, "a destroyed parent takes all of them along");
  END_SET("several per parent")

  START_SET("hidden with the parent")
    URSAttachmentRegistry *r = [[URSAttachmentRegistry new] autorelease];
    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    PASS(![r isWindowHiddenWithParent: 0x500], "a new sheet is shown");
    [r setWindow: 0x500 hiddenWithParent: YES];
    PASS([r isWindowHiddenWithParent: 0x500],
         "a sheet hidden along with its minimised parent is marked so");
    PASS([r windowOfParent: 0x100] == 0x500, "and stays attached while hidden");
    [r setWindow: 0x500 hiddenWithParent: NO];
    PASS(![r isWindowHiddenWithParent: 0x500], "it is shown again with its parent");

    [r setWindow: 0x500 hiddenWithParent: YES];
    [r detachWindow: 0x500];
    [r attachWindow: 0x500 toParent: 0x100 exclusive: YES];
    PASS(![r isWindowHiddenWithParent: 0x500],
         "a sheet shown again later does not inherit the old hidden mark");

    [r setWindow: 0x700 hiddenWithParent: YES];
    PASS(![r isWindowHiddenWithParent: 0x700],
         "only an attached sheet can be hidden with a parent");
  END_SET("hidden with the parent")

  [arp release];
  return 0;
}
