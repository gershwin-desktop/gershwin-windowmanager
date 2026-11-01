/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// A flip side whose window went: its terminal lives on as an ordinary
// window until a window of the same application comes back for it.
@interface URSFlipSideOrphan : NSObject

// The WM_CLASS class of the window it was the back of, and the source
// directory its terminal runs in; nil when unknown, and then it never goes
// back onto a window.
@property (readonly, copy, nonatomic) NSString *application;
@property (readonly, copy, nonatomic) NSString *directory;
@property (readonly, nonatomic) uint32_t window;
// What ends its terminal (the NSTask, or the process id of one started by
// an earlier window manager); nil when nothing is known.
@property (readonly, strong, nonatomic) id token;

@end

// The orphaned flip sides, oldest first.
@interface URSFlipSideOrphans : NSObject

@property (readonly, nonatomic) NSUInteger count;
// Oldest first.
@property (readonly, nonatomic) NSArray<URSFlipSideOrphan *> *orphans;

// The same window added again counts as new.
- (void)addOrphanWindow:(uint32_t)window
            application:(NSString *)application
              directory:(NSString *)directory
                  token:(id)token;
- (void)removeOrphanWithWindow:(uint32_t)window;
- (URSFlipSideOrphan *)orphanWithWindow:(uint32_t)window;
// By isEqual:, so a task or a process id.
- (URSFlipSideOrphan *)orphanWithToken:(id)token;

// Lets a new window skip looking up its source directory, which reads the
// file system, when no orphan could be its own.
- (BOOL)hasOrphansOfApplication:(NSString *)application;
// The one that has waited longest for a window of this application in this
// directory, or nil.
- (URSFlipSideOrphan *)oldestOrphanOfApplication:(NSString *)application
                                       directory:(NSString *)directory;

@end
