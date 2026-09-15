// NoSaveSetTest - negative control for ICCCM §4.1.4 save-set behaviour.
//
// Without adding a reparented client to the WM's save-set, killing the WM
// (even via SIGKILL) destroys the WM-created frame window AND, because the
// client is its descendant, the client window too.  This test verifies that
// the destroy-without-save-set behaviour holds, which is the counterexample
// proving the save-set (tested in saveset.m) is what protects clients.
//
// Run with:  gnustep-tests test-saveset

#import <Foundation/Foundation.h>
#import <xcb/xcb.h>
#import <sys/types.h>
#import <sys/wait.h>
#import <signal.h>
#import <unistd.h>

#import "Testing.h"

static xcb_connection_t *connectToServer(xcb_screen_t **outScreen)
{
    xcb_connection_t *c = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(c)) {
        return NULL;
    }
    *outScreen = xcb_setup_roots_iterator(xcb_get_setup(c)).data;
    return c;
}

// Like the mini WM in saveset.m, but deliberately OMITS the save-set call.
static int miniWMNoSaveSet(xcb_window_t client)
{
    xcb_screen_t *screen = NULL;
    xcb_connection_t *c = connectToServer(&screen);
    if (!c) return 1;

    int cx = 0, cy = 0;
    {
        xcb_get_geometry_cookie_t gc = xcb_get_geometry(c, client);
        xcb_get_geometry_reply_t *gr = xcb_get_geometry_reply(c, gc, NULL);
        if (gr) { cx = gr->x; cy = gr->y; free(gr); }
    }

    xcb_window_t frame = xcb_generate_id(c);
    uint32_t mask = XCB_CW_EVENT_MASK;
    uint32_t values[] = { XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT };
    xcb_create_window(c, screen->root_depth, frame, screen->root,
                      cx, cy, 400, 300, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      screen->root_visual, mask, values);

    xcb_reparent_window(c, client, frame, 0, 0);
    xcb_map_window(c, frame);
    xcb_map_window(c, client);

    // NOTE: deliberately NO xcb_change_save_set(... INSERT ...) here.

    xcb_flush(c);
    for (;;) {
        xcb_generic_event_t *ev = xcb_wait_for_event(c);
        if (ev) free(ev);
    }
    return 0;
}

static int testNoSaveSetDestroysClient(void)
{
    xcb_screen_t *screen = NULL;
    xcb_connection_t *c = connectToServer(&screen);
    if (!c) {
        PASS(0, "could not connect to X server (is DISPLAY set?)");
        return 0;
    }

    xcb_window_t client = xcb_generate_id(c);
    xcb_create_window(c, screen->root_depth, client, screen->root,
                      300, 300, 200, 150, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      screen->root_visual, 0, NULL);
    xcb_map_window(c, client);
    xcb_flush(c);

    pid_t wm = fork();
    if (wm == -1) {
        PASS(0, "fork failed");
        return 0;
    }
    if (wm == 0) {
        _exit(miniWMNoSaveSet(client));
    }

    usleep(200000);
    kill(wm, SIGKILL);
    waitpid(wm, NULL, 0);
    usleep(200000);

    // Without the save-set, the client should be GONE (destroyed with the
    // frame).  xcb_get_window_attributes returns an error/NULL for a
    // destroyed window.
    {
        xcb_get_window_attributes_cookie_t ac = xcb_get_window_attributes(c, client);
        xcb_generic_error_t *err = NULL;
        xcb_get_window_attributes_reply_t *ar = xcb_get_window_attributes_reply(c, ac, &err);
        PASS(ar == NULL, "client window destroyed after WM SIGKILL when not in save-set");
        if (err) free(err);
        if (ar) free(ar);
    }

    xcb_disconnect(c);
    return 0;
}

int main(void)
{
    START_SET("no save-set => client destroyed on WM SIGKILL")
    testNoSaveSetDestroysClient();
    END_SET("no save-set => client destroyed on WM SIGKILL")
    return 0;
}
