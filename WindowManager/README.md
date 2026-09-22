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

**Note:** The display number `:1` is what you set for Xephyr. It cannot run on the same display where X11 is already running.

Distributions may set the `DISPLAY` environment variable differently based on their needs. For example:
- On **Ubuntu**, you typically cannot use `DISPLAY=:1` because it's already used by X11. You would need to use `DISPLAY=:2` for Xephyr instead.
- On other distributions you can usually use `:1`.



