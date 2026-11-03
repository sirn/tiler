# Tiler Coding Agent Instructions

## Project overview
Tiler is a scrollable tiling window manager for macOS written in Swift, inspired by Niri. The project is currently at the alpha/daily-driver stage, meaning it is functional for daily use but still has edge cases and bugs being actively ironed out.

## Build & test
Always run the following commands to build and verify the project:
- Build: `swift build`
- Test: `swift test`
- Release + app bundle: `make app` (or `make app SIGN_IDENTITY="..."` for custom codesigning)
- Clean: `make clean`

All unit tests operate on pure data structures, requiring no accessibility (AX), CoreGraphics (CG), or screen access. Running `swift test` is the gating check; all tests must pass before making a commit.

## Architecture constraints
Tiler implements a pure Elm-like architecture (State -> Actions -> Reducer -> Effects -> Shell).
- **The Reducer must remain pure**: The `Reducer.apply(action, to: &state, env)` function is completely pure and must never contain side-effects, I/O, or direct calls to Accessibility (AX) or CoreGraphics (CG) APIs.
- **Side effects**: All state mutations must happen within the Reducer. Any side-effects (such as retiling, moving/focusing windows, or printing logs) must be returned as `Effect` values to be run by the `WindowManager` shell.

## Code style
- Use 2-space indentation.
- Logging: Use `tiler_debug(...)` for diagnostics (only active when the `TILER_DEBUG` environment variable is set) and `tiler_log(...)` for always-on info level logging.
- Commenting: Code comments should explain "why" a particular decision was made, not "how" the code works. Do not write changelog-style comment blocks.
- No backward compatibility shims unless specifically requested by the user.
- Always match the existing style of the file you are editing.

## Debugging with a live instance
Follow this workflow when deploying and testing a live build.

### Launching Tiler
First build the app, then launch it in the background via a terminal multiplexer or background runner (e.g. `terminal-use`) with debug logging enabled:
```sh
swift build
tu run --name tiler --env TILER_DEBUG=1 .build/debug/TilerApp
```

### Viewing logs
Stream logs matching the Tiler subsystem in real time:
```sh
log stream --predicate 'subsystem == "co.cakework.Tiler"' --style compact --info
```

### Safe test apps
To prevent accidental modification of your development environment, only use these safe test apps:
- TextEdit — Standard multi-window application, ideal for testing vertical stacking and basic layout.
- Ghostty — Modern terminal supporting native macOS tabs.
- Finder — Standard file manager, useful for testing native tabs (Cmd+T) and multi-window behavior (Cmd+N).
- Calculator — Small, rigid window useful for testing minimum size constraints and window filtering.

Do NOT launch apps that modify state, system settings, network, or disk contents during your testing loop.

### Simulating user input
Synthetic CoreGraphics events are used to simulate keyboard shortcuts when physical input isn't available.
- Build a helper Swift script that posts `keyDown` and `keyUp` events using `CGEventSource(stateID: .hidSystemState)`.
- **Modifier flags**: `ctrl = .maskControl`, `alt/option = .maskAlternate`, `shift = .maskShift`, `cmd = .maskCommand`.
- **Keycodes**: H=4, J=38, K=40, L=37, T=17, Q=12, F=3, W=13, O=31, S=1, Escape=53, bracketleft=33, bracketright=30, comma=43, period=47, P=35, N=45, 1=18, 2=19, 3=20.
- Example pattern (send Ctrl+Opt+L for focus right):
```swift
let source = CGEventSource(stateID: .hidSystemState)
let down = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: true)
down?.flags = [.maskControl, .maskAlternate]
down?.post(tap: .cghidEventTap)
let up = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: false)
up?.flags = [.maskControl, .maskAlternate]
up?.post(tap: .cghidEventTap)
```

### Accessibility (AX) inspection helper
Write a small Swift script utilizing `CGWindowListCopyWindowInfo` and `AXUIElementCopyAttributeValue` to inspect window roles, subroles, close button presence (`kAXCloseButtonAttribute`), or minimized/fullscreen attributes. This is crucial for diagnosing window tracking failures.

### Testing workflow
1. Ensure a clean build and that all tests pass (`swift build && swift test`).
2. Start Tiler in debug mode via a background runner (e.g. `tu run --name tiler --env TILER_DEBUG=1 .build/debug/TilerApp`).
3. In a separate pane, start `log stream` to observe behaviors in real time.
4. Launch safe test apps (TextEdit, Ghostty, Finder).
5. Exercise your changes: send hotkeys, open/close/minimize windows.
6. Verify output in the log stream (look for `Added`, `tileable=`, `focus:`, `LayoutEngine`, `Parked`).
7. Run the AX inspection helper if a window behaves unexpectedly or fails to tile.
8. Re-run `swift test` and restart Tiler to verify the fix works cleanly.

