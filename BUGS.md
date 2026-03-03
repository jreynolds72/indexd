# Bug List

## Open Settings from In-App UI Does Nothing / Can Freeze

- Status: Open
- Severity: High
- Area: `ABSClientMac` toolbar menu (`Settings` menu in app UI)
- First observed: 2026-03-02

### Symptoms

- Clicking `Open Settings...` in the in-app top-right `Settings` menu does not open settings.
- Clicking `Configure Shortcuts in Settings...` in the same menu does not open settings.
- In some runs, app becomes unresponsive after clicking these actions.
- macOS app menu path works:
  - `ABSClientMac` -> `Settings...` opens correctly.

### Crash Evidence (user report)

- Exception: `NSInvalidArgumentException`
- Reason: `-[(dynamic class) showSettingsWindow:]: unrecognized selector sent to instance`
- Stack points to:
  - `ContentView.openSettingsWindow(tab:)`
  - `ContentView.swift:2318`

### Repro Steps

1. Launch app.
2. Open top-right in-app `Settings` menu.
3. Click `Open Settings...` or `Configure Shortcuts in Settings...`.
4. Observe no window opens and/or app UI stalls.

### Expected

- In-app settings actions open the same Settings window as macOS app menu.
- `Configure Shortcuts in Settings...` should open Settings focused on `Shortcuts`.

### Notes

- Native macOS menu path currently remains usable workaround.

## Now Playing Window Resize Prioritizes Album Art Shrink Over Chapter List

- Status: Open
- Severity: Medium
- Area: `ABSClientMac` now-playing right panel layout/resizing
- First observed: 2026-03-02

### Symptoms

- During window resize (making the window smaller), album art shrinks before chapter list area is reduced.
- Desired behavior was previously defined as:
  - chapter list should shrink first on general window resize
  - album art should only shrink when user explicitly resizes chapter list via drag handle

### Repro Steps

1. Open now-playing panel on the right.
2. Ensure chapter list is visible.
3. Resize the app window narrower/shorter.
4. Observe cover art scaling down before chapter list contraction.

### Expected

- On normal window resize, chapter list absorbs size changes first.
- Album art size should remain stable unless chapter list is explicitly user-resized.

### Notes

- User explicitly asked to keep this on the bug list for later revisit.
