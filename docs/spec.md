# MagicTrack — Implementation Spec v1

Oct 21, 2026 · @Hammad

This spec defines v1 of MagicTrack, a background menu-bar app that turns the trackpad into a numpad with brightness and volume sliders, shown on a view-only overlay. Design rationale lives in Doc.

## 1. Scope

v1 ships a single-user, notarized menu-bar app for Apple Silicon and Intel Macs with a Force Touch trackpad or Magic Trackpad.

**Goals**

1. A trigger gesture on the trackpad opens a view-only overlay from any app, including full-screen apps.
2. While open, clicks on numpad zones type keypad keys into the previously focused app.
3. Vertical slides on two edge strips adjust brightness and volume.
4. The cursor and the app underneath receive no trackpad input while the overlay is open.
5. Closing is always possible: same gesture, Esc, or idle timeout.

**Non-goals for v1**

- Mac App Store distribution (blocked by private APIs).
- Tap-to-type mode (click only).
- Custom layouts beyond 4×4 and 4×5 grids.
- DDC/CI brightness for external monitors.
- Localization beyond English.

## 2. Platform, build and distribution

Target macOS 13 Ventura and later, built with Swift 5.9+ in Xcode as a non-sandboxed, notarized app.

| Item | Value |
| --- | --- |
| Minimum OS | macOS 13.0 (needed for `SMAppService` login items) |
| Architectures | Universal (arm64 + x86\_64) |
| UI frameworks | AppKit for the panel, event tap and menu bar; SwiftUI hosted in `NSHostingView` for the overlay |
| Info.plist | `LSUIElement = YES` (no Dock icon), `NSAccessibilityUsageDescription` text |
| Sandbox | Off (`com.apple.security.app-sandbox` absent) |
| Hardened runtime | On; add `com.apple.security.cs.disable-library-validation` only if `dlopen` of private frameworks fails under it |
| Private frameworks | Loaded at runtime with `dlopen` + `dlsym`, not linked, so a missing symbol degrades a feature instead of crashing at launch |
| Signing | Developer ID Application certificate |
| Notarization | `xcrun notarytool submit --wait`, then `xcrun stapler staple` |
| Packaging | Signed `.dmg`; Sparkle for updates in a later version |
| Bundle id | `com.hammad.magictrack` (prefix is a placeholder); display name MagicTrack |

## 3. Permissions and onboarding

The app requires Accessibility permission; without it, nothing beyond the menu bar item runs.

| Permission | Needed for | Check | Request |
| --- | --- | --- | --- |
| Accessibility | Active event tap (dropping mouse events), posting keystrokes | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true`, plus a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| Input Monitoring | Possibly prompted by the keyboard tap used for Esc | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()` |

Onboarding flow:

1. On first launch, show a small welcome window explaining what each permission is for.
2. Request Accessibility, then poll `AXIsProcessTrusted()` every 1 s while the window is open.
3. When granted, create the event tap and start the touch engine, then close the window.
4. Show a one-time tip: "Tap with five fingers to open the numpad."

Runtime rule: re-check `AXIsProcessTrusted()` every 5 s while idle. If it becomes false, tear down the event tap, close the overlay, and set the menu bar icon to a warning state with a "Grant Accessibility…" item.

## 4. Modules, core types and threading

The code splits into eight folders; everything except `Touch` and `Actions` is pure Swift that can be unit-tested without hardware.

| Folder | Files | Responsibility |
| --- | --- | --- |
| App | `AppDelegate`, `MenuBarController` | Lifecycle, menu bar item, wiring |
| Permissions | `PermissionManager`, `OnboardingWindow` | Checks, prompts, polling |
| Touch | `MTBridge.h`, `MultitouchLoader`, `TouchEngine` | Private framework, device list, contact frames |
| Gesture | `TriggerDetector`, `GestureStateMachine` | Trigger detection, mode state |
| Zones | `Layout`, `ZoneMapper`, `SliderTracker` | Geometry, hit testing, slider deltas |
| Input | `EventTapController`, `CursorLock` | Swallowing input, click events |
| Actions | `ActionDispatcher`, `KeyEmitter`, `VolumeController`, `BrightnessController`, `Haptics` | System side effects |
| Overlay | `OverlayPanel`, `OverlayModel`, `OverlayView` | View-only UI |

