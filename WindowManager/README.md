# WindowManager

> **Note:** This project has been renamed from `uroswm` to `WindowManager`.

A window manager written in Objective-C using GNUstep and the XCBKit framework.

---

## Installation

To install WindowManager, you need XCBKit installed on your system.

## Dependencies

### XCBKit Dependencies
- libxcb
- xcb-fixes
- xcb-icccm
- gnustep-base

### WindowManager Dependencies
- XCBKit

---

## Testing

If you want to try WindowManager's current status, you can test it using Xephyr:

```bash
# Start Xephyr on display :1
Xephyr -ac -br -screen 1300x900 -reset :1 &

# Set the DISPLAY environment variable
export DISPLAY=:1

# Run the window manager
uroswm
# Or run in background to free the command line
uroswm &
```

### Command-Line Options

```
uroswm [options]

Options:
  -dc, --disable-compositing  Disable XRender compositing
  -h, --help          Show help message
```

**Compositing Mode:**
- **Default:** Windows use XRender for transparency effects
- **With `-dc`:** Windows render directly (traditional mode)
- Automatically falls back to non-compositing on any errors
- Requires COMPOSITE, RENDER, DAMAGE, and XFIXES X extensions

### Settings

```
defaults write WindowManager URSHopOnWindowSwitch YES
defaults write WindowManager URSOverviewHotCorner top-left
defaults write WindowManager URSWobblyWindows YES
defaults write WindowManager URSWindowSwitcherStyle deck
```

The overview and Show Desktop settings take effect when the window manager
starts.

- `URSOverviewEnabled` (default `YES`): F9 shows every window on the
  screen side by side, shrunk, over a darkened desktop; the menu bar, the
  Dock and any other window of type `_NET_WM_WINDOW_TYPE_DOCK` fade out
  meanwhile. Click a window,
  or pick one with the arrow keys and Return, to bring it to the front;
  Escape, F9 or a click beside the windows goes back. Needs compositing.
- `URSOverviewKey` (default `F9`): the X key name of the key that opens
  and closes the window overview.
- `URSOverviewHotCorner` (default `none`): `top-left`, `top-right`,
  `bottom-left` or `bottom-right` opens and closes the window overview
  when the pointer is pushed into that screen corner.
- `URSShowDesktopEnabled` (default `YES`): F11 slides every window out
  over the nearest edge of the screen until only a sliver of it is left,
  so the desktop can be used: icons opened, files dragged. The menu bar
  and the Dock stay; palettes fade out. F11 again brings the windows back with the one in
  front focused again; a click on a sliver brings them back with that one
  in front; a window becoming active (a new window, the Dock, Alt-Tab)
  brings them back too. F9 opens the overview over it. Needs compositing.
- `URSShowDesktopKey` (default `F11`): the X key name of the key that
  shows the desktop and brings the windows back.
- `URSShowDesktopHotCorner` (default `none`): `top-left`, `top-right`,
  `bottom-left` or `bottom-right` does the same when the pointer is pushed
  into that screen corner.
- `URSWobblyWindows` (default `NO`): a window dragged by its titlebar
  bends and trails behind the pointer like jelly and wobbles back into
  shape when let go. Needs compositing. Takes effect on the next drag.
- `URSHopOnWindowSwitch` (default `NO`): the window Alt-Tab switches to
  hops in place to lead the eye to it. Needs compositing. Takes effect
  on the next switch, without restarting the window manager.
- `URSWindowSwitcherStyle` (default `flow`): how Alt-Tab shows the
  windows while Alt is held. `flow` flies the windows themselves into a
  row across the darkened screen, the chosen one big in the middle and
  the others turned away to both sides; Tab and Shift-Tab slide the row,
  releasing Alt flies the chosen window back and raises it, Escape flies
  everything back. Minimized windows are left out of the row. Without
  compositing, with fewer than two windows on the screen, or with `list`,
  a strip of application icons and names is shown instead. Takes effect
  on the next switch.
  `deck` flies the windows into a deck instead, as an endless carousel:
  the chosen window stands in front with its middle at the golden section
  of the screen height, low on the screen, and the others stand behind it,
  each smaller and higher so that only their top strips show. Each Tab
  sends the front window down out of the screen, growing as it comes nearer
  to the viewer, and brings it back in from behind at the top while every
  other window moves one place forward; Shift-Tab goes the other way.
  Windows are shown at most at their own size at rest and always leave some
  room above the bottom edge. Off unless set, since `flow` is the default:
  `defaults write WindowManager URSWindowSwitcherStyle deck`.
- `URSWindowFlipEnabled` (default `YES`): "Flip Window" in the titlebar's
  context menu turns the window over, in perspective, to its plain back;
  choosing it again turns it back. Only the picture turns: the window
  stays where it is and keeps working. Needs compositing. Takes effect
  the next time the menu is opened.
- `URSWindowFlipSideTerminal` (default `YES`): the back of a window turned
  over with "Flip Window" shows a terminal in the source directory of the
  window's application, under the window's own titlebar, which stays
  usable. The directory is the one whose GNUmakefile declares the
  application's name as `APP_NAME` under `/Developer/Library/Sources`,
  subdirectories included; no plist is needed. The first turn starts Terminal and waits
  for its window (at most 10 seconds); the shell is then there on every
  turn, and typing `exit` turns the window back to its front. With the back
  shown, keys and clicks over the client area go to the terminal. The
  terminal outlives its window: when the window goes (its application
  quits, is killed or closes it), the terminal stays where it was as a
  window of its own, with a titlebar, in front and focused; its close
  button ends it. When the application is started again, its next window
  takes the terminal back onto its back (the one left longest, if there
  are several), with the shell as it was. Applications without such a directory turn to
  the plain back. Read at every flip; set to `NO` to always get the plain
  back (a terminal already running for a window then quits):
  `defaults write WindowManager URSWindowFlipSideTerminal NO`.

**Note:** The display number `:1` is what you set for Xephyr. It cannot run on the same display where X11 is already running.

Distributions may set the `DISPLAY` environment variable differently based on their needs. For example:
- On **Ubuntu**, you typically cannot use `DISPLAY=:1` because it's already used by X11. You would need to use `DISPLAY=:2` for Xephyr instead.
- On other distributions you can usually use `:1`.



