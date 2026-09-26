/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "URSHotCorner.h"
#import "XCBConnection.h"
#import "XCBScreen.h"

static const NSTimeInterval URSHotCornerPollInterval = 0.1;
// The pointer must leave the corner by this much before it can fire again,
// or resting against it would fire it over and over.
static const int URSHotCornerRearmDistance = 8;

@interface URSHotCorner ()
@property (weak, nonatomic) XCBConnection *connection;
@property (weak, nonatomic) id target;
@property (assign, nonatomic) SEL action;
@property (assign, nonatomic) BOOL left;
@property (assign, nonatomic) BOOL top;
@property (assign, nonatomic) BOOL armed;
@property (strong, nonatomic) NSTimer *timer;
@end

@implementation URSHotCorner

- (instancetype)initWithConnection:(XCBConnection *)connection
                        cornerName:(NSString *)cornerName
                           setting:(NSString *)settingName
                            target:(id)target
                            action:(SEL)action {
    if ([cornerName isEqualToString:@"none"]) {
        return nil;
    }
    NSArray *corners = @[@"top-left", @"top-right", @"bottom-left", @"bottom-right"];
    if (![corners containsObject:cornerName]) {
        NSLog(@"[HotCorner] ERROR: %@ is %@, expected none, %@",
              settingName, cornerName, [corners componentsJoinedByString:@", "]);
        return nil;
    }
    self = [super init];
    if (self) {
        _connection = connection;
        _target = target;
        _action = action;
        _left = [cornerName hasSuffix:@"left"];
        _top = [cornerName hasPrefix:@"top"];
        _armed = YES;
    }
    return self;
}

- (void)start {
    // Polled rather than watched through small windows in the corners:
    // those would have to be kept above every window raised later.
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:URSHotCornerPollInterval
                                                  target:self
                                                selector:@selector(check:)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)check:(NSTimer *)timer {
    xcb_connection_t *conn = [self.connection connection];
    XCBScreen *screen = [[self.connection screens] objectAtIndex:0];
    xcb_query_pointer_reply_t *pointer = xcb_query_pointer_reply(conn,
        xcb_query_pointer(conn, [[screen rootWindow] window]), NULL);
    if (!pointer) {
        return;
    }
    int cornerX = self.left ? 0 : [screen width] - 1;
    int cornerY = self.top ? 0 : [screen height] - 1;
    int dx = abs(pointer->root_x - cornerX);
    int dy = abs(pointer->root_y - cornerY);
    // A drag into the corner (a window, a file) is not meant for the corner.
    BOOL buttonDown = (pointer->mask & (XCB_BUTTON_MASK_1 | XCB_BUTTON_MASK_2 | XCB_BUTTON_MASK_3)) != 0;
    free(pointer);

    if (dx == 0 && dy == 0 && self.armed && !buttonDown) {
        self.armed = NO;
        id target = self.target;
        if (target) {
            ((void (*)(id, SEL, id))[target methodForSelector:self.action])(target, self.action, self);
        }
    } else if (dx > URSHotCornerRearmDistance || dy > URSHotCornerRearmDistance) {
        self.armed = YES;
    }
}

@end
