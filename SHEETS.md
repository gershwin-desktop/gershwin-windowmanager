# Sheets

A sheet is a document-modal panel (an alert, a save panel) that belongs to
one window. The window manager hangs it from the bottom of that window's
titlebar, centred on it, without a titlebar of its own, slides it out from
under the titlebar when it is shown and back when it is dismissed, and keeps
it attached to its parent.

## The contract with clients: `WM_WINDOW_ROLE` = `sheet`

A client marks a window as a sheet with two standard ICCCM properties, both
set before the window is mapped:

| Property           | Type        | Value                               |
|--------------------|-------------|-------------------------------------|
| `WM_TRANSIENT_FOR` | `WINDOW`    | the client window it is a sheet of  |
| `WM_WINDOW_ROLE`   | `STRING`    | `sheet` (a trailing NUL is ignored) |

Both are needed: `WM_TRANSIENT_FOR` alone is set for any dialog, drawer or
child window, and the role alone does not say whose sheet it is. Any other
role, or none, means "not a sheet". A client that shows the same window later
as an ordinary dialog must remove the role first. No private property is
used, so any toolkit can take part.

The window is treated as a sheet only while its parent is decorated (framed);
a sheet of an undecorated or unknown window is framed like any other dialog.

The Eau theme sets the property for every GNUstep sheet
(`-beginSheet:modalForWindow:...`, `NSAlert`, `NSSavePanel`) in its swizzled
`XGServer -orderwindow:::`; see the theme's README. No libs-gui change is
needed.

## What the window manager does with a sheet

| Event | Behaviour |
|-------|-----------|
| Map request | Not framed. Placed at the top of the parent's client area, centred, kept on the screen sideways, stacked directly above the parent's frame, mapped and focused. |
| Configure request | Only its size is honoured; it is placed again, so a growing sheet stays centred. |
| Parent moves, resizes or is restacked | The sheet follows (ConfigureNotify of the parent's client or frame). |
| Parent (client or frame) gets the focus | The focus is passed to the sheet; the parent keeps its active titlebar. A click on the parent therefore leaves Return and typing with the sheet. |
| Sheet gets the focus | The parent's titlebar is drawn active (the sheet has none). |
| Parent's frame unmapped (minimised) | The sheet is unmapped with it and stays attached. |
| Parent's frame mapped again | The sheet is mapped again, without a slide, and gets the focus back. |
| Sheet unmapped by the client (dismissed) | The slide back plays after the unmap; the focus returns to the parent. |
| Window manager starts with a sheet up | Adoption frames every other window first, then attaches mapped sheets to their parents instead of framing them. |
| Parent or sheet destroyed | The attachment is forgotten. |

Placement, following, stacking and focus work with or without the
compositor; the slide needs it.

## Code

| File | Role |
|------|------|
| `URSSheetController.h/m` | Recognises sheets, places, maps, follows, hides and focuses them; hooked into `URSHybridEventHandler` (map/configure requests, Map/Unmap/Configure/Destroy notify, FocusIn, start-up adoption). |
| `URSWindowRole.h/m` | Reads `WM_WINDOW_ROLE` values (Foundation only). |
| `URSAttachmentRegistry.h/m` | Which sheet (or drawer) hangs from which window, and whether it is hidden with its parent (Foundation only). |
| `URSSheetLayout.h/m` | Where a sheet sits on its parent and how far it has slid out (pure geometry). |
| `URSSheetSlideEffect.h/m` | The 0.25 s slide as a `URSWindowEffect`, clipped at the titlebar (`-clipRectForWindowRect:`); it may replace a running effect (`-replacesRunningEffect`), so a sheet dismissed mid-slide slides back at once. |

The compositor keeps a sheet's picture after unmap
(`-setKeepsContentAfterUnmap:forWindow:`, a named pixmap) so that the slide
back can be painted once the window is gone, and an effect started at map
time waits for the client's first content.

## Tests

`gnustep-tests test-sheets` (headless): `sheetlayout.m` (placement and
curve), `sheetslide.m` (the slide effect, its clip and reach, replacing a
running effect), `attachmentregistry.m` (attachment bookkeeping), `windowrole.m` (reading the
role).