Core types:

```swift
enum ContactPhase { case began, moved, stationary, ended }

struct Contact: Equatable {
    let id: Int            // stable per finger until lift
    let x: Double, y: Double   // normalized 0...1, y up
    let size: Double       // contact area, for palm rejection
    let phase: ContactPhase
}

struct TouchFrame { let contacts: [Contact]; let timestamp: TimeInterval; let deviceID: Int }

enum NumKey: CaseIterable { case k0, k1, k2, k3, k4, k5, k6, k7, k8, k9,
                            decimal, enter, plus, minus, multiply, divide }
enum SliderKind { case brightness, volume }
enum Zone: Equatable { case key(NumKey), slider(SliderKind), dead, outside }

enum Action { case keyDown(NumKey), keyUp(NumKey), adjust(SliderKind, delta: Double) }

protocol TouchSource: AnyObject { var onFrame: ((TouchFrame) -> Void)? { get set } }
protocol ActionSink { func perform(_ action: Action) }
```

Threading model:

- **Touch callback thread** (owned by MultitouchSupport): copy contacts into a `TouchFrame` and hop onto the engine queue. Do no other work here.
- **Engine queue** (serial `DispatchQueue`, user-interactive QoS): state machine, zone mapping, slider tracking and action dispatch. `CGEventPost` and CoreAudio calls are safe here.
- **Event tap thread** (dedicated `Thread` with its own run loop): keeps the tap responsive when the main thread is busy. Reads the latest primary contact from a snapshot guarded by `OSAllocatedUnfairLock`, then enqueues a click onto the engine queue.
- **Main thread:** overlay rendering only, fed by `OverlayModel` updates throttled to 60 Hz.

## 5. Touch layer

`TouchEngine` loads MultitouchSupport at runtime, registers a contact callback on every trackpad, and emits `TouchFrame`s. The declarations below come from community reverse engineering, not Apple headers, so verify the struct layout on the target macOS before relying on it.

```c
// MTBridge.h
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t  frame;
    double   timestamp;
    int32_t  identifier;   // stable per finger
    int32_t  state;        // contact state, see below
    int32_t  fingerID;
    int32_t  handID;
    MTVector normalized;   // 0...1, y up
    float    size;
    int32_t  zero1;
    float    angle, majorAxis, minorAxis;
    MTVector absolute;     // millimetres
    int32_t  zero2[2];
    float    density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int32_t count, double timestamp, int32_t frame);

// Resolved with dlsym from
// /System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport
CFArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTFrameCallback);
void MTUnregisterContactFrameCallback(MTDeviceRef, MTFrameCallback);
void MTDeviceStart(MTDeviceRef, int32_t mode);   // mode 0
void MTDeviceStop(MTDeviceRef);
```

Contact handling rules:

- Treat states 3–5 (hovering, touch made, touching) as down and 6–7 (breaking, lingering) as lifting; confirm the numbering empirically with a logging spike before building on it.
- Map `identifier` to `Contact.id`, `normalized.position` to x/y, and derive `phase` by diffing against the previous frame.
- The C callback cannot capture Swift context, so it forwards to a single global `TouchEngine.shared` that copies the buffer before returning.
- Read the sensor aspect ratio once per device; if no reliable API exists, default to 1.6:1 and expose a setting.

Device handling:

- Enumerate devices at start, and again on `NSWorkspace.didWakeNotification` and on an IOKit notification for HID multitouch devices, so a Magic Trackpad connected later is picked up.
- Tag each frame with its device so zone mapping uses only the device the trigger came from while the overlay is open.
- If `dlopen` or any symbol lookup fails, disable the feature and show "Trackpad access unavailable on this macOS version" in the menu.

## 6. Gesture state machine

`GestureStateMachine` has four states and runs entirely on the engine queue; only Active changes how the event tap treats input.

&#91;embedded content: gesture state machine · 4 states\]

