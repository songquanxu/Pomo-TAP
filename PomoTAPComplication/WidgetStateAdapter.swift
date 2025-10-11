import Foundation

/// 统一的 Widget 状态适配器
/// 将 SharedTimerState 转换为各类 Widget/Complication 所需的数据模型
struct WidgetStateAdapter {
    private let state: SharedTimerState

    init(state: SharedTimerState) {
        self.state = state
    }

    // MARK: - Complication Model
    func makeComplicationState() -> ComplicationDisplayState {
        ComplicationDisplayState(
            displayMode: state.displayMode,
            phaseType: state.currentPhaseType,
            isRunning: state.timerRunning,
            countdownRemaining: state.remainingTime,
            flowElapsed: state.flowElapsedTime,
            totalDuration: state.totalTime,
            progress: state.progress,
            phaseEndDate: state.phaseEndDate,
            flowStartDate: state.flowStartDate,
            currentPhaseName: state.currentPhaseName,
            nextPhaseName: nextPhase()?.name,
            nextPhaseDuration: nextPhase()?.duration ?? 0
        )
    }

    // MARK: - Smart Stack Model
    func makeSmartStackState() -> SmartStackDisplayState {
        SmartStackDisplayState(
            displayMode: state.displayMode,
            phaseType: state.currentPhaseType,
            phaseName: state.currentPhaseName,
            isRunning: state.timerRunning,
            countdownRemaining: state.remainingTime,
            flowElapsed: state.flowElapsedTime,
            totalDuration: state.totalTime,
            completedCycles: state.completedCycles,
            hasSkippedInCurrentCycle: state.hasSkippedInCurrentCycle,
            phaseStatuses: state.phaseCompletionStatus,
            nextPhaseName: nextPhase()?.name,
            nextPhaseDuration: nextPhase()?.duration ?? 0
        )
    }

    // MARK: - Helpers
    private func nextPhase() -> PhaseInfo? {
        guard !state.phases.isEmpty else { return nil }
        let nextIndex = (state.currentPhaseIndex + 1) % state.phases.count
        return state.phases[safe: nextIndex]
    }
}

// MARK: - Complication Display Model
struct ComplicationDisplayState {
    let displayMode: PhaseDisplayMode
    let phaseType: PhaseCategory
    let isRunning: Bool
    let countdownRemaining: Int
    let flowElapsed: Int
    let totalDuration: Int
    let progress: Double
    let phaseEndDate: Date?
    let flowStartDate: Date?
    let currentPhaseName: String
    let nextPhaseName: String?
    let nextPhaseDuration: Int

    var isInFlow: Bool {
        displayMode == .flow
    }

    var effectiveTimeIndicator: Int {
        isInFlow ? flowElapsed : countdownRemaining
    }
}

// MARK: - Smart Stack Display Model
struct SmartStackDisplayState {
    let displayMode: PhaseDisplayMode
    let phaseType: PhaseCategory
    let phaseName: String
    let isRunning: Bool
    let countdownRemaining: Int
    let flowElapsed: Int
    let totalDuration: Int
    let completedCycles: Int
    let hasSkippedInCurrentCycle: Bool
    let phaseStatuses: [PhaseCompletionStatus]
    let nextPhaseName: String?
    let nextPhaseDuration: Int

    var isInFlow: Bool {
        displayMode == .flow
    }
}

// MARK: - Safe Index Helper
extension Array {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

// MARK: - SmartStackDisplayState Helper Methods
extension SmartStackDisplayState {
    var progressValueForGauge: Double {
        if displayMode == .flow {
            return min(Double(flowElapsed) / Double(max(totalDuration, 1)), 1.0)
        }
        guard totalDuration > 0 else { return 0 }
        return 1.0 - Double(countdownRemaining) / Double(totalDuration)
    }

    func updatedForCountdown(remaining: Int, isRunning: Bool? = nil) -> SmartStackDisplayState {
        SmartStackDisplayState(
            displayMode: remaining > 0 ? .countdown : .idle,
            phaseType: phaseType,
            phaseName: phaseName,
            isRunning: isRunning ?? (remaining > 0),
            countdownRemaining: remaining,
            flowElapsed: 0,
            totalDuration: totalDuration,
            completedCycles: completedCycles,
            hasSkippedInCurrentCycle: hasSkippedInCurrentCycle,
            phaseStatuses: phaseStatuses,
            nextPhaseName: nextPhaseName,
            nextPhaseDuration: nextPhaseDuration
        )
    }

    func updatedForFlow(elapsed: Int) -> SmartStackDisplayState {
        SmartStackDisplayState(
            displayMode: .flow,
            phaseType: phaseType,
            phaseName: phaseName,
            isRunning: true,
            countdownRemaining: 0,
            flowElapsed: elapsed,
            totalDuration: totalDuration,
            completedCycles: completedCycles,
            hasSkippedInCurrentCycle: hasSkippedInCurrentCycle,
            phaseStatuses: phaseStatuses,
            nextPhaseName: nextPhaseName,
            nextPhaseDuration: nextPhaseDuration
        )
    }
}
