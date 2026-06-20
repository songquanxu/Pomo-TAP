# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pomo-TAP (捏捏番茄) is a **watchOS-only** Pomodoro timer built with SwiftUI (MVVM). There is no iOS companion app. The app ships with a WidgetKit extension that provides **6 widgets + 1 Control Center control** (all registered in the single `@main PomoTAPWidgetBundle`).

- **Build truth (from `Pomo TAP.xcodeproj/project.pbxproj`):** `WATCHOS_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 6.0` (full Swift 6 language mode → strict concurrency `complete`). The target was raised from 11.6 to 26.0 to adopt the watchOS-26 `ControlWidget` and Smart-Stack `RelevanceConfiguration` APIs (both are `@available(watchOS 26.0)` and would not compile below it). The whole app target is uniformly `@MainActor`; system delegate callbacks are `nonisolated` and hop back via `Task { @MainActor in }`; `BackgroundSessionManager` uses `@preconcurrency import WatchKit/Dispatch` for the non-Sendable `WKExtendedRuntimeSession` it passes through delegate methods (safe because that object is only ever touched on the MainActor). Both schemes build with **zero warnings** under Swift 6. Use these as ground truth. The codebase follows current watchOS HIG and prefers modern APIs (WidgetKit over ClockKit, `DispatchSourceTimer`, system `Gauge`/`ProgressView`). When using an API newer than training, verify signatures against the installed SDK's `.swiftinterface` — don't write WWDC framework API from memory.
- **Localization:** zh-Hans (dev region), zh-Hant, en, ja, ko. All user-facing strings go through `NSLocalizedString()` and live in `Localizable.xcstrings` (one per target).
- **No test target exists.** No XCTest/Swift Testing files are present.
- **Bundle IDs:** app `songquan.Pomo-TAP.watchkitapp`, widget extension `songquan.Pomo-TAP.watchkitapp.PomoTAPComplication`. App Group: `group.songquan.Pomo-TAP`.

## Build Commands

This is a watchOS app; meaningful run/testing requires Xcode + a paired Watch simulator or device. Command-line builds verify compilation.

**Build env:** the default `xcode-select -p` here points at `/Library/Developer/CommandLineTools`, which **cannot** build the project (`xcodebuild requires Xcode`). Prefix builds with the full Xcode: `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. For a compile-only check without signing, append `-destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO`.

```bash
# Build the watch app (Debug) — DEVELOPER_DIR must point at a full Xcode, not CommandLineTools
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "Pomo TAP Watch App" -configuration Debug build

# Build the widget extension
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "PomoTAPComplicationExtension" -configuration Debug build

# Clean
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "Pomo TAP Watch App" clean
```

The two shared schemes are `Pomo TAP Watch App` and `PomoTAPComplicationExtension`.

## Architecture

The app is a constellation of single-responsibility `@MainActor` managers coordinated by `TimerModel`. Everything timer-related is `@MainActor`; state flows from child managers up to `TimerModel` via Combine `assign(to:)`, then to the views.

```
View (ContentView) ←→ TimerModel (@StateObject, single source of truth for UI)
                          │ owns + binds via Combine:
                          ├─ TimerCore .................. countdown/count-up engine (DispatchSourceTimer)
                          ├─ TimerStateManager .......... phases, cycle, completion status, persistence
                          ├─ BackgroundSessionManager ... WKExtendedRuntimeSession (ref-counted)
                          ├─ NotificationManager ........ UNUserNotificationCenter (+ NotificationRepeatManager)
                          └─ SharedTimerStatePublisher .. writes App Group state, throttled Widget reloads