| Parameter | Default | Purpose |
| --- | --- | --- |
| Arm window | 100 ms | All five contacts must touch down within this span |
| Tap window | 300 ms | All five must lift within this time of the first touch |
| Max movement | 0.03 normalized | Per contact, from its start point; larger means pinch or swipe |
| Exactly five | 5 contacts | A sixth contact or a palm-sized contact aborts to Idle |
| Idle timeout | 4 s (setting) | Active with no contacts this long closes the overlay |
| Cooldown | 400 ms | Prevents the closing tap from immediately reopening |

Entering Active: snapshot the triggering device id, enable swallowing in the event tap, lock the cursor, show the overlay, read current brightness and volume. Leaving Active (any path): reverse all of these in a single `deactivate()` that is safe to call twice.

While Active, a second five-finger tap is detected with the same rules and closes the overlay. Clicks and slides never count toward the trigger because they involve fewer than five contacts.

## 7. Zone layout and hit testing

All geometry is in normalized trackpad coordinates (x right, y up, 0...1) and lives in one `Layout` value so the overlay and the mapper draw from the same numbers.

| Region | x range | y range | Notes |
| --- | --- | --- | --- |
| Numpad grid | 0.03 – 0.80 | 0.04 – 0.96 | 4 columns × 4 rows, 0.015 gap |
| Brightness strip | 0.83 – 0.905 | 0.04 – 0.96 | Mirrored to the left edge if `sliderSide = left` |
| Volume strip | 0.915 – 0.99 | 0.04 – 0.96 | Outermost strip |
| Key dead zone | 0.01 inset on each side of every key | — | Clicks here do nothing |

Grid order, top row first (top row = highest y):

| Col 1 | Col 2 | Col 3 | Col 4 |
| --- | --- | --- | --- |
| 7 | 8 | 9 | ÷ |
| 4 | 5 | 6 | × |
| 1 | 2 | 3 | − |
| 0 | . | Enter | + |

The 4×5 variant adds a top row of Clear, =, and two spare cells, and makes Enter span rows 4–5 in column 4.

Hit testing (`ZoneMapper.zone(at:) -> Zone`):

1. Outside every region → `.outside`.
2. Inside a slider strip → `.slider(kind)`.
3. Inside a key's inset rect → `.key(k)`; inside the key's full rect but not the inset → `.dead`.

Primary contact: the most recent contact in phase `began`/`moved`/`stationary` whose `size` is below the palm threshold (start at 1.5× the median finger size, tuned in testing). Clicks and the overlay highlight use only the primary contact.

Slider tracking (`SliderTracker`):

- A contact that begins inside a strip is captured by that strip until it lifts, even if it drifts out sideways.
- Each frame, `delta = (y − lastY) × sensitivity`, where sensitivity 1.0 means a full strip length changes the value by 100%. Finger up increases, finger down decreases.
- Accumulate deltas and emit `adjust` only when the accumulated change reaches 1/64 (about 1.6%), to avoid flooding CoreAudio and DisplayServices.
- Fire a haptic tick each time the value crosses a 10% boundary, and a stronger one at 0% and 100%.

## 8. Input capture

One active event tap is installed at launch and stays installed; a flag decides whether it passes events through (Idle) or swallows them (Active), so opening the overlay has no setup latency.

Tap creation: `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback:, userInfo:)`, added to the event tap thread's run loop.

| Event | Idle | Active |
| --- | --- | --- |
| `mouseMoved`, `leftMouseDragged`, `rightMouseDragged`, `otherMouseDragged` | Pass | Drop |
| `leftMouseDown` | Pass | Drop; enqueue `click(down)` with the primary contact snapshot |
| `leftMouseUp` | Pass | Drop; enqueue `click(up)` |
| `rightMouseDown/Up`, `otherMouseDown/Up` | Pass | Drop |
| `scrollWheel` | Pass | Drop |
| Gesture events (raw types 18, 19, 20, 29, 30, 31, 32, 34: rotate, begin/end, gesture, magnify, swipe, smart magnify, pressure) | Pass | Drop |
| `keyDown` Esc (keycode 53) | Pass | Drop; close overlay |
| Other `keyDown`/`keyUp` | Pass | Pass |
| `tapDisabledByTimeout`, `tapDisabledByUserInput` | Re-enable with `CGEvent.tapEnable(tap:enable: true)` | Re-enable and close the overlay |

