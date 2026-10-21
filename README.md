# Oz Window Manager

A **vertically scrolling** tiling window manager for macOS, inspired by [PaperWM](https://github.com/paperwm/PaperWM).

Instead of squeezing every window onto the screen, Oz lays windows out on an endless **vertical strip**, one below the other, like panels on a comic book page. The screen is a viewport onto that strip: **swipe up and down with three fingers** to move along it freely. When you let go, the strip glides on and settles on a window edge if it is close to one.

```
┌──────────── screen ───────────┐
│ ┌───────────────────────────┐ │
│ │        Terminal           │ │ ← focused
│ └───────────────────────────┘ │
│ ┌────────────┐ ┌────────────┐ │
│ │   Safari   │ │   Notes    │ │ ← two panels in one row
│ └────────────┘ └────────────┘ │
└───────────────────────────────┘
  ┌───────────────────────────┐
  │          Xcode            │   ← below the screen, three fingers up brings it in
  └───────────────────────────┘
  ┌───────────────────────────┐
  │          Mail             │
  └───────────────────────────┘
```

## Install and run

Requires macOS 14+ and Xcode / Swift 5.9+.

```bash
make run        # builds build/Oz.app and starts it
make install    # copies it to ~/Applications/Oz.app and starts it
make test       # unit tests
make stop       # quits the running Oz
```

On first launch:

1. **Accessibility**: System Settings › Privacy & Security › Accessibility › turn on *Oz*. Oz starts as soon as it has the permission.
2. **Trackpad**: if the three-finger vertical swipe still belongs to Mission Control, Oz asks to take it over. With *Apply*:
   - three fingers up/down → **Oz scrolls the strip**
   - **three-finger double tap → Mission Control** (toggles it, like the Mission Control key)
   - Mission Control also stays on four fingers up and F3; App Exposé on four fingers down
   - to undo: menu bar › *Trackpad: Restore macOS Gestures* (or `scripts/trackpad-gestures.sh restore`)

   If it doesn't take effect right away, set System Settings › Trackpad › More Gestures › Mission Control to **"Swipe Up with Four Fingers"** (same thing).
3. **Screen Recording** (optional): needed for windows to slide off the top edge (see below). Without it Oz shrinks them instead.

> **Development note:** with an ad-hoc signature every build changes the code signature and macOS drops the Accessibility permission. Run `./scripts/create-signing-cert.sh` once: it adds a self-signed "Oz Local Signing" identity to your login keychain, `make app` uses it automatically and the permissions survive rebuilds (`SIGN_ID=...` for another identity).

The ▤ menu bar icon: toggle tiling, toggle tiling for this desktop, live capture, smooth scrolling, scroll area, retile, edit/reload the config, open the log, trackpad setup, quit. When Oz quits it brings every window it hid back on screen.

## Widths and rows

- **Narrow a window with the mouse.** If it is alone in its row, the space beside it stays empty and the window stays where you left it: narrowed from the right it keeps its left edge, from the left it keeps its right edge, so you can place it anywhere in the row by its edges — or drag it by its title bar and drop it in the same row: it slides back into the row at the sideways place you dropped it. Keyboard width changes keep its place too (moving it left only as far as it needs to fit); back at full width it fills the row again.
- To put windows side by side, drag one beside another (the vertical split line) or use `joinUp` / `joinDown` / `slurpIn`; rows are never merged on their own.
- **Moving up/down** (`⌃⌥⇧ ↑/↓`, `moveUp`/`moveDown`): if the next row holds a single narrowed window and this one fits in the space beside it, it joins that row (on the side it's on) and the two share it; press again and it carries on, into a row of its own beyond. Otherwise the rows swap as before.
- The same from the keyboard: in a single-window row `cycleWidth` (`⌃⌥ w`) cycles the share 1/3 → 1/2 → 2/3 → full, `resizeWidth` (`⌃⌥ , / .`) narrows/widens in steps, `equalizeRow` (`⌃⌥ =`) goes back to full width.
- While you resize a window, its neighbours make room live.
- **Double click a title bar** (macOS zoom): the window fills the whole usable screen (not just the Oz zone, over the regions around it too) while the rest of the strip stays as it was behind it; double click again and it slides back into its place. Same as `toggleMaximize` (`⌃⌥⇧ f`). Rearranging the strip (moves, joins, sizes) puts it back first.
- Keyboard moves (`moveUp/Down/Left/Right`, joins, width/height changes, floating) slide the windows to their new places over `animationDuration` instead of jumping.

## Scroll area

By default the strip scrolls across the whole screen. Menu bar › *Set Scroll Area…* (or `⌃⌥⇧ a`) lets you give it only part of the screen, e.g. the right half: the windows are hidden behind the wallpaper, the rest of the screen is dimmed, and the hatched area can be resized by its edges and corners, moved by dragging inside it, or drawn anew (presets: left/right half, left/right two thirds, full). Return saves, Esc cancels. The strip then lives in that area only and the rest of the screen stays empty: windows are cut off at the area's top and bottom edges the same way they slide off the top of the screen. Each desktop has its own area, remembered across restarts; *Reset Scroll Area* goes back to the whole screen.

Menu bar › *Keep Windows Alive (Live Capture)* decides how windows cut off at an edge are drawn: on, they are captured continuously (`livePeekFPS`), so video keeps playing; off, Oz takes one picture when a window starts to peek and shows that, so screen capture (and its indicator) only runs for a moment. The menu choice overrides `livePeek` in the config and is remembered.

With a scroll area set, the rest of the screen is free for windows that stay put:

- **Drag a window out** of the scroll area (by its title bar) and drop it outside: it leaves the strip and stays where you dropped it, floating, unaffected by scrolling. The strip closes the gap.
- **Tear a tab off** (Chrome, Safari, Finder, Terminal…) and drop it outside the area: the new window stays there. Dropped inside, it joins the strip.
- **Regions around the zone.** The free part of the screen is divided into rectangles: one per side of the zone that is wide enough for a window (150 pt), as few as possible, the corners going to whichever side makes the longest rectangle. A window dropped outside the zone (dragged out, a torn-off tab, or a floating window moved there) is tiled in the region under the cursor when you let go: alone it fills the region; if a window is already there, the region is split in half along its long side (stacked in a tall region, side by side in a wide one) and the new window takes the half where the cursor is. More windows share the region equally. When one leaves (closed, dragged into the zone or to another region) the rest close the gap; when the zone is resized, docked windows move to the region that now holds them.
- **Split lines in the zone.** Dragging a window over the Oz zone shows a glowing line (no animation, it jumps straight to the slot) where it will go: a horizontal line between two rows (above the row under the cursor when it's in the row's upper half, below it otherwise), or a vertical line beside a window when the cursor is near that window's left or right edge (then they share the row). Let go and it slides into that slot — this works for windows already in the strip too, so you can reorder the strip by dragging. No line means it would stay where it is. To reach rows out of view, rest the cursor in the band along the zone's top or bottom edge (15% of its height) while dragging: after a moment the strip scrolls that way, faster the closer you are to the edge, easing in and out; back in the middle it stops. It only arms once the drag has been in the middle of the zone, so grabbing a window's title bar at the top of the zone doesn't scroll.
- **Drop preview.** While you drag, a pane of Liquid Glass (frosted glass before macOS 26) shows where the window will land if you let go: its slot in a region outside the zone, or the zone itself when it would join the strip. Nothing shows while a tiled window is still inside the zone (it goes back to its place) or while you resize by an edge.
- **Drag it back** into the scroll area: it joins the strip at the row nearest to where you dropped it. The same goes for a window floated with `toggleFloat`; windows that float because of a rule or a fixed size stay floating.

## Tiling per desktop

Each Mission Control desktop can be tiled or left floating on its own: `⌃⌥⇧ esc` (`toggleSpaceTiling`) or menu bar › *Tile This Desktop*. On a floating desktop Oz leaves every window where it is (hidden ones come back on screen) and ignores its gestures and shortcuts; turning tiling back on picks its windows up again. The choice is remembered across restarts. A window moved to a floating desktop is let go.

## Gestures

| Gesture | Action |
|---|---|
| Three fingers up/down | Scroll the strip freely; on release it glides with your speed and settles on a window edge (top or bottom) when it ends near one. Focus doesn't change (`swipe.focus: true` to focus the top window). `snap: "always"` for panel-by-panel scrolling. |
| Three-finger double tap | Mission Control (configurable) |
| Three fingers left/right | Left to macOS (switching Spaces) |

When Oz opens Mission Control or App Exposé (double tap, `⌃⌥ m`, `⌃⌥⇧ m`) it first brings the strip's off-screen windows onto the screen, so the overview shows them at a normal size, and slides them back into the strip when it closes. Opened another way (four-finger swipe, the Mission Control key) the overview sees the parked windows where they are and draws them small.

If the scroll direction feels reversed, set `swipe.natural: false`.

## Default shortcuts (`⌃⌥` = ctrl+alt, `⇧` = shift)

Keys are resolved in the active keyboard layout; the defaults are for a US layout (edit the `K` table at the top of the config for others, e.g. Turkish Q uses `ğ ü ö ç - .`).

| Keys | Action | | Keys | Action |
|---|---|---|---|---|
| `⌃⌥ h j k l` / arrows | focus left/down/up/right | | `⌃⌥⇧ h j k l` / arrows | move the window |
| `⌃⌥ 1…9` | go to row n | | `⌃⌥ home/end` | first/last row |
| `⌃⌥ [` | **joinUp**: into the row above, side by side | | `⌃⌥ ]` | **joinDown**: into the row below |
| `⌃⌥ i` | slurpIn: pull the window below into this row | | `⌃⌥ o` | barfOut: take it out of the row |
| `⌃⌥ w` / `⌃⌥⇧ w` | width share 1/3 → 1/2 → 2/3 | | `⌃⌥ =` | equalize the row |
| `⌃⌥ ,` / `⌃⌥ .` | narrower / wider | | `⌃⌥⇧ ,` / `⌃⌥⇧ .` | shorter / taller |
| `⌃⌥ s` | side by side: pull in + equalize | | `⌃⌥⇧ s` | this panel 2/3 |
| `⌃⌥ r` / `⌃⌥⇧ r` | cycle height | | `⌃⌥ f` | toggle full height |
| `⌃⌥⇧ f` | fill the screen / back into the strip | | | |
| `⌃⌥ c` / `⌃⌥ t` | center / align to top | | `⌃⌥ u` / `⌃⌥ d` | scroll half a screen |
| `⌃⌥⇧ pageup/pagedown` | start / end of the strip | | `⌃⌥ esc` | toggle floating |
| `⌃⌥ return` | new Terminal | | `⌃⌥⇧ q` | close the window |
| `⌃⌥ n` | move to the next screen | | `⌃⌥ m` / `⌃⌥⇧ m` | Mission Control / App Exposé |
| `⌃⌥⇧ t` | toggle tiling | | `⌃⌥⇧ esc` | toggle tiling for this desktop |
| `⌃⌥⇧ c` | reload the config | | `⌃⌥⇧ a` | set this desktop's scroll area |
| `⌃⌥ /` | shortcut cheat sheet | | | |

## Config (`~/.config/oz/config.js`)

Plain JavaScript (JavaScriptCore), like PaperWM's `user.js`. Created from [examples/config.js](examples/config.js) on first launch and **reloaded automatically when you save**. To validate it:

```bash
make check-config
```

```js
oz.set({
  gap: 10, outerGap: 10, width: 1.0,
  heights: [1/3, 1/2, 2/3, 1],      // cycleHeight presets (PaperWM: window_ratios)
  defaultHeight: 1/2,
  newWindowPosition: "below",       // below | above | end | start
  animationDuration: 0.2,
  topOverflow: "slide",             // slide | shrink | hide
  swipe: { enabled: true, fingers: 3, sensitivity: 1.5, natural: true, snap: "near", snapDistance: 70, momentum: 1.0, focus: false },
  doubleTap: { enabled: true, fingers: 3, action: "missionControl" },
});

oz.bind("ctrl+alt+j", "focusDown");                       // a command name
oz.bind("hyper+return", function () { oz.exec("open -na Terminal"); });  // a function
oz.bind("ctrl+alt+1", function () { oz.setHeight(1/3); });

oz.rule({ app: "Calculator", float: true });               // don't tile
oz.rule({ app: /Code/, title: /Settings/, float: true });  // RegExp, arrays and functions work too
oz.rule({ bundleId: "com.apple.ActivityMonitor", height: 1/3 });
oz.rule({ app: "Some App", ignore: true });                // leave it alone entirely

oz.on("windowCreated", function (w) { oz.log("new:", w.app, w.title); });
oz.set({ doubleTap: { action: function () { oz.appExpose(); } } });
```

**`oz` API:** `set`, `settings()`, `bind`, `rule`, `on` (`windowCreated`, `windowFocused`, `windowFloated`, `swipeEnded`, `spaceChanged`, `spaceTilingChanged`, `configLoaded`), `command(name, arg)`, a shortcut function per command (`oz.focusDown()`, `oz.setHeight(0.5)` …), `windows()`, `focusedWindow()`, `exec(cmd)` (in the background), `shell(cmd)` (returns the output), `notify(title, text)`, `log(...)`.

**Commands:** `focusUp/Down/Left/Right/First/Last`, `focusRow(n)`, `moveUp/Down/Left/Right/First/Last`, `slurpIn`, `barfOut`, `joinUp`, `joinDown`, `cycleWidth`, `cycleWidthBack`, `setWidth(ratio)`, `resizeWidth(±ratio)`, `equalizeRow`, `cycleHeight`, `cycleHeightBack`, `setHeight(ratio|pt)`, `resizeHeight(±ratio)`, `toggleFullHeight`, `center`, `alignTop`, `scrollUp(ratio)`, `scrollDown(ratio)`, `scrollBy(pt)`, `scrollToTop`, `scrollToBottom`, `toggleFloat`, `toggleMaximize`, `closeWindow`, `moveToNextScreen`, `retile`, `toggleTiling`, `toggleSpaceTiling`, `editScrollArea`, `reloadConfig`, `missionControl`, `appExpose`, `showDesktop`, `launchpad`.

From the shell (skhd, Raycast, scripts…):

```bash
build/Oz.app/Contents/MacOS/OzWM msg focusDown
build/Oz.app/Contents/MacOS/OzWM msg setHeight 0.5
```

## How it works (mapped to PaperWM)

| PaperWM | Oz |
|---|---|
| Horizontal strip of columns | Vertical strip of **rows** (`Sources/OzCore/Strip.swift`) |
| Width cycling with `window_ratios` | Height cycling with `heights` |
| slurp / barf (add to / remove from a column) | `slurpIn` / `barfOut`, `joinUp` / `joinDown` (panels side by side in a row) |
| A strip per workspace | A strip per (Mission Control Space × display) |
| `user.js` | `~/.config/oz/config.js` |
| Touchpad swipe (GNOME) | Raw trackpad data from `MultitouchSupport.framework` (`Multitouch.swift`, `GestureRecognizer.swift`) |

- Windows are moved and resized through the Accessibility API (AXUIElement); new, closed and focused windows are tracked with AXObserver. Moves are applied off the main thread, one queue per app, keeping only the newest target per window, so a slow app never stalls scrolling. Layout runs once per display frame (CADisplayLink).
- **Sliding off the top.** macOS doesn't let a window go above the menu bar. With `topOverflow: "slide"` (default), a window leaving the top edge is parked off screen and drawn in its place from a capture of its own content, cut at the top edge, so it slides off just like at the bottom. The half-visible window stays visible at rest and is clickable (brings the real window back); with `livePeek` it keeps updating at `livePeekFPS` (12, captured at 1x) so video keeps playing. Captures happen only when a window starts to peek, and the live stream stops after ~2 s without changes, so macOS's purple screen-recording indicator only shows while something is actually being captured. Use `topOverflow: "shrink"` (pinned and shrunk) or `"hide"` to never capture. Windows fully outside the viewport are parked in the bottom-right corner (like AeroSpace).
- **Smooth scrolling** (`smoothScroll`, default on; menu bar › *Smooth Scrolling (Snapshots While Moving)*). While the strip moves (swipes, animations) every window is drawn from a snapshot and the real windows are moved once, when the motion ends, so scrolling stays smooth however slowly apps answer. Content stands still during the motion. Oz keeps a recent picture of the windows on screen at rest so the next swipe has them from its first frame. Turned off, only slow apps are drawn this way (below).
- **Slow apps.** Some apps (e.g. WhatsApp) sometimes take 50–120 ms to apply a move, so their window would trail behind while scrolling. Oz tracks each app's recent worst move time; windows of apps above `slowAppThreshold` (30 ms) are drawn from a capture while the strip moves and the real window is placed once, when the motion ends (`slowAppProxy`).
- **Wallpaper tinting.** macOS tints window backgrounds with the colour of the wallpaper behind them (System Settings › Appearance › *Allow wallpaper tinting in windows*). A window parked off screen loses that tint, so a capture of it would look greyer than the real window. Oz therefore turns this macOS setting off while it runs and restores your previous choice when it quits. Apps that were already open pick the change up when reopened. As a fallback Oz also corrects the tint shift in live captures and cross-fades when handing back to the real window.
- Scrolling doesn't change focus; focus changes when you click a window or use a focus command.

## Known limitations

- `MultitouchSupport` is a private framework; if a future macOS changes it, gestures may stop working (shortcuts keep working). The menu then shows "No trackpad found".
- Apps with a minimum window size (some settings windows) make their row at least that tall.
- Native full-screen windows are not tiled.
- Widths and rows are not saved across restarts of Oz.
- Log: `~/Library/Logs/OzWM.log` (`debug: true` for verbose output). Main-thread hitches are logged as `[stall]` with the code that caused them, slow apps as `[slow]`.
