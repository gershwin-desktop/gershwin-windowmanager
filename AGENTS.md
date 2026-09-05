# AGENTS.md

Gershwin WindowManager: a standalone reparenting X11 window manager for the
GNUstep-based Gershwin desktop. Objective-C + XCB (no GNUstep display server).

## Build, install, restart

- Build the app: `cd WindowManager && make` (top-level `GNUmakefile` just
  forwards there). Single target, no framework. Must build warning-free.
  `make PROFILE=1` enables CPU instrumentation (summary every 10s and on
  SIGUSR1).
- Install: `sudo make install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`. The app is
  installed to `/System/Library/CoreServices/Applications/WindowManager.app/WindowManager`
  (that exact path is what the running WM is; there is no LOCAL copy).
- To test changes: install, then restart the WM process. The desktop start
  script (`gershwin-system/Library/Scripts/Gershwin.sh`) launches it via
  `(WindowManager &)`; killing and relaunching it manually works too. For a
  sandboxed smoke test on a nested server, `WindowManager/test-with-xephyr.sh`
  builds and runs the WM plus test windows in Xephyr (default `:10`).
- **Arc is ON**: sources are compiled with `-fobjc-arc`. Do not add
  retain/release/autorelease. This is unusual for GNUstep and easy to get
  wrong.

## Tests

- Save-set suite (regression test for ICCCM §4.1.4): `gnustep-tests test-saveset`
  from the repo root. Uses the GNUstep ObjectTesting framework (`PASS()`);
  needs a live X server (`DISPLAY` set). Writes `tests.log`/`tests.sum`
  (gitignored).
- `test/` is a manual app (KillTest.app), not part of the automated suite.

## Branching

- Work on `dev` (ahead of `master`; `origin/HEAD -> origin/master`). Never
  commit to `master`/`main`.

## Architecture (see ARCHITECTURE.md)

- All code under `WindowManager/`, one binary. XCB layer in `WindowManager/xcb/`
  (plus `services/`, `enums/`, `utils/`). Build adds `-Ixcb -Ixcb/services
  -Ixcb/enums -Ixcb/utils`, so import headers by name only (`#import "XCBConnection.h"`),
  never by path.
- Event coordinator: `URSHybridEventHandler` (bridges the XCB fd into the
  NSRunLoop and dispatches). Managers: `URSFocusManager`, `URSKeyboardManager`,
  `URSWorkareaManager`, `URSTitlebarController`, `URSSnappingMenuController`.
- Compositing is ON by default; disable with `-dc`/`--disable-compositing`
  (see `main.m`). `URSCompositingManager` owns animations.

## Window open/close animation protocol (cross-repo contract)

- Documented in ANIMATIONS.md. WM advertises `_WINDOW_BIRTH_ANIMATION` and
  `_WINDOW_CLOSE_ANIMATION` in `_NET_SUPPORTED`; Workspace (gershwin-workspace,
  `GWViewersManager.m` / `X11AppSupport.m`) is the producer. If you change the
  property layout or atom names, update BOTH sides and ANIMATIONS.md.
- Birth animation reads the property in `XCBConnection.m` (map request);
  close animation is driven by `UnmapNotify`. The property is deleted after
  reading (one-shot); a re-mapped window without a fresh property must NOT
  reuse it.

## Logging / error-noise conventions

- `XCBReply description` is **intentionally silent** about BadWindow/BadDrawable
  errors (they are expected during window teardown). Do not "fix" it by adding
  logging there.
- A `BadWindow` flood from **Menu.app** (gershwin-components) after opening/
  closing menus comes from Menu doing X11 work on undecorated popup/drop-down
  windows that the WM no longer manages. The WM-side fix direction is to ignore
  undecorated / override-redirect / popup windows earlier and more aggressively;
  startup adoption already skips `overrideRedirect`. Menu-side code lives in
  gershwin-components, not here.
- The WM itself logs a WARNING when a Workspace window maps without the birth
  property; keep that, it flags a producer regression.

## Other gotchas

- The build links `-ldispatch` and `dispatch_async`/`dispatch_after` is used in
  `XCBConnection.m`. Note: global project rules forbid adding new
  libdispatch/GCD usage - follow the existing style if you must touch these
  call sites, but prefer not to introduce new dispatch code.
- `GSScaleFactor` (HiDPI) is monitored live; scale changes re-frame windows and
  re-render titlebars. `TitleBarSettingsService` holds titlebar height from the
  GSTheme.
- The WM reparents every managed client into a frame and adds it to the X
  save-set so clients survive a WM crash/SIGKILL (see test-saveset).
- Don't `git add`/commit `tests.log`, `tests.sum`, `obj/`, `*.app` (already in
  `.gitignore`).