Open issue: Dock-level system gestures (Mission Control, App Exposé, Space switching) may not be blocked by an event tap. Test this early; if they leak through, document it and rely on the five-finger trigger not colliding with them.

Cursor lock (`CursorLock`):

- On activate: `CGAssociateMouseAndMouseCursorPosition(0)` to freeze the pointer, then try `CGDisplayHideCursor(kCGNullDirectDisplay)`.
- A background app's hide request may be ignored by the window server. If so, leave the cursor visible but frozen in v1; a private `CGSSetConnectionProperty` "SetsCursorInBackground" workaround is an optional later spike.
- On deactivate: `CGAssociateMouseAndMouseCursorPosition(1)` and `CGDisplayShowCursor`, always in a `defer` so every exit path restores the cursor.

Fail-safes: any uncaught error in Active state, permission loss, or 30 s of continuous Active state with no touches forces Idle and restores the cursor.

## 9. Actions

`ActionDispatcher` routes each `Action` to one of four controllers; each controller exposes an `isAvailable` flag so the overlay can grey out what doesn't work.

### Key emitter

Post a key down on click down and a key up on click up, using `CGEvent(keyboardEventSource: src, virtualKey: code, keyDown:)` with `flags = .maskNumericPad` and `post(tap: .cghidEventTap)`. Use a `CGEventSource(stateID: .hidSystemState)`. No auto-repeat in v1.

| Key | Constant | Code |
| --- | --- | --- |
| 0 | `kVK_ANSI_Keypad0` | 0x52 |
| 1 | `kVK_ANSI_Keypad1` | 0x53 |
| 2 | `kVK_ANSI_Keypad2` | 0x54 |
| 3 | `kVK_ANSI_Keypad3` | 0x55 |
| 4 | `kVK_ANSI_Keypad4` | 0x56 |
| 5 | `kVK_ANSI_Keypad5` | 0x57 |
| 6 | `kVK_ANSI_Keypad6` | 0x58 |
| 7 | `kVK_ANSI_Keypad7` | 0x59 |
| 8 | `kVK_ANSI_Keypad8` | 0x5B |
| 9 | `kVK_ANSI_Keypad9` | 0x5C |
| . | `kVK_ANSI_KeypadDecimal` | 0x41 |
| × | `kVK_ANSI_KeypadMultiply` | 0x43 |
| + | `kVK_ANSI_KeypadPlus` | 0x45 |
| Clear | `kVK_ANSI_KeypadClear` | 0x47 |
| ÷ | `kVK_ANSI_KeypadDivide` | 0x4B |
| Enter | `kVK_ANSI_KeypadEnter` | 0x4C |
| − | `kVK_ANSI_KeypadMinus` | 0x4E |
| = | `kVK_ANSI_KeypadEquals` | 0x51 |

If `IsSecureEventInputEnabled()` returns true (a password field has focus), synthetic keys are blocked; show "Secure input active" on the overlay instead of failing silently.

### Volume controller