DeepLinkManager (owned by Pomo_TAPApp) → calls TimerModel for pomoTAP:// URLs
```

### Source layout
- `Pomo TAP Watch App/` — main app target (timer logic, managers, UI).
- `PomoTAPComplication/` — widget extension target (widgets, shared data types, widget-side adapters).
- Code-level details (file lists, fonts, colors) are discoverable; the sections below cover only what spans multiple files.

### The canonical phase-transition path

`TimerModel.prepareNextPhase(source:shouldSkip:)` is the **single source of truth for advancing phases**. Every transition (natural completion, skip, notification response, deep link, flow stop, reset) routes through it via the `PhaseTransitionSource` enum. It atomically: clears paused state → conditionally cancels notifications (`shouldClearNotifications(for:)`) → stops the background session → runs the transition animation → updates `TimerStateManager` → syncs UI → persists → publishes shared state.

When changing transition behavior, modify `prepareNextPhase` / `shouldClearNotifications`, not the call sites. (The legacy `moveToNextPhase(autoStart:skip:)` wrapper has been removed — `prepareNextPhase(source:shouldSkip:)` is the only entry point.)

**Auto-advance vs. auto-start** are independent decisions:
- Natural countdown completion → auto-advance, **do not** auto-start (user starts via the system notification action or the start button).
- Skip, deep-link quick-start, and flow-mode stop → auto-advance **and** auto-start (the user's action already signals intent).

### TimerCore (timer engine)
- `DispatchSourceTimer` on the main queue, 1s interval. Time is derived from wall-clock `endTime`/`startTime` (`ceil(endTime - now)`), so sleep/wake and AOD throttling never desync the countdown.
- Two modes: normal countdown and flow count-up (`isInFlowCountUp`, `infiniteElapsedTime`). `enterFlowCountUp()` / `exitFlowCountUp()` switch modes; `clearPausedState()` prevents a stale `pausedRemainingTime` from leaking into the next phase.
- Callbacks to `TimerModel`: `onPhaseCompleted` (fires at 0) and `onPeriodicUpdate` (every 60s, drives Widget sync).
- **AOD throttling rule:** completion detection and the final-5s haptic run *every tick regardless of AOD*; throttling only skips the `@Published` time assignment (the UI-visible value). In AOD: countdown >60s remaining publishes only on minute boundaries (~96% fewer UI updates); ≤60s publishes every second. `syncTimerStateFromSystemTime()` (handles both countdown **and** flow count-up) is called by `ContentView` when leaving AOD to correct any drift. Don't move the completion/haptic checks behind the throttle — that historically caused phases to not complete in AOD.
- Final-5-seconds haptic (`.click`) is gated by `enableFinalCountdownHaptics`.

### Flow mode (心流模式 / "heart flow")
Two-level state: `isInfiniteMode` (persisted user toggle) vs. `isInFlowCountUp` (runtime active state). Flow mode only affects **Work** phases (`TimerStateManager.isCurrentPhaseWorkPhase()`, matched by phase `name == "Work"`). When a Work countdown hits 0 with the toggle on, it enters count-up instead of advancing — no notification. UI conditionals (rainbow ring, golden time, ∞ indicator, Stop button) key off `isInFlowCountUp`, never `isInfiniteMode`. Toggling the setting off mid-count-up immediately stops and advances (observer in `setupBindings()`).

### Notifications
- Single, system-notification-driven model (no in-app completion dialog). Phase-completion notifications are **pre-scheduled** in `startTimer()` via `UNTimeIntervalNotificationTrigger` (battery-optimized; the app need not poll). **Pass durations in seconds, never minutes** — a historical double-conversion bug. Not scheduled while `isInFlowCountUp`.
- Both notification paths set `interruptionLevel = .timeSensitive`; this **requires the `com.apple.developer.usernotifications.time-sensitive` entitlement** (in the app target's `.entitlements`) — without it the system silently downgrades to `.active`. (Automatic signing registers the capability on the App ID at first device build.)
- `willPresent` returns `[.list, .sound]` (watchOS 10+) so notifications show in foreground *and* background — one unified path.
- Action `START_NEXT_PHASE` (category `PHASE_COMPLETED`) → `TimerModel.handleNotificationResponse(scheduledPhaseIndex:)`. Each scheduled notification (main **and** the 3 repeats) carries a **phase stamp** in `userInfo["scheduledPhaseIndex"]` — the index of the phase that was counting down when it was scheduled. The handler advances **only** when the stamped phase is still current; if the phase already auto-advanced it just starts; if the stamp no longer matches the current phase (a stale notification tapped after reset/skip/quick-start) it starts the current phase **without** advancing. This replaced the ambiguous `remainingTime == totalTime` heuristic (also true right after a reset), which could wrongly skip a phase. A nil stamp (legacy payloads) falls back to the old heuristic.
- The `PHASE_COMPLETED` category is registered **unconditionally in `NotificationManager.init`** (every launch), *not* gated behind the permission request — categories are not persisted across launches, so gating registration on `.notDetermined` would silently drop the action button on every relaunch after the first.
- `NotificationRepeatManager` schedules 3 progressive reminders at +1/+3/+6 min after the main notification (prefix `PomoTAP_Repeat_`), gated by `enableRepeatNotifications`. It cancels *only* repeat IDs so the main notification survives; user response cancels them.
- Cancel notifications on every stop path (pause/reset/skip/flow-stop). watchOS has **no custom notification sounds** and **no AudioToolbox** — haptics only, via `WKInterfaceDevice.current().play(_:)`.

### BackgroundSessionManager
`WKExtendedRuntimeSession` with **reference counting** (multiple start/stop calls nest). Key invariants: assign the strong reference *before* calling `start()`; fully `invalidate()` + clear any existing session before creating a new one; cleanup is synchronous; delegate methods **do not auto-restart** (that caused infinite loops). When the app backgrounds with the timer stopped, the session is torn down so the watch can enter AOD.

## Widget / App-Group data flow

Widgets never touch `TimerModel`. State crosses the target boundary through the App Group:

1. **Write:** `SharedTimerStatePublisher.updateSharedState(from:)` builds a `SharedTimerState` (defined in `PomoTAPComplication/SharedTypes.swift`) and JSON-encodes it to `UserDefaults(suiteName: "group.songquan.Pomo-TAP")` under key `"TimerState"`.
2. **Throttle:** `shouldRefreshWidgets(oldState:newState:)` calls `WidgetCenter.shared.reloadAllTimelines()` (and `ControlCenter.shared.reloadControls(ofKind:)` for the Start/Pause control) **only on key changes** (phase index, running, name, cycles, skip, completion statuses, display mode/type) or a ≥60s time delta — never every second.
3. **Project forward:** `SharedTimerState` carries `phaseEndDate` / `flowStartDate` plus `displayMode` and `currentPhaseType`. Widgets render live time directly from these dates via system self-updating views — `Text(_:style:.timer)` for digits and `ProgressView(timerInterval:countsDown:)` for the corner arc — so the display keeps ticking between timeline entries instead of freezing on a snapshot. Providers (`loadCurrentEntry` / NextPhase `loadEntry`) also **re-derive remaining/elapsed from these dates against the real `Date()`** and anchor the first entry at `now`, so a stale `lastUpdateTime` never offsets the countdown.
4. **Read/adapt:** `WidgetStateAdapter` converts `SharedTimerState` into `ComplicationDisplayState` (the single display model — used by the primary complication, the Next Phase widget, *and* the Smart Focus relevance card) for the views.

`SharedTimerState` decodes defensively (`decodeIfPresent` with fallbacks) so older encoded payloads still load — preserve that when adding fields.

### Widgets & Control (bundle `PomoTAPWidgetBundle`, the single `@main`)
**6 widgets + 1 control.** Five `StaticConfiguration` widgets: the **primary timer complication** (`PomoTAPComplication`, 4 accessory families), **Quick Start Work**, **Quick Start Break**, **Stats**, **Next Phase**. Plus **Smart Focus** (`SmartFocusWidget`, watchOS-26 `RelevanceConfiguration`) and the **Start/Pause** control (`StartPauseControlWidget`, a `ControlWidget`). (A Smart Stack and a Cycle Progress widget existed but were unregistered dead code and have been removed — don't resurrect them without re-adding to the bundle.) Progress indicators **must use system `Gauge`** (`.accessoryCircular`) / `ProgressView` / `.widgetLabel` — never hand-drawn `Circle().stroke()` (you can't match system ring thickness and lose vibrant rendering). Apply `.widgetAccentable()` to icons and `.containerBackground(.clear, for: .widget)`.

#### Smart Focus — Smart Stack relevance (`RelevanceConfiguration`, watchOS 26)
`SmartFocusWidget` (`PomoTAPFocusRelevanceWidget.swift`) uses `RelevanceConfiguration` (watchOS-only, 26.0+) so the rectangular card **auto-surfaces in the Smart Stack** near phase boundaries. Its `RelevanceEntriesProvider.relevance()` reads `SharedTimerState` and returns `WidgetRelevance` attributes from `RelevantContext.date(interval:kind:)` — `.scheduled` for the last 5 min of a countdown (time-sensitive), `.default` for the whole running window (and for flow). It requires a `WidgetConfigurationIntent` (`SmartFocusConfigurationIntent`, no params). The provider returns a **single entry** (no timeline); live ticking comes from `Text(_:style:.timer)`. `RelevantContext` lives in **`RelevanceKit`** (`import RelevanceKit`); the `date(from:to:)` form is **deprecated at 26** — use `date(interval:kind:)`.

#### Start/Pause — Control Center control (`ControlWidget`, watchOS 26)
`StartPauseControlWidget` (`PomoTAPStartPauseControl.swift`) is a `ControlWidget` (`StaticControlConfiguration` + `ControlValueProvider` reading `timerRunning`, a `ControlWidgetToggle`). The timer engine (DispatchSourceTimer + WKExtendedRuntimeSession + notifications) lives in the **app** process, so the control can't drive it from the extension. `StartPauseTimerControlIntent` (a `SetValueIntent`, `openAppWhenRun = true`) writes `pomoTAP://toggle` to the App Group via **`ControlActionBridge`** (in `SharedTypes.swift`, shared by both targets), opens the app, and `Pomo_TAPApp` drains the pending action on `scenePhase == .active` (and on cold-launch `.task`) through the existing idempotent `DeepLinkManager`. `SharedTimerStatePublisher` calls `ControlCenter.shared.reloadControls(ofKind:)` alongside the widget reload so the toggle reflects running state. **Do not** mutate the timer from the control's `perform()` directly.

