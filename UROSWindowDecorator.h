//
//  UROSWindowDecorator.h
//  uroswm - Independent Window Decoration
//
//  Completely independent window decoration system that bypasses XCBKit
//  and uses only GSTheme for authentic AppKit window appearance.
//

#import <Foundation/Foundation.h>
#import <XCBKit/XCBConnection.h>
#import "UROSTitleBar.h"

@interface UROSWindowDecorator : NSObject

// Window decoration management
+ (void)decorateWindow:(xcb_window_t)clientWindow
        withConnection:(XCBConnection*)connection
                 title:(NSString*)title;

+ (void)updateWindowTitle:(xcb_window_t)clientWindow title:(NSString*)title;
+ (void)setWindowActive:(xcb_window_t)clientWindow active:(BOOL)active;
+ (void)undecoateWindow:(xcb_window_t)clientWindow;

// Get titlebar for a client window
+ (UROSTitleBar*)titlebarForWindow:(xcb_window_t)clientWindow;

// Event handling (returns YES if event was handled by our titlebar)
+ (BOOL)handleExposeEvent:(xcb_expose_event_t*)event;
+ (BOOL)handleButtonEvent:(xcb_button_press_event_t*)event;

@end