1. Get the default output device with `kAudioHardwarePropertyDefaultOutputDevice`.
2. Read and write `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (output scope, main element) via `AudioObjectGetPropertyData` / `AudioObjectSetPropertyData`, clamped to 0...1.
3. If `AudioObjectIsPropertySettable` is false (some HDMI and USB devices), fall back to media-key events: a `.systemDefined` `NSEvent` with subtype 8 and `data1 = (key << 16) | (0xA << 8)` for down, `0xB` for up, where `NX_KEYTYPE_SOUND_UP = 0`, `NX_KEYTYPE_SOUND_DOWN = 1`.
4. Listen for default-device changes with `AudioObjectAddPropertyListenerBlock` and refresh.

### Brightness controller

- Find built-in displays with `CGDisplayIsBuiltin`.
- `dlsym` `DisplayServicesGetBrightness(CGDirectDisplayID, float *)` and `DisplayServicesSetBrightness(CGDirectDisplayID, float)` from `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`.
- If unavailable, fall back to brightness media keys (`NX_KEYTYPE_BRIGHTNESS_UP = 2`, `NX_KEYTYPE_BRIGHTNESS_DOWN = 3`), which step in fixed increments.
- External displays are not adjusted in v1; the strip shows "Built-in only" when no built-in display is active (clamshell mode).

### Haptics

`NSHapticFeedbackManager.defaultPerformer.perform(_:performanceTime: .now)`: `.generic` on key down, `.alignment` on each 10% slider tick, `.levelChange` at slider ends. Gated by the `hapticsEnabled` setting. Magic Trackpad support varies, so treat haptics as best-effort.

## 10. Overlay UI

The overlay is a borderless, non-activating, click-through panel that mirrors the trackpad layout and never takes focus.

| Property | Value |
| --- | --- |
| Class | `NSPanel` subclass, `canBecomeKey` and `canBecomeMain` return false |
| Style mask | `[.borderless, .nonactivatingPanel]` |
| Level | `.statusBar` (raise to `.screenSaver` if it hides behind full-screen apps) |
| Collection behavior | `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]` |
| Mouse | `ignoresMouseEvents = true` |
| Background | `isOpaque = false`, `backgroundColor = .clear`, content in `NSVisualEffectView` with `.hudWindow` material, 16 pt corner radius |
| Show / hide | `orderFrontRegardless()`; 120 ms fade and 0.96 → 1.0 scale in, 100 ms fade out |
| Size | Width = `overlayScale` × 520 pt (default scale 1.0), height = width ÷ trackpad aspect ratio |
| Placement | Screen containing the cursor at activation, horizontally centred, bottom edge 15% above the visible frame's bottom |

`OverlayModel` (an `ObservableObject` updated on main at up to 60 Hz) publishes:

- `layout: Layout` and `contacts: [Contact]` (positions to draw finger dots).
- `highlightedKey: NumKey?` (key under the primary contact) and `pressedKey: NumKey?` (between click down and up).
- `brightness: Double?`, `volume: Double?` (nil = unavailable, strip greyed).
- `banner: String?` for "Secure input active" or "Built-in only".

Visual states per key: idle (hairline border), hovered (accent border, 12% accent fill), pressed (accent fill 30%, 0.95 scale for 80 ms), dead-zone hover (no highlight). Slider strips show a fill level from the bottom plus the current percentage. Finger dots: 18 pt circles at 40% opacity, the primary contact at 70%. Respect Reduce Motion by dropping scale animations, and Increase Contrast by using solid borders.

## 11. Menu bar and settings

The menu bar item is the only persistent UI; settings live in a small SwiftUI `Settings` window and persist in `UserDefaults`.

Menu items, top to bottom: status line ("Ready", "Needs Accessibility", "Trackpad unavailable"), Enabled toggle, Open Numpad (for testing without the gesture), Settings…, Launch at Login toggle, About, Quit.

| Key | Type | Default | Range / values |
| --- | --- | --- | --- |
| `enabled` | Bool | true | — |
| `trigger` | String | `fiveFingerTap` | `fiveFingerTap`, `cornerDoubleTap`, `cornerHold` |
| `idleTimeout` | Double (s) | 4 | 2 – 15 |
| `sliderSide` | String | `right` | `right`, `left` |
| `gridLayout` | String | `4x4` | `4x4`, `4x5` |
| `sliderSensitivity` | Double | 1.0 | 0.5 – 2.0 |
| `hapticsEnabled` | Bool | true | — |
| `overlayScale` | Double | 1.0 | 0.75 – 1.5 |
| `palmSizeFactor` | Double | 1.5 | 1.2 – 2.5 |
| `launchAtLogin` | Bool | false | Applied via `SMAppService.mainApp.register()` / `unregister()` |

Changing `sliderSide` or `gridLayout` rebuilds the `Layout` value and takes effect the next time the overlay opens.

## 12. Edge cases and failure handling

Every failure must leave the cursor free and the overlay closed; no state may trap the user.

| Situation | Required behavior |
| --- | --- |
| Accessibility revoked while Active | Close overlay, restore cursor, remove tap, show warning in menu |
| Event tap disabled by timeout | Re-enable; if Active, close overlay |
| Secure input enabled | Keys disabled with banner; sliders still work |
| Sleep, screen lock, fast user switch | Close overlay on `NSWorkspace.willSleepNotification` and `com.apple.screenIsLocked` distributed notification; re-enumerate devices on wake |
| Magic Trackpad connects or disconnects | Re-enumerate; if the active device disappears, close overlay |
| Two trackpads touched at once | Only the device that fired the trigger drives the overlay |
| Click with no primary contact | Ignore (no key) |
| Click on dead zone or `.outside` | Ignore, no haptic |
| Finger drifts off a key between down and up | Key up is sent for the key that went down |
| Overlay opened on one screen, cursor frozen on another | Expected; overlay stays where it opened |
| Full-screen app or Stage Manager | Overlay still visible via `.fullScreenAuxiliary` and level |
| Clamshell mode (no built-in display) | Brightness strip greyed with "Built-in only" |
| Audio output not settable | Media-key fallback |
| MultitouchSupport or DisplayServices symbols missing | Disable that feature, keep the rest, explain in menu |
| App crash while Active | Cursor association resets when the process exits; verify this in testing |

## 13. Testing plan

Pure logic is tested with recorded touch data; hardware-dependent parts get a scripted manual checklist.

**Unit tests (XCTest)**

- `ZoneMapper`: every key centre maps to its key, every inset border maps to `.dead`, both strips map correctly for `sliderSide` left and right, and both grid layouts.
- `SliderTracker`: capture persists when the finger drifts out, emission threshold of 1/64, 10% tick boundaries, clamping at 0 and 1.
- `TriggerDetector` and `GestureStateMachine`: replay JSON fixtures of recorded `TouchFrame`s, including true five-finger taps, five-finger pinches, palm rests, four-finger swipes and slow five-finger placements.
- `ActionDispatcher`: with a fake `ActionSink`, key down/up pairing survives finger drift.

**Fixture recorder:** a debug menu item that writes the last 10 s of `TouchFrame`s to `~/Library/Application Support/MagicTrack/recordings/*.json`.

**Manual checklist**

- [ ] Built-in trackpad on a MacBook and a Magic Trackpad on a desktop Mac
- [ ] Keys land in TextEdit, Numbers, Terminal and a browser text field
- [ ] Password field shows the secure-input banner
- [ ] Volume on built-in speakers, AirPods and an HDMI display
- [ ] Brightness on built-in display; clamshell mode greys the strip
- [ ] Full-screen app, multiple Spaces, two displays
- [ ] Cursor never moves and nothing underneath scrolls while Active
- [ ] Mission Control and Space-switch gestures while Active (record whether they leak)
- [ ] Revoke Accessibility while Active; sleep and wake while Active
- [ ] Kill the process while Active and confirm the cursor is free

**Performance budget:** engine queue work under 1 ms per frame, CPU under 1% while Idle, click-to-keystroke latency under 20 ms.

## 14. Milestones and open questions

Build in seven milestones, each ending in something runnable; the first two are throwaway spikes that de-risk the private APIs.

| # | Milestone | Done when |
| --- | --- | --- |
| M1 | Touch spike | A CLI tool prints contact id, x, y, size and state for every finger; state numbering confirmed |
| M2 | Capture spike | An event tap freezes the cursor and drops clicks while a flag is set, and always releases on exit |
| M3 | Mapping core | `Layout`, `ZoneMapper`, `SliderTracker` with unit tests passing; a debug window shows the hit zone live |
| M4 | Actions | Keypad keys type into TextEdit; volume and brightness respond to debug buttons |
| M5 | Overlay | Panel shows finger dots, highlight and press states without stealing focus |
| M6 | Trigger and state machine | Five-finger tap opens, all close paths work, fixture replays pass |
| M7 | Product shell | Onboarding, menu bar, settings, launch at login, notarized DMG |

Open questions:

- Do Dock-level gestures leak through the event tap while Active? (answered in M2)
- Can a background app reliably hide the cursor, or is the private workaround needed? (M2)
- Is the MultitouchSupport struct layout stable on the target macOS version? (M1)
- Final slider side and grid layout after real-hand testing (M5)
- Is a tap-to-type mode worth adding in v1.1?
