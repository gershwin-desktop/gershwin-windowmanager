//
// XCBCursor.h
// XCBKit
//
// Created by slex on 15/12/20.
//

#import <Foundation/Foundation.h>
#import "XCBScreen.h"
#import <xcb/xcb_cursor.h>
#import "EMousePosition.h"

@class XCBConnection;

@interface XCBCursor : NSObject
{
}

@property (strong, nonatomic) XCBConnection *connection;
@property (strong, nonatomic) XCBScreen *screen;
@property (nonatomic) xcb_cursor_context_t *context;
@property (strong, nonatomic) NSString *cursorPath;
@property (nonatomic) xcb_cursor_t cursor;
@property (strong, nonatomic) NSMutableDictionary *cursors;
@property (strong, nonatomic) NSString *leftPointerName;
@property (strong, nonatomic) NSString *resizeBottomCursorName;
@property (strong, nonatomic) NSString *resizeRightCursorName;
@property (strong, nonatomic) NSString *resizeLeftCursorName;
@property (strong, nonatomic) NSString *resizeTopCursorName;
@property (strong, nonatomic) NSString *resizeBottomRightCornerCursorName;
@property (strong, nonatomic) NSString *resizeTopLeftCornerCursorName;
@property (strong, nonatomic) NSString *resizeTopRightCornerCursorName;
@property (strong, nonatomic) NSString *resizeBottomLeftCornerCursorName;
@property (assign, nonatomic) BOOL leftPointerSelected;
@property (assign, nonatomic) BOOL resizeBottomSelected;
@property (assign, nonatomic) BOOL resizeRightSelected;
@property (assign, nonatomic) BOOL resizeLeftSelected;
@property (assign, nonatomic) BOOL resizeBottomRightCornerSelected;
@property (assign, nonatomic) BOOL resizeTopLeftCornerSelected;
@property (assign, nonatomic) BOOL resizeTopRightCornerSelected;
@property (assign, nonatomic) BOOL resizeBottomLeftCornerSelected;
@property (assign, nonatomic) BOOL resizeTopSelected;
// The pixel size the cursors are loaded at, 0 for the theme's default size
// (libxcb-cursor, as always); see URSCursorSize.h.
@property (assign, nonatomic) uint32_t pixelSize;

- (instancetype)initWithConnection:(XCBConnection *)aConnection screen:(XCBScreen*)aScreen;
- (instancetype)initWithConnection:(XCBConnection *)aConnection screen:(XCBScreen*)aScreen
                         pixelSize:(uint32_t)aPixelSize;
// Load every cursor again at another size; a window showing one of them
// must be given the new id (cursorIdForPosition:, selectLeftPointerCursor).
- (void) changePixelSize:(uint32_t)aPixelSize;
- (BOOL) createContext;
- (void) destroyContext;
- (void) destroyCursor;

- (xcb_cursor_t) selectLeftPointerCursor;
- (xcb_cursor_t) selectResizeCursorForPosition:(MousePosition)position;
- (xcb_cursor_t) cursorIdForPosition:(MousePosition)position;

@end