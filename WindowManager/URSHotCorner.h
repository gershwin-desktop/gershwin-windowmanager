/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class XCBConnection;

// A screen corner that does something when the pointer is pushed into it.
@interface URSHotCorner : NSObject

// cornerName is "none", "top-left", "top-right", "bottom-left" or
// "bottom-right"; settingName is the defaults key it came from.  nil for
// "none", and for a wrong name after saying so.  The action is sent to the
// target with the hot corner as argument.
- (instancetype)initWithConnection:(XCBConnection *)connection
                        cornerName:(NSString *)cornerName
                           setting:(NSString *)settingName
                            target:(id)target
                            action:(SEL)action;

- (void)start;
- (void)stop;

@end
