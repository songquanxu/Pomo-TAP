import SwiftUI
import Combine
import os

// MARK: - 状态管理
@MainActor
class TimerStateManager: ObservableObject {
    // MARK: - Published Properties
    @Published var phases: [Phase] = []
    @Published var currentPhaseIndex: Int = 0
    @Published var completedCycles: Int = 0
    @Published var hasSkippedInCurrentCycle = false
    @Published var currentPhaseName: String = ""
    @Published var phaseCompletionStatus: [PhaseStatus] = []

    // MARK: - Private Properties
    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "TimerStateManager")
    private let launchedBeforeKey = "launchedBefore"

    // MARK: - Initialization
    init() {
        self.userDefaults = UserDefaults.standard
        initializeDefaultPhases()
        resetPhaseCompletionStatus()

        if !userDefaults.bool(forKey: launchedBeforeKey) {
            resetCycle()
            userDefaults.set(true, forKey: launchedBeforeKey)
        } else {
            loadState()
        }
    }

    // MARK: - Public Methods
    func saveState() {
        let state = TimerState(
            currentPhaseIndex: currentPhaseIndex,
            remainingTime: 0, // This will be handled by TimerCore
            timerRunning: false, // This will be handled by TimerCore
            totalTime: 0, // This will be handled by TimerCore
            phaseCompletionStatus: phaseCompletionStatus,
            currentPhaseName: currentPhaseName,
            completedCycles: completedCycles
        )

        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(state)
            userDefaults.set(data, forKey: "timerState")
            userDefaults.synchronize()
            logger.info("状态保存成功")
        } catch {
            logger.error("状态保存失败: \(error.localizedDescription)")
        }
    }

    func loadState() {
        if let data = userDefaults.data(forKey: "timerState"),
           let state = try? JSONDecoder().decode(TimerState.self, from: data) {
            currentPhaseIndex = state.currentPhaseIndex
            completedCycles = state.completedCycles
            currentPhaseName = state.currentPhaseName

            // 重建阶段完成状态
            phaseCompletionStatus = Array(repeating: .notStarted, count: phases.count)

            // 更新之前阶段的状态
            for i in 0..<currentPhaseIndex {
                if let savedStatus = state.phaseCompletionStatus[safe: i],
                   savedStatus == .skipped {
                    phaseCompletionStatus[i] = .skipped
                } else {
                    phaseCompletionStatus[i] = .normalCompleted
                }
            }

            // 设置当前阶段状态
            phaseCompletionStatus[currentPhaseIndex] = .current
        } else {
            resetCycle()
        }
    }

    func resetPhaseCompletionStatus() {
        phaseCompletionStatus = Array(repeating: .notStarted, count: phases.count)
        phaseCompletionStatus[currentPhaseIndex] = .current

        // 清除所有阶段的调整后时长
        for index in phases.indices {
            phases[index].adjustedDuration = nil
        }
    }

    func resetCycle() {
        currentPhaseIndex = 0
        // ✅ 不重置 completedCycles - 保留历史奖章数据
        hasSkippedInCurrentCycle = false
        resetPhaseCompletionStatus()
        currentPhaseName = phases[0].name
        saveState()
    }

    func moveToNextPhase(currentPhaseStatus: PhaseStatus = .normalCompleted) {
        // 更新当前阶段的完成状态（使用传入的状态或默认为正常完成）
        phaseCompletionStatus[currentPhaseIndex] = currentPhaseStatus
        savePhaseCompletionStatus()

        // 移动到下一个阶段
        currentPhaseIndex = (currentPhaseIndex + 1) % phases.count

        // 如果当前阶段是最后一个阶段，完成一个周期
        if currentPhaseIndex == 0 {
            completeCycle()
        } else {
            // 否则，将下一个阶段标记为当前阶段
            phaseCompletionStatus[currentPhaseIndex] = .current
        }

        // 更新当前阶段的名称
        currentPhaseName = phases[currentPhaseIndex].name
        saveState()
    }

    func skipPhase() {
        hasSkippedInCurrentCycle = true
        // 直接调用 moveToNextPhase 并传递 .skipped 状态
        moveToNextPhase(currentPhaseStatus: .skipped)
    }

    func isCurrentPhaseWorkPhase() -> Bool {
        // 判断当前阶段是否为工作阶段
        return phases[currentPhaseIndex].name == "Work"
    }

    // MARK: - Private Methods
    private func initializeDefaultPhases() {
        phases = [
            Phase(duration: 25 * 60, name: "Work"),
            Phase(duration: 5 * 60, name: "Short Break"),
            Phase(duration: 25 * 60, name: "Work"),
            Phase(duration: 15 * 60, name: "Long Break")
        ]
    }

    private func completeCycle() {
        if !hasSkippedInCurrentCycle {
            completedCycles += 1
        }
        hasSkippedInCurrentCycle = false
        resetPhaseCompletionStatus()
    }

    private func savePhaseCompletionStatus() {
        if let data = try? JSONEncoder().encode(phaseCompletionStatus) {
            userDefaults.set(data, forKey: "phaseCompletionStatus")
        }
    }
}

// MARK: - Supporting Types
enum PhaseStatus: String, Codable {
    case notStarted, current, normalCompleted, skipped
}

struct Phase: Codable {
    let duration: Int
    let name: String
    var adjustedDuration: Int?  // 实际完成的时长（如果有调整或心流模式）
}

struct TimerState: Codable {
    var currentPhaseIndex: Int
    var remainingTime: Int
    var timerRunning: Bool
    var totalTime: Int
    var phaseCompletionStatus: [PhaseStatus]
    var currentPhaseName: String
    var completedCycles: Int

    init(currentPhaseIndex: Int = 0,
         remainingTime: Int = 1500,
         timerRunning: Bool = false,
         totalTime: Int = 1500,
         phaseCompletionStatus: [PhaseStatus] = [.current, .notStarted, .notStarted, .notStarted],
         currentPhaseName: String = "Work",
         completedCycles: Int = 0) {
        self.currentPhaseIndex = currentPhaseIndex
        self.remainingTime = remainingTime
        self.timerRunning = timerRunning
        self.totalTime = totalTime
        self.phaseCompletionStatus = phaseCompletionStatus
        self.currentPhaseName = currentPhaseName
        self.completedCycles = completedCycles
    }
}

// MARK: - Array Extension
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
