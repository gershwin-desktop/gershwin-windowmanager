/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSCommandLine.h"
#include <string.h>

@implementation URSCommandLine

+ (instancetype)commandLineWithArguments:(const char * const *)argv count:(int)argc
{
    URSCommandLine *line = [[self alloc] init];
    line->_compositingEnabled = YES;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-dc") == 0 || strcmp(argv[i], "--disable-compositing") == 0) {
            line->_compositingEnabled = NO;
        } else if (strcmp(argv[i], "--replace") == 0) {
            line->_replaceRequested = YES;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            line->_helpRequested = YES;
        }
    }
    return line;
}

@end
