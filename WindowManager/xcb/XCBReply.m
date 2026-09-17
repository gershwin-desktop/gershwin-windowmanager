//
//  XCBReply.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 26/07/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import "XCBReply.h"

@implementation XCBReply

@synthesize isError;
@synthesize message;
@synthesize reply;
@synthesize error;

- (id) initWithError:(xcb_generic_error_t *)anError
{
    self = [super init];
    
    if (self == nil)
    {
        NSLog(@"Unable to init...");
        return nil;
    }
    
    isError = YES;
    
    message = anError->error_code;
    error = anError;
    
    return self;
}

- (id) initWithReply:(void *)aReply
{
    self = [super init];
    
    if (self == nil)
    {
        NSLog(@"Unable to init...");
        return nil;
    }
    
    reply = aReply;
    
    return self;
}

- (void) description
{
    // Intentionally silent.  BadWindow/BadDrawable errors are expected and
    // common while a window is being destroyed; logging them only produced
    // noise (e.g. "Error: BadWindow") on every window close.
}

- (void) dealloc
{
    if (reply)
        free(reply);
    
    reply = NULL;
    
    
    if (error)
        free(error);
    
    error = NULL;
    
}

@end
