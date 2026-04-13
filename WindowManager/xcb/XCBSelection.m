//
//  XCBSelection.m
//  XCBKit
//
//  Created by Alessandro Sangiuliano on 26/01/20.
//  Copyright (c) 2020 alex. All rights reserved.
//

#import "XCBSelection.h"
#import "EWMHService.h"

@implementation XCBSelection

@synthesize connection;

- (id) initWithConnection:(XCBConnection *)aConnection andAtom:(xcb_atom_t)anAtom
{
    self = [super init];
    
    if (self == nil)
    {
        NSLog(@"Unable to allocate");
        return nil;
    }
    
    connection = aConnection;
    atom = anAtom;
    
    return self;
}


-(XCBWindow*) requestOwner
{
    xcb_get_selection_owner_cookie_t request = xcb_get_selection_owner([connection connection], atom);
    xcb_get_selection_owner_reply_t *reply = xcb_get_selection_owner_reply([connection connection],
                                                                           request,
                                                                           NULL);
    
    [connection setIsWindowsMapUpdated:NO];
    
    if (NULL == reply)
	{
        NSLog(@"Unable to get the owner");
        return nil;
	}
    
    XCBWindow *owner = reply->owner != XCB_NONE ? [[XCBWindow alloc] initWithXCBWindow:reply->owner andConnection:connection] : nil;
    [connection registerWindow:owner];
    [owner onScreen];
    
    free(reply);
    return owner;
}

- (void) setOwner:(XCBWindow *)aWindow
{
    xcb_timestamp_t currentTime = [connection currentTime];

    xcb_set_selection_owner([connection connection],
                            [aWindow window],
                            atom,
                            currentTime);

    xcb_flush([connection connection]);

    NSLog(@"[XCBSelection] Set selection owner for atom %u to window %u", atom, [aWindow window]);
}

- (BOOL)aquireWithWindow:(XCBWindow *)aWindow replace:(BOOL)replace
{
    XCBWindow *currentOwner = [self requestOwner];
    BOOL aquired = NO;

    if (currentOwner != nil)
    {
        if (!replace)
            return NO;

        xcb_window_t oldOwnerWindow = [currentOwner window];
        NSLog(@"[XCBSelection] Current owner is window %u, attempting replacement", oldOwnerWindow);

        // ICCCM §2.8: Set ourselves as the new owner
        // The old owner will receive a SelectionClear event and should clean itself up
        [self setOwner:aWindow];
        
        NSLog(@"[XCBSelection] Successfully replaced old owner window %u", oldOwnerWindow);
        NSLog(@"[XCBSelection] Old WM should receive SelectionClear and terminate gracefully");

        aquired = YES;
    }
    else
    {
        NSLog(@"[XCBSelection] No current owner, acquiring selection");
        [self setOwner:aWindow];
        aquired = YES;
    }

    // ICCCM §2.8: Send MANAGER ClientMessage to announce new manager
    XCBScreen *screen = [aWindow onScreen];
    EWMHService *ewmhService = [EWMHService sharedInstanceWithConnection:connection];
    
    xcb_client_message_event_t ev;
    ev.response_type = XCB_CLIENT_MESSAGE;
    ev.window = [screen screen]->root;
    ev.format = 32;
    ev.type = [[[[ewmhService atomService] cachedAtoms] objectForKey:[ewmhService MANAGER]] unsignedIntValue];
    ev.data.data32[0] = [connection currentTime];
    ev.data.data32[1] = atom;
    ev.data.data32[2] = [aWindow window];
    ev.data.data32[3] = ev.data.data32[4] = 0;
    
    // ICCCM §2.8: Send to root with SubstructureNotifyMask | SubstructureRedirectMask
    uint32_t eventMask = XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT;
    xcb_send_event([connection connection], false, [screen screen]->root, eventMask, (char*)&ev);
    xcb_flush([connection connection]);
    
    NSLog(@"[XCBSelection] Sent MANAGER ClientMessage for atom %u with timestamp %u", atom, [connection currentTime]);
    
    screen = nil;
    ewmhService = nil;
    currentOwner = nil;
    
    return aquired;
}



/************
 * ACCESSORS *
 ************/

- (void) setAtom:(xcb_atom_t)anAtom
{
    atom = anAtom;
}

- (xcb_atom_t) getAtom
{
    return atom;
}

- (void) dealloc
{
    connection = nil;
}
@end