### Deep links (`pomoTAP://`)
`DeepLinkManager` is the unified, **idempotent** entry point (`onOpenURL` → `handleDeepLink`). It dedupes identical actions within a 1s window and tracks success/duplicate/failure stats. Actions: `open`, `startWork`, `startBreak`, `startLongBreak`, `toggle`, `skipPhase`. Widgets trigger these via `.widgetURL` / `Link` (the supported way to open the host app from a widget) — e.g. the Quick Start widgets link to `pomoTAP://startWork`, and the rectangular complication's `widgetURL` is `pomoTAP://toggle`. The Control Center control reaches the same router via AppIntents `openAppWhenRun = true` + an App Group pending action (`ControlActionBridge`), **not** custom-scheme URL routing. Do **not** use `openSystemURL(...)` from an AppIntent in the widget process to route a `pomoTAP://` URL — it does not reliably reach the app (this was a real bug; the broken `TimerIntents.swift` was removed).

## Conventions & gotchas

- **`@MainActor` everywhere** for timer/state/manager classes. When calling async work from sync contexts, wrap in `Task { await ... }`. Never `await` synchronous properties (`@Published`, `WKApplication.shared().applicationState`). Avoid capturing non-Sendable types (e.g. `DispatchWorkItem`) in `@Sendable` closures — prefer `Task.sleep`.
- **`WKExtension` → `WKApplication`:** `WKExtension` was renamed to `WKApplication` at watchOS 9.2; the codebase uses `WKApplication.shared()` (e.g. `openSystemURL`). Don't reintroduce `WKExtension`.
- **After any state mutation:** call `stateManager.saveState()` and `sharedStatePublisher.updateSharedState(from:)` so persistence and widgets stay consistent.
- **`completedCycles` is never reset** by `resetCycle()` — the medal/history count is intentionally preserved (orange = clean cycle, green = a phase was skipped).
- **Widget view `@available` must match the deployment target.** Stale `@available(watchOS 11.5, *)`-style annotations have silently prevented widgets from rendering. Don't add version gates unless an API genuinely requires it — the floor is now 26.0, so `ControlWidget` / `RelevanceConfiguration` / `ControlCenter` (all `@available(watchOS 26.0)`) need **no** gating.
- **Cross-target types:** types the main app needs (e.g. `NotificationEvent`) live in the **main app target**, not the widget extension — the app can't import from the extension. Only runtime data structures (`SharedTimerState`, etc.) belong in the shared `SharedTypes.swift`.
- **Standard SwiftUI controls get Liquid Glass automatically** — don't add `.glassEffect()` to buttons/toolbars/lists. The main timer's Reset and Start/Pause/Stop buttons are intentional custom circles (`.buttonStyle(.plain)` + `Circle()` backgrounds).
- **Digital Crown time adjustment is NOT implemented** despite older docs describing it. `TabView(.page)` reserves the Crown for paging; any future Crown use needs `@FocusState`-gated `.focusable()`.
- **Xcode 16+ index corruption:** if the IDE reports "Cannot find type X" but `xcodebuild` succeeds and the file exists, it's `PBXFileSystemSynchronizedRootGroup` index desync — clear `~/Library/Developer/Xcode/DerivedData/Pomo_TAP-*` and clean.

## Working agreement

Commit significant design changes and bug fixes with messages that explain rationale and impact. Per the project's `.cursorrules` style: prefer the latest Swift/SwiftUI features, favor readability, implement features completely (no TODO/placeholder stubs), and keep prose concise.
