//
//  UROSTitleBar.h
//  uroswm - Independent GSTheme Titlebar
//
//  A completely independent titlebar implementation that uses only GSTheme
//  and doesn't depend on XCBKit's titlebar system at all.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <GNUstepGUI/GSTheme.h>
#import <XCBKit/XCBWindow.h>
#import <XCBKit/XCBConnection.h>
#import <XCBKit/XCBFrame.h>

@interface UROSTitleBar : NSObject

// Core titlebar properties
@property (strong, nonatomic) XCBConnection *connection;
@property (assign, nonatomic) xcb_window_t windowId;
@property (assign, nonatomic) xcb_pixmap_t pixmap;
@property (strong, nonatomic) XCBVisual *visual;
@property (strong, nonatomic) NSString *title;
@property (assign, nonatomic) NSRect frame;
@property (assign, nonatomic) BOOL isActive;

// Initialization
- (instancetype)initWithConnection:(XCBConnection*)connection
                             frame:(NSRect)frame
                      parentWindow:(xcb_window_t)parentWindow;

// GSTheme rendering
- (void)renderWithGSTheme;
- (void)setTitle:(NSString*)title;
- (void)setActive:(BOOL)active;

// Window management
- (void)show;
- (void)hide;
- (void)updateFrame:(NSRect)newFrame;

// Event handling
- (void)handleButtonPress:(xcb_button_press_event_t*)event;
- (void)handleMotion:(xcb_motion_notify_event_t*)event;

// Cleanup
- (void)destroy;

@end