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
   - **three-finger double tap → Mission Control** (what F3 does)
   - Mission Control also stays on four fingers up and F3; App Exposé on four fingers down
   - to undo: menu bar › *Trackpad: Restore macOS Gestures* (or `scripts/trackpad-gestures.sh restore`)

   If it doesn't take effect right away, set System Settings › Trackpad › More Gestures › Mission Control to **"Swipe Up with Four Fingers"** (same thing).
3. **Screen Recording** (optional): needed for windows to slide off the top edge (see below). Without it Oz shrinks them instead.

> **Development note:** with an ad-hoc signature every build changes the code signature and macOS drops the Accessibility permission. Run `./scripts/create-signing-cert.sh` once: it adds a self-signed "Oz Local Signing" identity to your login keychain, `make app` uses it automatically and the permissions survive rebuilds (`SIGN_ID=...` for another identity).

The ▤ menu bar icon: toggle tiling, retile, edit/reload the config, open the log, trackpad setup, quit. When Oz quits it brings every window it hid back on screen.

## Widths and rows

- **Narrow a window with the mouse.** If it is alone in its row, the space beside it stays empty.
- If adjacent rows (the one below first, then the one above) hold windows **narrow enough** to fit in that space, they join the row when you let go, and the row's windows fill it while keeping their width ratios. Full-width windows are never pulled in.
- The same from the keyboard: in a single-window row `cycleWidth` (`⌃⌥ w`) cycles the share 1/3 → 1/2 → 2/3 → full, `resizeWidth` (`⌃⌥ , / .`) narrows/widens in steps, `equalizeRow` (`⌃⌥ =`) goes back to full width.
- While you resize a window, its neighbours make room live.

## Gestures

| Gesture | Action |
|---|---|
| Three fingers up/down | Scroll the strip freely; on release it glides with your speed and settles on a window edge (top or bottom) when it ends near one. Focus doesn't change (`swipe.focus: true` to focus the top window). `snap: "always"` for panel-by-panel scrolling. |
| Three-finger double tap | Mission Control (configurable) |
| Three fingers left/right | Left to macOS (switching Spaces) |

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
| `⌃⌥ c` / `⌃⌥ t` | center / align to top | | `⌃⌥ u` / `⌃⌥ d` | scroll half a screen |
| `⌃⌥⇧ pageup/pagedown` | start / end of the strip | | `⌃⌥ esc` | toggle floating |
| `⌃⌥ return` | new Terminal | | `⌃⌥⇧ q` | close the window |
| `⌃⌥ n` | move to the next screen | | `⌃⌥ m` / `⌃⌥⇧ m` | Mission Control / App Exposé |
| `⌃⌥⇧ t` | toggle tiling | | `⌃⌥⇧ c` | reload the config |
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

**`oz` API:** `set`, `settings()`, `bind`, `rule`, `on` (`windowCreated`, `windowFocused`, `swipeEnded`, `spaceChanged`, `configLoaded`), `command(name, arg)`, a shortcut function per command (`oz.focusDown()`, `oz.setHeight(0.5)` …), `windows()`, `focusedWindow()`, `exec(cmd)` (in the background), `shell(cmd)` (returns the output), `notify(title, text)`, `log(...)`.

**Commands:** `focusUp/Down/Left/Right/First/Last`, `focusRow(n)`, `moveUp/Down/Left/Right/First/Last`, `slurpIn`, `barfOut`, `joinUp`, `joinDown`, `cycleWidth`, `cycleWidthBack`, `setWidth(ratio)`, `resizeWidth(±ratio)`, `equalizeRow`, `cycleHeight`, `cycleHeightBack`, `setHeight(ratio|pt)`, `resizeHeight(±ratio)`, `toggleFullHeight`, `center`, `alignTop`, `scrollUp(ratio)`, `scrollDown(ratio)`, `scrollBy(pt)`, `scrollToTop`, `scrollToBottom`, `toggleFloat`, `closeWindow`, `moveToNextScreen`, `retile`, `toggleTiling`, `reloadConfig`, `missionControl`, `appExpose`, `showDesktop`, `launchpad`.

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
- **Sliding off the top.** macOS doesn't let a window go above the menu bar. With `topOverflow: "slide"` (default), a window leaving the top edge is parked off screen and drawn in its place from a capture of its own content, cut at the top edge, so it slides off just like at the bottom. The half-visible window stays visible at rest and is clickable (brings the real window back); with `livePeek` it keeps updating at `livePeekFPS` (24) so video keeps playing. Captures happen only when a window starts to peek, and the live stream stops after ~2 s without changes, so macOS's purple screen-recording indicator only shows while something is actually being captured. Use `topOverflow: "shrink"` (pinned and shrunk) or `"hide"` to never capture. Windows fully outside the viewport are parked in the bottom-right corner (like AeroSpace).
- **Slow apps.** Some apps (e.g. WhatsApp) sometimes take 50–120 ms to apply a move, so their window would trail behind while scrolling. Oz tracks each app's recent worst move time; windows of apps above `slowAppThreshold` (30 ms) are drawn from a capture while the strip moves and the real window is placed once, when the motion ends (`slowAppProxy`).
- **Wallpaper tinting.** macOS tints window backgrounds with the colour of the wallpaper behind them (System Settings › Appearance › *Allow wallpaper tinting in windows*). A window parked off screen loses that tint, so a capture of it would look greyer than the real window. Oz therefore turns this macOS setting off while it runs and restores your previous choice when it quits. Apps that were already open pick the change up when reopened. As a fallback Oz also corrects the tint shift in live captures and cross-fades when handing back to the real window.
- Scrolling doesn't change focus; focus changes when you click a window or use a focus command.

## Known limitations

- `MultitouchSupport` is a private framework; if a future macOS changes it, gestures may stop working (shortcuts keep working). The menu then shows "No trackpad found".
- Apps with a minimum window size (some settings windows) make their row at least that tall.
- Native full-screen windows are not tiled.
- Widths and rows are not saved across restarts of Oz.
- Log: `~/Library/Logs/OzWM.log` (`debug: true` for verbose output). Main-thread hitches are logged as `[stall]` with the code that caused them, slow apps as `[slow]`.
