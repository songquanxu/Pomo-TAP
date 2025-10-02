# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pomo-TAP (捏捏番茄) is a watchOS-only Pomodoro timer application built with SwiftUI. The app uses a modular architecture with specialized managers for timer logic, state management, background sessions, and notifications.

**Key Characteristics:**
- watchOS 26+ deployment target (2025)
- Swift 6.0
- SwiftUI MVVM architecture
- No iOS companion app (watch-only)
- Multi-language support: Chinese, English, Japanese, Korean (development region: zh-Hans)
- Widget/Complication extension support

**Development Standards:**
- **MUST use latest watchOS 26/iOS 26 APIs and best practices**
- **Strictly follow Apple official frameworks only**
- **NO deprecated technologies** (e.g., CoreData - use UserDefaults or SwiftData instead)
- When unfamiliar with latest APIs, consult official Apple documentation or search for 2025 resources
- Adhere to watchOS 26 Human Interface Guidelines

## Build Commands

**Build the project:**
```bash
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "Pomo TAP Watch App" -configuration Debug build
```

**Build for Release:**
```bash
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "Pomo TAP Watch App" -configuration Release build
```

**Clean build artifacts:**
```bash
xcodebuild -project "Pomo TAP.xcodeproj" -scheme "Pomo TAP Watch App" clean
```

**Note:** This is a watchOS app and must be built/run using Xcode with a paired Apple Watch simulator or physical device. Command-line builds are limited.

## Architecture Overview

### Core Components

The app follows a modular MVVM architecture with clear separation of concerns:

1. **TimerModel** (`TimerModel.swift`) - Main coordinator marked with `@MainActor`
   - Orchestrates all specialized managers
   - Holds published UI state
   - Acts as the single source of truth for the view layer
   - Uses Combine to bind properties from child managers

2. **TimerCore** (`TimerCore.swift`) - Pure timer logic
   - **`DispatchSourceTimer` for precise countdown/countup** - Preferred over Foundation Timer for accuracy
   - System time synchronization (startTime/endTime) to handle sleep/wake correctly
   - 1-second update interval for battery optimization
   - Manages pause/resume state independently
   - **Dual mode support**: Normal countdown and infinite countup (`isInfiniteMode`)
   - `infiniteElapsedTime` tracks elapsed seconds in infinite mode
   - Phase completion callback (`onPhaseCompleted`) for custom alerts

3. **TimerStateManager** (`TimerStateManager.swift`) - Phase and cycle management
   - 4-phase Pomodoro cycle: 25min Work → 5min Short Break → 25min Work → 15min Long Break
   - UserDefaults persistence for state restoration
   - Tracks completion status and skip behavior
   - Manages phase transitions and cycle completion

4. **BackgroundSessionManager** (`BackgroundSessionManager.swift`) - Extended runtime
   - Uses `WKExtendedRuntimeSession` for background execution
   - Reference counting to handle multiple timer start/stop requests
   - Automatic session restart on expiration
   - Proper cleanup to avoid session leaks

