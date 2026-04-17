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

**Note:** The display number `:1` is what you set for Xephyr. It cannot run on the same display where X11 is already running.

Distributions may set the `DISPLAY` environment variable differently based on their needs. For example:
- On **Ubuntu**, you typically cannot use `DISPLAY=:1` because it's already used by X11. You would need to use `DISPLAY=:2` for Xephyr instead.
- On other distributions you can usually use `:1`.



