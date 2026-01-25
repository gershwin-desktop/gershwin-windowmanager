//
//  XCBAtomService.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 07/01/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import "XCBAtomService.h"

@implementation XCBAtomService

@synthesize connection;
@synthesize cachedAtoms;

- (id) initWithConnection:(XCBConnection*)aConnection
{
    self = [super init];
    
    if (self == nil)
    {
        NSLog(@"Unable to init...");
        return nil;
    }
    
    connection = aConnection;
    cachedAtoms = [[NSMutableDictionary alloc] init];
    
    return self;
}

+ (id) sharedInstanceWithConnection:(XCBConnection *)aConnection
{
    static XCBAtomService *sharedInstance = nil;
    
    //Not thread safe
    
    if (sharedInstance == nil)
    {
        sharedInstance = [[self alloc] initWithConnection:aConnection];
    }
    
    return sharedInstance;
}

- (xcb_atom_t) cacheAtom:(NSString*) atomName
{
    NSNumber *atomValue = [cachedAtoms objectForKey:atomName];
    
    if (atomValue != nil)
    {
        xcb_atom_t value = [atomValue unsignedIntValue];
        atomValue = nil;
        return value;
    }
    
    const char *str = [atomName UTF8String];
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom([connection connection], NO, strlen(str), str);
    xcb_intern_atom_reply_t* reply = xcb_intern_atom_reply([connection connection], cookie, NULL);
    xcb_atom_t atom = reply->atom;
    atomValue = [NSNumber numberWithUnsignedInt:atom];
    [cachedAtoms setObject:atomValue forKey:atomName];
    
    free(reply);
    atomValue = nil;
    
    return atom;
}

- (void) cacheAtoms:(NSArray *)atoms
{
    NSUInteger size = [atoms count];
    
    for (NSUInteger i = 0; i < size; i++)
    {
        NSString *atomName = [atoms objectAtIndex:i];
        [self cacheAtom:atomName];
        atomName = nil;
    }
    
}

- (xcb_atom_t) atomFromCachedAtomsWithKey:(NSString *)atomName
{
    return [[cachedAtoms objectForKey:atomName] unsignedIntValue];
}

- (NSNumber*) atomNumberFromCachedAtomsWithKey:(NSString *)atomName
{
    return [cachedAtoms objectForKey:atomName];
}

- (NSString*) atomNameFromAtom:(xcb_atom_t)anAtom
{
    if (anAtom == XCB_ATOM_NONE) {
        return @"NONE";
    }

    xcb_get_atom_name_cookie_t cookie = xcb_get_atom_name([connection connection], anAtom);
    xcb_get_atom_name_reply_t *reply = xcb_get_atom_name_reply([connection connection], cookie, NULL);

    if (!reply) {
        NSLog(@"[XCBAtomService] Failed to get atom name for atom id: %u", anAtom);
        return nil;
    }

    int length = xcb_get_atom_name_name_length(reply);

    if (length == 0) {
        free(reply);
        return @"No atom name!";
    }

    char* n = xcb_get_atom_name_name(reply);
    // Create a properly null-terminated copy
    char *nameCopy = malloc(length + 1);
    memcpy(nameCopy, n, length);
    nameCopy[length] = '\0';

    NSString *name = [NSString stringWithUTF8String:nameCopy];
    free(nameCopy);
    free(reply);
    return name;
}

- (void) dealloc
{
    connection = nil;
    cachedAtoms = nil;
}

@end