### Cleanup after testing
Run the following cleanup sequence when finished testing:
```sh
tu kill --name tiler  # or stop via your background runner
pkill -f 'log stream.*co.cakework'
rm -f ~/Library/Application\ Support/tiler/state.json  # Reset state persistence if needed
osascript -e 'tell application "TextEdit" to quit saving no'
osascript -e 'tell application "Ghostty" to quit'
```

## Edge cases to test
Ensure your changes do not break or degrade performance in these critical areas:
- **Native macOS tabs**: Creating (Cmd+T in Finder) and switching tabs (Cmd+Shift+[ / ]) must not create a new column; instead, the background tab swap must be detected.
- **Non-standard windows**: Dialogs, Save sheets (`AXSheet`), Open dialogs (`AXStandardWindow` without a close button), Fonts panel (`AXFloatingWindow`), and Quick Look panels must be ignored.
- **Fullscreen**: Transitioning a window to fullscreen marks it as non-tileable (skipped); exiting fullscreen must restore its previous column width without triggering minimum width absorption.
- **Minimize/deminimize**: Minimized windows must be cleanly reaped; unminimizing them must place them back in the layout.
- **Workspace switching**: Inactive workspaces must park windows off-screen; switching back must restore layouts and preserve state across restarts.
- **Multi-window same PID**: Quick, simultaneous window creation from a single process (e.g., Command+N in TextEdit) must all be tracked correctly.
- **Column operations**: Validate left/right consume/expel operations (boundary conditions should be safe no-ops), toggle tabbed mode, column navigation, reordering, and resizing.
- **Focus reliability**: Navigation actions must target the correct screen even if the user clicks a window on another screen beforehand (relying on `syncFocusedScreenFromAX`).
- **State restore across restarts**: Terminate Tiler, restart it, and verify windows return to their correct persisted workspaces.

## Version control
- Commit messages: imperative mood (e.g. "Add...", "Fix..."), first line <= 72 characters, followed by a blank line and body text wrapped at 72 characters.
- Each commit should represent one logical change. Do not squash, rebase, or abandon commits unless explicitly instructed by the user.

## Common pitfalls
- **Direct AX/CG calls in Reducer**: Never call Accessibility or CoreGraphics APIs within Reducer code.
- **WindowFilter dialog checks**: Checking for `AXStandardWindow` is insufficient. Many save/open dialogs report as standard windows but lack a close button; filter them by asserting the presence of `kAXCloseButtonAttribute`, and accept a chrome-less window only when it implements `AXFullScreen` (Adobe Illustrator).
- **absorbMinWidth fullscreen guard**: When a window enters fullscreen, its width matches the screen. Prevent `absorbMinWidth` from locking column widths by skipping absorption when the observed width meets or exceeds the usable screen width (`observedWidth >= usableWidth`).
- **wasNotTileableLastPass stickiness**: Fullscreen windows may disappear from `CGWindowList` for a few passes during screen transitions. The non-tileable set must remain sticky until the window returns or is fully reaped.
- **Manual lockfile changes**: Do not edit lockfiles. Regenerate via `swift package update`.
- **State file location**: `~/Library/Application Support/tiler/state.json` (not in `.build/`).
- **Config file location**: `~/.config/tiler/config.toml`. Refer to `Resources/config.toml.example` for reference options.

## File layout
- `Sources/TilerApp/`: App entry point, AppDelegate, Status bar menu
- `Sources/TilerCore/`: Core tiling mechanics
  - `WindowManager/`: Main orchestrator loop, AX integration, window stores, and state reconciliation
  - `Layout/`: Geometry, viewport, and screen calculations
  - `Reducer/`: Pure state transitions, action types, and effects definitions
  - `State/`: Workspace, column, window models, and state tree
  - `Config/`: Configuration loader (TOML parsing)
  - `Persistence/`: JSON state serialization
  - `Events/`: Core systems for AX and workspace events
  - `Hotkey/`: Global hotkey registrations via Carbon APIs
- `Tests/TilerCoreTests/`: Pure-data unit tests

## Dependencies
- **TOMLKit**: Tiler's only external dependency, used to parse configuration files.
- **System Frameworks**: AppKit, ApplicationServices (Accessibility), CoreGraphics (CGWindowList), Carbon (Global Hotkeys).
- **Package Manager**: SwiftPM only.