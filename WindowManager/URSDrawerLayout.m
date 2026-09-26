/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSDrawerLayout.h"

@implementation URSDrawerLayout

+ (BOOL)getAttachment:(URSDrawerAttachment *)attachment
         ofDrawerRect:(NSRect)drawer
          parentFrame:(NSRect)parentFrame
        parentContent:(NSRect)parentContent
{
    return NO;
}

+ (NSRect)frameForAttachment:(URSDrawerAttachment)attachment
                 parentFrame:(NSRect)parentFrame
               parentContent:(NSRect)parentContent
{
    return NSZeroRect;
}

@end
