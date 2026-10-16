/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Rules for finding an application's source directory by its name, from the
// APP_NAME declarations in the GNUmakefiles under a sources root.  Headless.
// Run with:  gnustep-tests test-sourcedir

#import <Foundation/Foundation.h>
#import "Testing.h"
#include "../WindowManager/URSSourceDirectory.m"

static NSFileManager *fm;

static void write_(NSString *path, NSString *contents)
{
  [fm createDirectoryAtPath: [path stringByDeletingLastPathComponent]
withIntermediateDirectories: YES attributes: nil error: NULL];
  [contents writeToFile: path atomically: NO encoding: NSUTF8StringEncoding error: NULL];
}

// A directory with a GNUmakefile that declares the given lines.
static NSString *app(NSString *root, NSString *dir, NSString *makefileName, NSString *lines)
{
  NSString *d = [root stringByAppendingPathComponent: dir];
  write_([d stringByAppendingPathComponent: makefileName],
         [@"include $(GNUSTEP_MAKEFILES)/common.make\n" stringByAppendingString: lines]);
  return d;
}

static NSString *look(NSString *name, NSString *root)
{
  return [URSSourceDirectory sourceDirectoryForApplicationName: name sourceRoot: root];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  fm = [NSFileManager defaultManager];
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [NSString stringWithFormat: @"sourcedir-%d", (int)getpid()]];
  [fm removeItemAtPath: tmp error: NULL];
  NSString *root = [tmp stringByAppendingPathComponent: @"Sources"];

  // Every lookup in this tree starts from a fresh walk unless a case says
  // otherwise.
  [URSSourceDirectory setRescanInterval: 0];

  NSString *rootApp = app(root, @"repo-root", @"GNUmakefile", @"APP_NAME = RootApp\n");
  NSString *subApp = app(root, @"suite/Sub", @"GNUmakefile", @"APP_NAME = SubApp\n");
  NSString *deepApp = app(root, @"suite/Group/Deep", @"GNUmakefile", @"APP_NAME = DeepApp\n");
  NSString *inApp = app(root, @"inonly", @"GNUmakefile.in", @"APP_NAME = InApp\n");
  NSString *multi = app(root, @"multi",  @"GNUmakefile",
    @"APP_NAME = One Two\nAPP_NAME += Three\nAPP_NAME = Four \\\n  Five\n");
  app(root, @"commented", @"GNUmakefile",
      @"#APP_NAME = Hidden\n  # APP_NAME = Hidden2\nAPP_NAME = Shown # APP_NAME = Trailing\n");
  NSString *colon = app(root, @"colon", @"GNUmakefile", @"APP_NAME:=Colon\nAPP_NAME +=  Plus\n");
  NSString *spaced = app(root, @"spaced", @"GNUmakefile", @"APP_NAME   :=   Spaced\n");
  app(root, @"lookalike", @"GNUmakefile",
      @"APP_NAME_FOO = NotAName\nXAPP_NAME = NotAName\nTOOL_NAME = NotAName\n");
  app(root, @"variable", @"GNUmakefile", @"APP_NAME = $(OTHER)\n");

  PASS_EQUAL(look(@"RootApp", root), rootApp, "an app at the repository root");
  PASS_EQUAL(look(@"SubApp", root), subApp, "an app in a subdirectory");
  PASS_EQUAL(look(@"DeepApp", root), deepApp, "an app two levels deep");
  PASS_EQUAL(look(@"InApp", root), inApp, "GNUmakefile.in alone is enough");
  for (NSString *n in [@"One Two Three Four Five" componentsSeparatedByString: @" "]) {
    PASS_EQUAL(look(n, root), multi, "several names in one makefile all resolve");
  }
  PASS_EQUAL(look(@"Shown", root), [root stringByAppendingPathComponent: @"commented"],
             "the live declaration next to commented ones is found");
  PASS(look(@"Hidden", root) == nil, "a commented-out name is ignored");
  PASS(look(@"Hidden2", root) == nil, "an indented comment is ignored");
  PASS(look(@"Trailing", root) == nil, "a trailing comment is ignored");
  PASS_EQUAL(look(@"Colon", root), colon, "APP_NAME:=X");
  PASS_EQUAL(look(@"Plus", root), colon, "APP_NAME +=  X");
  PASS_EQUAL(look(@"Spaced", root), spaced, "APP_NAME   :=   X");
  PASS(look(@"NotAName", root) == nil, "lookalike variables are not APP_NAME");
  PASS(look(@"$(OTHER)", root) == nil, "an unexpanded variable is not a name");

  /* Places that are never searched. */
  app(root, @"repo/.claude/worktrees/w/Copy", @"GNUmakefile", @"APP_NAME = Worktree\n");
  app(root, @"repo/obj", @"GNUmakefile", @"APP_NAME = InObj\n");
  app(root, @"repo/derived_src", @"GNUmakefile", @"APP_NAME = InDerived\n");
  app(root, @"repo/X.app/Resources", @"GNUmakefile", @"APP_NAME = InBundle\n");
  app(root, @"repo/Y.framework", @"GNUmakefile", @"APP_NAME = InFramework\n");
  app(root, @"repo/Z.bundle", @"GNUmakefile", @"APP_NAME = InPlugin\n");
  app(root, @"repo/node_modules/m", @"GNUmakefile", @"APP_NAME = InNode\n");
  app(root, @"repo/.hidden/h", @"GNUmakefile", @"APP_NAME = InHidden\n");
  app(root, @"repo/a/b/c/d/e", @"GNUmakefile", @"APP_NAME = Depth5\n");
  app(root, @"repo/a/b/c/d/e/f", @"GNUmakefile", @"APP_NAME = Depth6\n");
  for (NSString *n in [@"Worktree InObj InDerived InBundle InFramework InPlugin InNode InHidden Depth6"
                       componentsSeparatedByString: @" "]) {
    PASS(look(n, root) == nil, "skipped places are not searched");
  }
  PASS_EQUAL(look(@"Depth5", root),
             [root stringByAppendingPathComponent: @"repo/a/b/c/d/e"],
             "five levels below a repository are searched");

  /* Symlinks are not followed. */
  {
    NSString *target = app(tmp, @"outside/Linked", @"GNUmakefile", @"APP_NAME = Linked\n");
    [fm createSymbolicLinkAtPath: [root stringByAppendingPathComponent: @"link"]
             withDestinationPath: target error: NULL];
    PASS(look(@"Linked", root) == nil, "a symbolic link is not followed");
  }

  /* The same name in two directories is ambiguous, in one repository or two. */
  app(root, @"dupA", @"GNUmakefile", @"APP_NAME = Twice\n");
  app(root, @"dupB/inner", @"GNUmakefile", @"APP_NAME = Twice\n");
  PASS(look(@"Twice", root) == nil, "a name declared in two directories gives nil");
  app(root, @"same", @"GNUmakefile", @"APP_NAME = Once\nAPP_NAME += Once\n");
  app(root, @"same", @"GNUmakefile.in", @"APP_NAME = Once\n");
  PASS_EQUAL(look(@"Once", root), [root stringByAppendingPathComponent: @"same"],
             "one directory declaring a name repeatedly is not ambiguous");

  /* Names that cannot be application names. */
  PASS(look(nil, root) == nil, "nil name gives nil");
  PASS(look(@"", root) == nil, "empty name gives nil");
  PASS(look(@"a/b", root) == nil, "a name with a slash gives nil");
  PASS(look(@"../RootApp", root) == nil, "a name that is a path gives nil");
  PASS(look(@"RootApp", nil) == nil, "nil root gives nil");
  PASS(look(@"RootApp", @"/nonexistent-root-dir") == nil, "missing root gives nil");
  PASS(look(@"Missing", root) == nil, "an unknown name gives nil");

  /* The index: one walk serves many lookups, a miss rescans at most once per
   * interval. */
  {
    NSString *r2 = [tmp stringByAppendingPathComponent: @"Sources2"];
    NSString *first = app(r2, @"one", @"GNUmakefile", @"APP_NAME = First\n");
    [URSSourceDirectory setRescanInterval: 1000];
    NSUInteger w0 = [URSSourceDirectory walkCount];
    PASS_EQUAL(look(@"First", r2), first, "first lookup in a new root");
    PASS([URSSourceDirectory walkCount] == w0 + 1, "the first lookup walks once");

    app(r2, @"two", @"GNUmakefile", @"APP_NAME = Second\n");
    PASS(look(@"Second", r2) == nil, "a new app is not seen inside the rescan interval");
    PASS([URSSourceDirectory walkCount] == w0 + 1, "a miss inside the interval does not walk");

    [fm removeItemAtPath: r2 error: NULL];
    PASS_EQUAL(look(@"First", r2), first, "a hit comes from the index without a walk");
    PASS([URSSourceDirectory walkCount] == w0 + 1, "a hit does not walk");

    app(r2, @"two", @"GNUmakefile", @"APP_NAME = Second\n");
    [URSSourceDirectory setRescanInterval: 0];
    PASS_EQUAL(look(@"Second", r2), [r2 stringByAppendingPathComponent: @"two"],
               "a miss after the interval finds a new app");
    PASS([URSSourceDirectory walkCount] == w0 + 2, "that miss walked once");
    PASS(look(@"First", r2) == nil, "an app that is gone after a rescan is not found");

    NSString *r3 = [tmp stringByAppendingPathComponent: @"Sources3"];
    app(r3, @"x", @"GNUmakefile", @"APP_NAME = Other\n");
    PASS(look(@"First", r3) == nil, "each root has its own index");
  }

  PASS_EQUAL([URSSourceDirectory sourceRoot], @"/Developer/Library/Sources",
             "the sources root");

  [fm removeItemAtPath: tmp error: NULL];
  [arp release];
  return 0;
}