5. **NotificationManager** (`NotificationManager.swift`) - User notifications
   - **Uses `UNUserNotificationCenter` (Apple's standard framework)** - No custom notification system needed
   - Handles permission requests with proper authorization flow
   - Schedules phase completion notifications using `UNTimeIntervalNotificationTrigger`
   - Supports notification actions (start next phase via notification action)
   - Localized notification content for all supported languages
   - Distinguishes foreground/background notification presentation

### State Flow

```
User Action → TimerModel → Specialized Manager(s) → State Update → Combine Binding → View Update
```

All managers are `@MainActor` to ensure thread safety. State synchronization happens via Combine publishers (`$property.assign(to:)`).

### UI Architecture

- **ContentView.swift** - Main timer interface (TabView with timer and settings pages)
  - **TabView Integration**: Uses `.tabViewStyle(.page)` for horizontal pagination between timer and settings
    - Tab 0: Main timer page with countdown/countup display
    - Tab 1: Settings page with configuration options
  - **Layout Pattern**: Uses `.overlay(alignment:)` with padding instead of ZStack + `.position()` for predictable positioning
    - Main content: `timerRingView()` with `.frame(maxWidth: .infinity, maxHeight: .infinity)`
    - Overlays: `.overlay(alignment: .topLeading/topTrailing)` for corner elements
    - Conditional rendering based on wrist state and AOD mode
  - **Always-On Display Support**:
    - Detects AOD state via `@Environment(\.isLuminanceReduced)`
    - Hides non-essential UI (date/time, battery, phase indicators, medal) in AOD
    - Reduces ring brightness (`.orange.opacity(0.5)` or `.yellow.opacity(0.5)` in infinite mode) when `isLuminanceReduced`
    - Protects timer display with `.privacySensitive()` modifier
    - Wrist state detection via `WristStateManager` + `isLuminanceReduced` for optimal UI state
  - **watchOS 26 native `.toolbar()` API** for bottom controls (requires NavigationStack wrapper)
  - **Digital Crown control** - Use `.focusable()` and `.digitalCrownRotation()` to adjust phase duration when paused
    - Rotates to adjust total phase duration by 1-minute increments
    - Only active when timer is stopped (prevents accidental adjustments during countdown)
    - Adjusts `totalTime`, keeping elapsed time constant
    - **Remaining time increases/decreases accordingly**: `remainingTime = newTotalTime - elapsedTime`
    - Updates phase indicator number and timer ring proportion in real-time
    - Example: 25-minute phase with 10 minutes elapsed (15 remaining) → rotate +1 minute → becomes 26-minute phase with 10 minutes elapsed (16 remaining) ✅
    - **Phase duration resets to default when starting new cycle**
  - Ring-based progress visualization:
    - Background ring (opacity 0.2)
    - Tomato ring (orange in normal mode, yellow in infinite mode) - main progress indicator
    - Infinite mode: displays full circle (100% progress)
  - Phase indicators showing duration and completion status
    - Normal mode: displays minute count (e.g., "25")
    - Infinite mode: displays "∞" before starting, then actual elapsed time
    - Over 99 minutes: displays hours rounded up (e.g., "2h" for 119 minutes)
    - Golden color in infinite mode for current phase indicator
  - **Top status displays** (only when wrist raised and NOT in AOD):
    - **Left corner**: Date (MM/DD) and weekday abbreviation
    - **Note**: Time (HH:mm) and battery display were intentionally removed for cleaner interface
  - `confirmationDialog` for reset options (reset current phase / reset entire cycle)

- **SettingsView.swift** - Configuration page
  - List-based settings interface
  - **Infinite Timer Toggle**: Enable/disable infinite counting mode
    - When enabled: timer continues past phase duration with golden UI
    - Icon: infinity symbol (∞)
    - Persisted via `@Published var isInfiniteMode` in TimerModel

### Special Features

1. **Skip Tracking** - Quality metrics
   - Tracks if any phase was skipped in current cycle
   - Only increments `completedCycles` if no skips occurred
   - Medal color changes (orange = clean, green = skipped)

2. **State Persistence** - Seamless experience
   - Saves state on every phase transition
   - Restores timer state on app launch
   - First launch detection resets to clean state

3. **Double Tap Gesture Support** (Apple Watch Series 9+, Ultra 2+)
   - Start/pause button uses `.handGestureShortcut(.primaryAction)` modifier
   - Enables quick control via double tap gesture (pinch index finger and thumb twice)
   - Available on watchOS 10+ with supported hardware

4. **Phase Duration Adjustment** - Dynamic phase customization
   - Digital Crown adjusts total phase duration when timer is paused
   - Adjustment range: unlimited extension, cannot reduce below elapsed time
   - Phase indicator displays adjusted duration in real-time
   - Timer ring proportion updates immediately
   - `adjustedPhaseDuration` property tracks current phase's modified duration
   - **Resets to default duration when entering new cycle**

5. **Enhanced Phase Completion Alerts** - Haptic-based notification system
   - **Background Mode**: Standard system notification with `.timeSensitive` interruption level
   - **Foreground Mode**: Custom in-app haptic alert pattern
     - Pattern: Two quick taps → 0.5s pause → One success tap
     - Uses `.notification` and `.success` haptic types
     - Creates distinct, unmistakable alert pattern different from other notifications
   - **watchOS Limitation**: System sounds not supported (AudioToolbox unavailable on watchOS)
   - Automatic detection of app state to choose appropriate alert method
   - Callback-based architecture ensures alerts trigger precisely when phase completes

6. **Infinite Timer Mode** - Continuous counting beyond phase duration
   - **Settings Toggle**: Enable/disable via settings page
   - **Visual Changes**:
     - Timer ring: changes to golden color (yellow)
     - Time display: shows elapsed time (countup) in golden color
     - Current phase indicator: displays "∞" symbol before starting, then actual elapsed minutes
     - Full circle ring (100% progress) while counting
   - **Behavior**:
     - No phase completion notification when time reaches zero
     - Continues counting up indefinitely
     - Stop button replaces pause button when running
     - Clicking stop button records actual elapsed time in phase indicator
   - **Time Display Format**:
     - 0-99 minutes: displays as minutes (e.g., "25")
     - 100+ minutes: converts to hours rounded up (e.g., "119 min → 2h")
   - **Implementation**:
     - `TimerCore.isInfiniteMode` flag switches between countdown/countup logic
     - `infiniteElapsedTime` property tracks elapsed seconds
     - `stopInfiniteTimer()` method records final duration in `adjustedPhaseDuration`

## Widget/Complication Extension

- **PomoTAPComplication** - Widget extension target using WidgetKit
  - **Supported Families**: All 4 watchOS accessory widget families
    - `.accessoryCircular` - Circular progress ring with phase icon
    - `.accessoryRectangular` - Phase name, time, and horizontal progress bar
    - `.accessoryInline` - Single line: emoji + phase + time
    - `.accessoryCorner` - Corner gauge with curved time label
  - **Liquid Glass Design**: All widgets use `.glassEffect()` modifier for watchOS 26's translucent glass material
  - **Data Sharing**: Uses App Groups (`group.songquan.Pomo-TAP`)
    - `SharedTimerState` (defined in `SharedTypes.swift`): Codable struct with timer state
    - Main app saves state to shared UserDefaults via `TimerModel.updateSharedState()`
    - Widget reads state from shared UserDefaults in `Provider.loadCurrentState()`
    - Triggers refresh with `WidgetCenter.shared.reloadAllTimelines()` on state changes
  - **Timeline Strategy**: Sparse sampling to reduce battery consumption
    - **Stopped timer**: Single entry with `.never` policy
    - **Running timer**: Dynamic entries with `.atEnd` policy
      - First 5 minutes: entry every 1 minute (high granularity for focus phase start)
      - 5-20 minutes: entry every 5 minutes (reduced frequency for middle phase)
      - Last 5 minutes: entry every 1 minute (high granularity for phase completion)
      - Final entry: marks phase completion with `isRunning: false`
    - Implementation: `generateTimeIntervals(remainingSeconds:)` generates sparse intervals
  - **Smart Stack Relevance**: Intelligent widget suggestions using `TimelineEntryRelevance`
    - **Base score (0-50)**: Timer running (50 pts) vs stopped (10 pts)
    - **Time urgency (+30)**: Last 5 minutes before phase completion
    - **Context bonus (+20)**: Weekday working hours (Mon-Fri, 9am-6pm)
    - **Phase completion (80)**: High relevance when timer completes
    - Implementation: `calculateRelevance()` computes dynamic scores (0-100 range)
    - System uses scores to prioritize widget in Smart Stack rotation
  - **Phase Display**:
    - Symbols: brain (work), cup (short break), walking figure (long break)
    - Colors: orange (running), gray (stopped)
    - Localized phase names via `NSLocalizedString()`
  - **Deep Linking**: `widgetURL("pomoTAP://open")` for tap actions
  - **Bundle ID**: `songquan.Pomo-TAP.watchkitapp.PomoTAPComplication`

## Development Guidelines

### Code Style

Follow the existing `.cursorrules`:
- Use latest Swift and SwiftUI features
- Prioritize readability over performance
- Implement all functionality completely (no TODOs/placeholders)
- Think step-by-step before coding
- Minimize prose, be concise

### watchOS 26 Best Practices (2025)

#### Liquid Glass Design
- **What is Liquid Glass**: watchOS 26's new translucent material that reflects and refracts surroundings
- **SwiftUI API**: Apply `.glassEffect()` modifier to views for glass appearance
- **Widget Integration**: All widget families use `.glassEffect()` for consistent design language
- **Background**: Use `.containerBackground(.clear, for: .widget)` to maintain translucency
- **Visual Effect**: Creates depth and vitality across controls, navigation, and widgets
- **Platform Unity**: First unified design language across iOS 26, iPadOS 26, macOS Tahoe 26, watchOS 26, tvOS 26

#### Smart Stack Widget Relevance
- **Purpose**: Help system intelligently prioritize widgets in Smart Stack rotation
- **API**: Add `TimelineEntryRelevance` property to `TimelineEntry` conforming types
- **Score Range**: 0-100, where higher scores indicate greater relevance
- **Context Factors**: Consider time of day, timer state, user activity patterns
- **Implementation**: Create `calculateRelevance()` function that evaluates multiple signals
- **Best Practice**: Combine multiple relevance signals (state + time + context) for accurate scoring
- **Example Signals**:
  - Timer actively running vs paused
  - Time urgency (approaching completion)
  - User context (work hours, location)
  - Task type (work phase vs break)

#### Digital Crown Integration
- **API**: Use `.focusable()` + `.digitalCrownRotation()` modifiers together
- **Order matters**: `.focusable()` must come BEFORE `.digitalCrownRotation()` in modifier chain
- **Parameters**:
  - `from:` and `through:` define value range
  - `by:` sets stepping increment (e.g., 1.0 for 1-second steps)
  - `sensitivity:` controls rotation-to-value ratio (.low/.medium/.high)
  - `isContinuous:` enables value wrapping at limits
  - `isHapticFeedbackEnabled:` provides tactile feedback
- **Use cases**: Timers, volume controls, scrollable lists, value pickers
- **Reference**: Updated for Xcode 16.4 (May 2025)

#### Haptic Feedback on watchOS
- **Framework**: `WatchKit` - use `WKInterfaceDevice.current().play(_:)`
- **Available Types**: `.notification`, `.success`, `.failure`, `.retry`, `.start`, `.stop`, `.click`, `.directionUp`, `.directionDown`
- **Important Limitations**:
  - **No AudioToolbox**: `AudioServicesPlaySystemSound` is **not available** on watchOS
  - **No Custom Sounds**: watchOS does not support custom notification sounds or system sound effects
  - **Haptic Only**: All in-app alerts must use haptic feedback exclusively
  - **Background Requires**: Running `HKWorkoutSession` or `WKExtendedRuntimeSession` to play haptics in background
  - **Taptic Engine**: Cannot overlap haptics; there is a delay between each one
  - **Simulator**: Haptics only work on physical devices, not simulator
- **Best Practice**: Create distinctive patterns by combining different haptic types with timed delays
- **Example Pattern**: `.notification` → 0.2s → `.notification` → 0.5s → `.success` (double tap + pause + emphasis)

#### Timer Implementation
- **Recommended**: `DispatchSourceTimer` over Foundation `Timer`
  - Higher precision and lower battery consumption
  - Better scheduling control with leeway parameter
- **Update Frequency**: Use 1-second intervals (`repeating: .seconds(1)`) for timer ticks
  - Second-level precision is sufficient for countdown timers
  - Reduces CPU wake-ups from 10/sec to 1/sec (90% reduction)
  - Eliminates need for UI update throttling
- **Invalidation**: Always call `timer.cancel()` to prevent memory leaks
- **NOT for frame-level accuracy**: Use `CADisplayLink` for animation-synced updates

#### Notification Best Practices
- **Framework**: `UNUserNotificationCenter` is the standard - no custom system needed
- **Permission flow**: Request authorization with `.alert`, `.sound`, `.badge` options
- **Scheduling**: Use `UNTimeIntervalNotificationTrigger` for time-based notifications
- **Interruption Level**: Set `.timeSensitive` for focus app notifications that can break through Focus modes
- **watchOS Limitation**: Custom notification sounds (`.soundNamed()`) are iOS-only
- **In-App Alerts**: When app is in foreground, use **haptic-only** sequences (no sound support on watchOS)
- **Categories & Actions**: Define `UNNotificationCategory` for interactive notifications
- **Cleanup**: Remove pending/delivered notifications before scheduling new ones
- **Foreground handling**: Implement `willPresent` delegate to control foreground behavior
- **Infinite Mode**: Disable notifications when infinite timer mode is enabled

#### Battery Monitoring (watchOS)
- **Enable monitoring**: `WKInterfaceDevice.current().isBatteryMonitoringEnabled = true`
- **Read level**: `WKInterfaceDevice.current().batteryLevel` (0.0 to 1.0)
- **Check state**: `WKInterfaceDevice.current().batteryState` (.charging, .full, .unplugged, .unknown)
- **Update frequency**: Poll every 60s to balance accuracy and battery life
- **Platform limitation**: `UIDevice.batteryLevelDidChangeNotification` is iOS-only (unavailable on watchOS)

#### Toolbar API (watchOS 26)
- **Requirement**: Must wrap view in `NavigationStack` or `NavigationView`
- **Placement**: `.bottomBar` supported since watchOS 10+
- **Grouping**: Use `ToolbarItemGroup` for multiple items with custom layout
- **Liquid Glass**: Toolbar automatically applies watchOS 26 glass material design
- **Hide navigation bar**: Use `.navigationBarHidden(true)` to preserve full-screen interface

#### Always-On Display Optimization
- **Environment Detection**: Use `@Environment(\.isLuminanceReduced)` to detect AOD state
  - `isLuminanceReduced = true`: Display is in low-power always-on mode
  - `isLuminanceReduced = false`: Display is in normal active mode
- **Conditional Rendering**: Show detailed UI only when NOT in AOD
  - Hide: date/time, battery, phase indicators, medal/completion count
  - Keep: timer ring (with reduced brightness) and remaining time
- **Brightness Adjustment**: Reduce colors to 50% opacity in AOD (e.g., `.orange.opacity(0.5)`)
- **Privacy Protection**: Use `.privacySensitive()` on sensitive data (timer values)
- **Wrist State**: Combine with `WristStateManager` for dual-layer detection
  - Wrist down: hide top info, keep timer visible
  - AOD mode: hide top info, dim timer ring
- **Battery Optimization**: Skip periodic updates when `isLuminanceReduced`
- **1Hz support**: Timer app shows ticking seconds in always-on mode (Series 10+)
- **Reference**: [Apple - Designing for Always-On State](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)

#### Background Execution
- **Framework**: `WKExtendedRuntimeSession` for long-running tasks
- **Session lifecycle**: Start on timer start, stop on timer stop
- **Reference counting**: Track multiple start/stop requests to avoid premature termination
- **Auto-restart**: Handle expiration and error cases with retry logic
- **Delay between restarts**: Add 0.5-2s delays to avoid rapid restart loops
- **Swift 6 Concurrency**: Use `Task.sleep()` instead of `DispatchWorkItem` for timeout mechanisms to comply with Sendable protocol requirements

### Common Patterns

1. **All timer-related classes use `@MainActor`** to avoid threading issues

2. **Manager initialization in TimerModel:**
   ```swift
   private let manager = SpecializedManager()
   // Then in init():
   super.init()
   setupBindings() // Bind manager @Published to TimerModel @Published
   ```

3. **State updates always call `stateManager.saveState()`** after modifications

4. **Background sessions:**
   - Start when timer starts
   - Stop when timer stops
   - Use reference counting for nested start/stop calls

5. **Notification scheduling:**
   - Cancel previous notifications before scheduling new ones
   - Use `TimeIntervalNotificationTrigger` with precise intervals
   - Check permission status before sending

6. **Widget state synchronization:**
   - Call `updateSharedState()` after any timer state change
   - Encode `SharedTimerState` to App Group UserDefaults
   - Trigger refresh with `WidgetCenter.shared.reloadAllTimelines()`
   - Widget reads from shared UserDefaults in `Provider.loadCurrentState()`

7. **SwiftUI layout patterns:**
   - **Prefer**: `.overlay(alignment:)` with padding for predictable positioning
   - **Avoid**: ZStack + `.position()` with manual coordinate calculations
   - **Why**: overlay handles safe areas and dynamic sizing automatically

8. **Critical Bug Fix - Timer Start Logic:**
   - **NEVER reset `timerCore.totalTime` or `timerCore.remainingTime` in `startTimer()`**
   - These values may have been adjusted by Digital Crown or other user interactions
   - `timerCore.startTimer()` correctly handles starting from current `remainingTime` value
   - Only set these values during initialization, phase transitions, or explicit resets

9. **Phase Completion Callback Pattern:**
   - TimerCore provides `onPhaseCompleted` closure property
   - TimerModel sets callback in `setupTimerCallbacks()` during initialization
   - Callback triggers `handlePhaseCompletion()` which checks app state
   - Foreground: plays custom in-app haptic pattern (watchOS doesn't support custom sounds)
   - Background: relies on system notification (already scheduled)

10. **Infinite Mode State Management:**
   - `isInfiniteMode` synchronized between TimerModel and TimerCore via Combine
   - When enabled: timer counts up indefinitely without notifications
   - `stopInfiniteTimer()` records final elapsed time in `adjustedPhaseDuration`
   - Phase indicator shows ∞ before start, then actual elapsed time
   - Over 99 minutes: converts to hours with ceiling rounding (e.g., 119min → 2h)

11. **Swift 6 Concurrency Best Practices:**
   - **@preconcurrency imports**: Add `@preconcurrency import Dispatch` and `@preconcurrency import WatchKit` to suppress Sendable warnings from modules not yet fully compatible with Swift concurrency
   - **Sendable protocol compliance**: Avoid capturing non-Sendable types (like `DispatchWorkItem`) in `@Sendable` closures
   - **Structured concurrency**: Prefer `Task.sleep()` over `DispatchQueue.asyncAfter` for timeout mechanisms in async contexts
   - **Synchronous property access**: NEVER use `await` on synchronous properties like `@Published` variables or `WKExtension.shared().applicationState`
   - **Async/sync boundaries**: When calling async functions from sync contexts, wrap in `Task { await ... }` blocks

### Localization

- Use `Localizable.xcstrings` for string catalogs
- Always wrap user-facing strings in `NSLocalizedString()`
- Support Chinese (zh-Hans) and English (en)
- Key naming convention: `Phase_Work`, `Start_Immediately`, etc.

### Testing Considerations

- Use Xcode's Watch Simulator for basic testing
- Test phase transitions and state persistence
- Verify notification scheduling and delivery
- Check Always-On display behavior
- Test extended runtime sessions for background execution

## Important Notes

- **No CoreData usage currently** - The xcdatamodeld file was removed; use UserDefaults for persistence
- **No HapticManager** - Use `WKInterfaceDevice.current().play(_:)` directly
- **App Group sharing** - Extension and main app share state via `group.songquan.Pomo-TAP`
- **Bundle structure** - Container app (`Pomo TAP.app`) wraps watch app (`Pomo TAP Watch App.app`)
- **NO AudioToolbox on watchOS** - `import AudioToolbox` and `AudioServicesPlaySystemSound` are **not available**
- **Haptic-only feedback** - All in-app alerts must use haptic patterns only (no custom sounds)
- **@MainActor classes** - When using `@MainActor` on classes, avoid `[weak self]` in main-thread closures to prevent Optional type errors

## Recent Changes (Latest Session)

### Features Added
1. **TabView Navigation** - Horizontal page-style navigation between timer and settings
2. **Settings Page** (`SettingsView.swift`) - Infinite timer toggle with list-based UI
3. **Infinite Timer Mode** - Continuous countup mode with golden UI theme
4. **Time Format Conversion** - Hours display for durations over 99 minutes
5. **Localization** - Added Settings, Infinite_Timer, Stop keys (zh-Hans, en, ja, ko)

### Bug Fixes
1. **AudioToolbox Import Error** - Removed unsupported framework, redesigned haptic feedback
2. **Closure Capture Warnings** - Fixed `@MainActor` closure patterns
3. **Observer Unused Warning** - Changed to `let _ = Timer.scheduledTimer`
4. **Sendable Warnings** - Added `@preconcurrency import WatchKit` and `@preconcurrency import Dispatch`
5. **Swift 6 Concurrency Compliance** - Fixed all Sendable-related warnings
   - Replaced `DispatchWorkItem` with `Task.sleep()` in BackgroundSessionManager timeout mechanism
   - Removed unnecessary `await` keywords from synchronous property access (@Published properties, WKExtension.shared().applicationState)
   - Refactored `handlePhaseCompletion()` to be synchronous, wrapping async operations in Task blocks

### Architecture Updates
- `TimerCore.isInfiniteMode` for dual-mode timer logic
- `TimerModel.stopInfiniteTimer()` for recording infinite session durations
- Enhanced haptic pattern: `.notification` × 2 (0.2s apart) → 0.5s → `.success`
- `PhaseIndicator` displays ∞ symbol or elapsed time based on mode
- **BackgroundSessionManager timeout refactor**: Replaced `DispatchWorkItem` + `DispatchQueue.asyncAfter` with structured concurrency (`Task.sleep()`) to comply with Swift 6 Sendable requirements