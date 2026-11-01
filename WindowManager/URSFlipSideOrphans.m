/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSFlipSideOrphans.h"

@interface URSFlipSideOrphan ()
- (instancetype)initWithWindow:(uint32_t)window
                   application:(NSString *)application
                     directory:(NSString *)directory
                         token:(id)token;
@end

@implementation URSFlipSideOrphan

- (instancetype)initWithWindow:(uint32_t)window
                   application:(NSString *)application
                     directory:(NSString *)directory
                         token:(id)token
{
    self = [super init];
    if (self) {
        _window = window;
        _application = [application copy];
        _directory = [directory copy];
        _token = token;
#if !__has_feature(objc_arc)
        [_token retain];
#endif
    }
    return self;
}

@end

@implementation URSFlipSideOrphans
{
    NSMutableArray<URSFlipSideOrphan *> *_orphans;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _orphans = [NSMutableArray new];
    }
    return self;
}

- (NSUInteger)count
{
    return [_orphans count];
}

- (NSArray<URSFlipSideOrphan *> *)orphans
{
    return [_orphans copy];
}

- (void)addOrphanWindow:(uint32_t)window
            application:(NSString *)application
              directory:(NSString *)directory
                  token:(id)token
{
    [self removeOrphanWithWindow:window];
    [_orphans addObject:[[URSFlipSideOrphan alloc] initWithWindow:window
                                                      application:application
                                                        directory:directory
                                                            token:token]];
}

- (void)removeOrphanWithWindow:(uint32_t)window
{
    URSFlipSideOrphan *orphan = [self orphanWithWindow:window];
    if (orphan != nil) {
        [_orphans removeObjectIdenticalTo:orphan];
    }
}

- (URSFlipSideOrphan *)orphanWithWindow:(uint32_t)window
{
    for (URSFlipSideOrphan *orphan in _orphans) {
        if ([orphan window] == window) {
            return orphan;
        }
    }
    return nil;
}

- (URSFlipSideOrphan *)orphanWithToken:(id)token
{
    if (token == nil) {
        return nil;
    }
    for (URSFlipSideOrphan *orphan in _orphans) {
        if ([[orphan token] isEqual:token]) {
            return orphan;
        }
    }
    return nil;
}

- (BOOL)hasOrphansOfApplication:(NSString *)application
{
    if (application == nil) {
        return NO;
    }
    for (URSFlipSideOrphan *orphan in _orphans) {
        if ([[orphan application] isEqualToString:application]) {
            return YES;
        }
    }
    return NO;
}

- (URSFlipSideOrphan *)oldestOrphanOfApplication:(NSString *)application
                                       directory:(NSString *)directory
{
    if (application == nil || directory == nil) {
        return nil;
    }
    for (URSFlipSideOrphan *orphan in _orphans) {
        if ([[orphan application] isEqualToString:application] &&
            [[orphan directory] isEqualToString:directory]) {
            return orphan;
        }
    }
    return nil;
}

@end
