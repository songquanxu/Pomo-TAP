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
        // 提取每个阶段的时长（分钟）
        let phaseDurations = state.phases.map { phase in
            phase.duration / 60  // 转换秒为分钟
        }

        return ComplicationDisplayState(
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
            nextPhaseDuration: nextPhase()?.duration ?? 0,
            completedCycles: state.completedCycles,
            hasSkippedInCurrentCycle: state.hasSkippedInCurrentCycle,
            phaseStatuses: state.phaseCompletionStatus,
            phaseDurations: phaseDurations
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
    let completedCycles: Int
    let hasSkippedInCurrentCycle: Bool
    let phaseStatuses: [PhaseCompletionStatus]
    let phaseDurations: [Int]  // 每个阶段的时长（分钟）

    var isInFlow: Bool {
        displayMode == .flow
    }

    var effectiveTimeIndicator: Int {
        isInFlow ? flowElapsed : countdownRemaining
    }
}

// MARK: - Safe Index Helper
extension Array {
    subscript(safe index: Index) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
