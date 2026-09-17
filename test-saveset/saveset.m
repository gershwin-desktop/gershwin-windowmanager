// SaveSetTest - verify ICCCM §4.1.4 save-set behaviour.
//
// A reparenting window manager must add every managed client window to its
// X save-set (xcb_change_save_set INSERT).  When the WM connection dies,
// even via SIGKILL, the X server then automatically reparents each save-set
// window back to the root, preserving position and stacking, BEFORE it
// destroys the WM-created frame windows.  Without the save-set the client
// windows would be destroyed along with the frames.
//
// This test:
//   1. creates a client window,
//   2. forks a "mini WM" that reparents the client into a frame and adds it
//      to the save-set,
//   3. SIGKILLs the mini WM,
//   4. verifies the client still exists, is still mapped, and is now a
//      direct child of the root again.
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

// The mini window manager.  Runs in a forked child: reparents the client
// window into a frame window and adds it to the save-set, then loops until
// killed.
static int miniWM(xcb_window_t client)
{
    xcb_screen_t *screen = NULL;
    xcb_connection_t *c = connectToServer(&screen);
    if (!c) return 1;

    // Query the client's current position so the frame can be placed there
    // and the client reparented at (0,0) within it — this preserves the
    // client's absolute position (like a real WM does when decorating).
    int cx = 0, cy = 0;
    {
        xcb_get_geometry_cookie_t gc = xcb_get_geometry(c, client);
        xcb_get_geometry_reply_t *gr = xcb_get_geometry_reply(c, gc, NULL);
        if (gr) { cx = gr->x; cy = gr->y; free(gr); }
    }

    // Create the frame (a plain child of root) at the client's position.
    xcb_window_t frame = xcb_generate_id(c);
    uint32_t mask = XCB_CW_EVENT_MASK;
    uint32_t values[] = { XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT };
    xcb_create_window(c, screen->root_depth, frame, screen->root,
                      cx, cy, 400, 300, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      screen->root_visual, mask, values);

    // Reparent the client into the frame at (0,0) and map both.
    xcb_reparent_window(c, client, frame, 0, 0);
    xcb_map_window(c, frame);
    xcb_map_window(c, client);

    // THIS IS THE KEY STEP: add the client to the save-set.
    // A real WM does this (via XCBFrame decorateClientWindow).
    xcb_change_save_set(c, XCB_SET_MODE_INSERT, client);

    xcb_flush(c);

    // Loop forever until killed with SIGKILL (we don't install handlers).
    for (;;) {
        xcb_generic_event_t *ev = xcb_wait_for_event(c);
        if (ev) free(ev);
    }
    return 0;
}

static int testSaveSetSurvivesKill(void)
{
    xcb_screen_t *screen = NULL;
    xcb_connection_t *c = connectToServer(&screen);
    if (!c) {
        PASS(0, "could not connect to X server (is DISPLAY set?)");
        return 0;
    }

    // 1. Create a plain client window and map it.
    xcb_window_t client = xcb_generate_id(c);
    xcb_create_window(c, screen->root_depth, client, screen->root,
                      100, 100, 200, 150, 0, XCB_WINDOW_CLASS_INPUT_OUTPUT,
                      screen->root_visual, 0, NULL);
    xcb_map_window(c, client);
    xcb_flush(c);

    // 2. Fork the mini WM.
    pid_t wm = fork();
    if (wm == -1) {
        PASS(0, "fork failed");
        return 0;
    }
    if (wm == 0) {
        // Child: become the mini WM.  It inherits the parent's X connection
        // socket; make a fresh connection so the parent's is independent.
        _exit(miniWM(client));
    }

    // Give the WM a moment to reparent + add to save-set.
    usleep(200000);

    // Sanity check: the client should now be inside the WM's frame.
    {
        xcb_query_tree_cookie_t tc = xcb_query_tree(c, client);
        xcb_query_tree_reply_t *tr = xcb_query_tree_reply(c, tc, NULL);
        int hasParent = 0;
        if (tr) {
            hasParent = (tr->parent != screen->root);
            free(tr);
        }
        PASS(hasParent, "client is reparented into WM frame before kill");
    }

    // 3. SIGKILL the WM — no chance for cleanup.
    kill(wm, SIGKILL);
    waitpid(wm, NULL, 0);

    // Give the X server a moment to process the connection close.
    usleep(200000);

    // 4. Verify the client survived and is mapped.
    {
        xcb_get_window_attributes_cookie_t ac = xcb_get_window_attributes(c, client);
        xcb_get_window_attributes_reply_t *ar = xcb_get_window_attributes_reply(c, ac, NULL);
        PASS(ar != NULL, "client window still exists after WM SIGKILL");
        if (ar) {
            PASS(ar->map_state == XCB_MAP_STATE_VIEWABLE, "client window is still mapped after WM SIGKILL");
            free(ar);
        }
    }

    // 5. Verify the client was reparented back to the root (stacking/position
    //    preserved, frames destroyed instead of clients).
    {
        xcb_query_tree_cookie_t tc = xcb_query_tree(c, client);
        xcb_query_tree_reply_t *tr = xcb_query_tree_reply(c, tc, NULL);
        if (tr) {
            PASS(tr->parent == screen->root, "client reparented back to root after WM SIGKILL");
            free(tr);
        } else {
            PASS(0, "could not query client parent after kill");
        }
    }

    // 6. Position should be preserved (absolute coords are kept by the server
    //    on save-set reparenting).
    {
        xcb_get_geometry_cookie_t gc = xcb_get_geometry(c, client);
        xcb_get_geometry_reply_t *gr = xcb_get_geometry_reply(c, gc, NULL);
        if (gr) {
            PASS(gr->x == 100 && gr->y == 100, "client position preserved after WM SIGKILL");
            free(gr);
        } else {
            PASS(0, "could not get client geometry after kill");
        }
    }

    // Cleanup.
    xcb_destroy_window(c, client);
    xcb_flush(c);
    xcb_disconnect(c);
    return 0;
}

int main(void)
{
    START_SET("save-set survives WM SIGKILL")
    testSaveSetSurvivesKill();
    END_SET("save-set survives WM SIGKILL")
    return 0;
}
