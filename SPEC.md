# Window Overview Feature

## Overview

Window Overview provides a bird's-eye view of all open windows on the current
desktop (or across all desktops). When activated, the window manager scales
down every visible window and arranges them on a single plane so the user
can instantly locate and switch to the desired window.

This eliminates the need to cycle through windows one-by-one or hunt through
a task list when many applications are open simultaneously.

## Purpose

- Fast window discovery when many windows are open
- Quick visual identification of a target window by its content
- Efficient switching without relying on window titles or taskbar ordering
- Show the desktop by temporarily hiding all windows

## Activation

The feature can be triggered through any of the following:

| Method | Default binding | Notes |
|--------|----------------|-------|
| Keyboard shortcut | `Super+W` (or configurable) | Toggles the overview on/off |
| Hot corner | Top-left corner (optional) | Configurable in settings |
| Trackpad gesture | Three-finger swipe up (optional) | Requires gesture-capable hardware |
| Panel button | Click overview icon (optional) | Shown in the task manager or dock |

Pressing `Escape` or clicking outside any window dismisses the overview and
returns to normal desktop mode.

## Modes

### All Windows (default)

Shows every unminimized, unhidden window across all virtual desktops (or
restricted to the current desktop, depending on configuration). Windows
are scaled to uniform thumbnails and arranged in a grid or natural layout.

### Application Windows

Shows only windows belonging to the currently focused application. Useful
for finding a specific document or panel within a single application that
has many windows open.

### Show Desktop

Temporarily slides all windows off-screen to reveal the desktop. Clicking
a window thumbnail restores it. This is a toggle - triggering it again
restores all windows to their previous positions.

## Layout Behavior

### Natural Layout

Windows are positioned based on their original screen coordinates. Each
window is scaled proportionally and placed relative to its actual origin,
preserving spatial relationships. This helps users who rely on "that
window is in the top-left of my screen" mental models.

### Grid Layout

Windows are arranged in an optimized grid regardless of their original
position. This maximizes screen usage and ensures no overlap, but loses
spatial context.

The layout mode is configurable and should default to Natural for
first-time users.

## Visual Treatment

- **Window thumbnails**: Live previews rendered by the compositor, not
  static screenshots. Thumbnails update in real time.
- **Window titles**: Displayed below or on each thumbnail. Font size
  scales with thumbnail size.
- **Active window**: Highlighted with a distinct border or glow to
  indicate which window has focus.
- **Minimized windows**: Optionally shown dimmed or with a visual
  indicator; excluded by default for clarity.
- **Background**: A semi-transparent dark overlay dims the desktop
  behind the thumbnails to reduce visual clutter.
- **Workspace indicator**: When multiple virtual desktops exist, a
  strip or bar shows all workspaces and which one is active.

## Interaction

| Action | Result |
|--------|--------|
| Click a thumbnail | Switch to that window, dismiss overview |
| Middle-click a thumbnail | Switch to window and keep overview open (optional) |
| Hover a thumbnail | Show a larger preview or window title tooltip |
| Right-click a thumbnail | Context menu: move to workspace, close, always on top |
| Type to search | Filter thumbnails by window title or application name |
| Arrow keys | Navigate between thumbnails |
| `Enter` | Switch to highlighted window |
| `Escape` | Dismiss overview |
| Scroll wheel | Cycle through virtual desktops |

## Keyboard Navigation

When the overview is active, full keyboard navigation must work:

1. Arrow keys move focus between thumbnails in visual order
2. `Tab` / `Shift+Tab` cycles through windows
3. Typing initiates a search filter (window title or app name)
4. `Enter` activates the focused window
5. `Escape` cancels and returns to the desktop

## Virtual Desktop Support

- A workspace switcher strip appears at the top or bottom of the overview
- Clicking a workspace thumbnail switches to that workspace
- Windows can be dragged between workspaces while in overview mode
- Option to show windows from all workspaces or only the current one
- A "Show All" mode displays every workspace simultaneously in a
  grid, with each workspace shown as a cluster of thumbnails

## Search

When the user starts typing in overview mode, a search field appears and
the visible thumbnails are filtered in real time:

- Match against window title, application name, or class
- Multiple search terms are AND-ed (e.g., "firefox mail" shows
  Firefox windows with "mail" in the title)
- Results update on each keystroke
- `Backspace` removes the last character; empty string restores all
- `Enter` on a single result switches to it immediately

## Performance Requirements

- Thumbnail rendering must not cause perceptible frame drops
- Entering and exiting overview must complete within 300 ms
- Live previews must update at least at 15 fps while overview is open
- No unnecessary texture copies; use damage tracking or compositor
  side-stream rendering where available
- On systems with many windows (>50), fall back to static thumbnails
  to maintain responsiveness

## Accessibility

- All keyboard navigation described above must work without a pointing
  device
- Screen reader must announce the overview mode, number of windows,
  and the focused window's title
- High-contrast mode must ensure thumbnail borders and focus indicators
  are clearly visible
- Minimum touch target size of 48x48 px for touch/gesture activation

## Configuration

The following should be user-configurable:

- Activation shortcut (keyboard, gesture, hot corner)
- Layout mode: natural vs. grid
- Whether to show minimized windows
- Whether to include all workspaces or only the current one
- Animation duration (can be set to 0 for reduced motion)
- Background opacity
- Thumbnail size (small, medium, large)
- Search behavior (filter vs. highlight)

## Implementation Notes

- The compositor must support rendering window thumbnails without
  redirecting the window's drawing context. If damage tracking is
  available, prefer it over full re-renders per frame.
- The overview overlay is a separate X11 window or compositor layer
  that sits above all managed windows but below any system UI (panels,
  notifications).
- When the overview is active, normal window operations (move, resize,
  close from taskbar) must continue to work without dismissing the
  overview first.
- The window manager must keep the stacking order consistent when
  exiting overview: the window the user clicked should be raised to
  the top and given focus.

## Edge Cases

- **Single window open**: Overview still works but provides no benefit;
  could optionally skip activation.
- **All windows minimized**: Show desktop mode or empty overview with
  a "No open windows" message.
- **Multi-monitor**: Overview activates per-monitor by default. An
  option may show all monitors' windows combined.
- **Window on another workspace**: Include it in overview (dimmed) with
  a workspace indicator badge, or exclude based on configuration.
- **Notification/dialog windows**: Small transient windows (tooltips,
  pop-ups) should be excluded from overview to reduce clutter.
