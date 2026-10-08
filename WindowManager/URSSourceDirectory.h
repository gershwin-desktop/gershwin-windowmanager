/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <sys/types.h>

// Where the source of an installed GNUstep application lives on a
// development system.  The application is found by its name alone (a
// GNUstep application's WM_CLASS class is its name, the APP_NAME of its
// GNUmakefile): the answer is the one directory under the sources root whose
// GNUmakefile or GNUmakefile.in declares that name.  When there is none, or
// more than one, the answer is nil rather than a guess.
@interface URSSourceDirectory : NSObject

// The directory that holds one checkout per repository.
+ (NSString *)sourceRoot;

// The directory that declares APP_NAME = name, searched in the repositories
// and their subdirectories (applications live in subdirectories of
// repositories that hold several).  Pure but for the index it keeps per
// root, so it can be tested with a sources root of its own.
+ (NSString *)sourceDirectoryForApplicationName:(NSString *)name
                                     sourceRoot:(NSString *)root;
+ (NSString *)sourceDirectoryForApplicationName:(NSString *)name;

// How long a name that is not in the index is trusted to be missing before
// the root is walked again, so that an application checked out while the
// window manager runs is found without a restart, yet a name that does not
// exist does not walk the tree each time the titlebar menu opens.  Seconds;
// 5 by default.
+ (NSTimeInterval)rescanInterval;
+ (void)setRescanInterval:(NSTimeInterval)seconds;

// How many times a root has been walked in this process.
+ (NSUInteger)walkCount;

@end
