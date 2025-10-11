import SwiftUI
import WidgetKit
import os

/// 集中管理共享计时器状态的发布器
/// 负责状态同步、Widget 刷新的统一管理和按需优化
@MainActor
class SharedTimerStatePublisher: ObservableObject {
    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "SharedStatePublisher")
    private let suiteName = SharedTimerState.suiteName
    private let userDefaultsKey = SharedTimerState.userDefaultsKey

    // 用于优化的前一次状态
    private var lastPublishedState: SharedTimerState?

    // MARK: - Initialization
    init() {
        logger.info("SharedTimerStatePublisher 已初始化")
    }

    // MARK: - Public Methods

    /// 更新共享状态并智能决定是否刷新 Widget
    /// - Parameter timerModel: 当前的计时器模型
    func updateSharedState(from timerModel: TimerModel) async {
        let newState = createSharedState(from: timerModel)

        // 智能判断是否需要刷新 Widget
        let needsWidgetRefresh = shouldRefreshWidgets(oldState: lastPublishedState, newState: newState)

        // 编码并保存到 App Group
        if let userDefaults = UserDefaults(suiteName: suiteName),
           let data = try? JSONEncoder().encode(newState) {
            userDefaults.set(data, forKey: userDefaultsKey)
            userDefaults.synchronize()

            logger.info("✅ 状态已更新: phase=\(newState.currentPhaseName), running=\(newState.timerRunning), remaining=\(newState.remainingTime)s")

            // 按需刷新 Widget
            if needsWidgetRefresh {
                WidgetCenter.shared.reloadAllTimelines()
                logger.info("🔄 Widget 已刷新 (智能触发)")
            } else {
                logger.debug("⏭️  跳过 Widget 刷新 (状态无关键变化)")
            }

            // 保存当前状态作为下次比较的基准
            lastPublishedState = newState

        } else {
            logger.error("❌ 状态更新失败: UserDefaults 或编码失败")
        }
    }

    /// 强制刷新 Widget (用于特殊场景)
    func forceRefreshWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("🔄 Widget 强制刷新")
    }

    // MARK: - Private Methods

    /// 从 TimerModel 创建 SharedTimerState
    private func createSharedState(from timerModel: TimerModel) -> SharedTimerState {
        // Determine display mode
        let displayMode: PhaseDisplayMode
        if timerModel.isInFlowCountUp && timerModel.timerRunning {
            displayMode = .flow
        } else if timerModel.timerRunning {
            displayMode = .countdown
        } else if timerModel.remainingTime > 0 {
            displayMode = .paused
        } else {
            displayMode = .idle
        }

        // Determine phase category
        let currentPhaseType: PhaseCategory
        if timerModel.stateManager.isCurrentPhaseWorkPhase() {
            currentPhaseType = .work
        } else {
            let normalizedName = timerModel.currentPhaseName.lowercased()
            if normalizedName.contains("long") {
                currentPhaseType = .longBreak
            } else if normalizedName.contains("short") {
                currentPhaseType = .shortBreak
            } else {
                currentPhaseType = .unknown
            }
        }

        // 将 PhaseStatus 转换为 PhaseCompletionStatus
        let completionStatus = timerModel.phaseCompletionStatus.map { status -> PhaseCompletionStatus in
            switch status {
            case .notStarted:
                return .notStarted
            case .current:
                return .current
            case .normalCompleted:
                return .normalCompleted
            case .skipped:
                return .skipped
            }
        }

        return SharedTimerState(
            currentPhaseIndex: timerModel.currentPhaseIndex,
            remainingTime: timerModel.remainingTime,
            timerRunning: timerModel.timerRunning,
            currentPhaseName: timerModel.currentPhaseName,
            lastUpdateTime: Date(),
            totalTime: timerModel.totalTime,
            phases: zip(timerModel.phases, timerModel.phaseCompletionStatus).map { phase, status in
                PhaseInfo(
                    duration: phase.duration,
                    name: phase.name,
                    status: status.rawValue,
                    adjustedDuration: phase.adjustedDuration
                )
            },
            completedCycles: timerModel.completedCycles,
            phaseCompletionStatus: completionStatus,
            hasSkippedInCurrentCycle: timerModel.hasSkippedInCurrentCycle,
            isCurrentPhaseWorkPhase: timerModel.stateManager.isCurrentPhaseWorkPhase(),
            isInFlowCountUp: timerModel.isInFlowCountUp,
            flowElapsedTime: timerModel.isInFlowCountUp ? timerModel.infiniteElapsedTime : 0,
            displayMode: displayMode,
            currentPhaseType: currentPhaseType,
            phaseEndDate: timerModel.timerCore.countdownEndDate,
            flowStartDate: timerModel.timerCore.flowStartDate
        )
    }

    /// 智能判断是否需要刷新 Widget
    /// 仅在关键状态变化时才触发刷新，优化电池效率
    private func shouldRefreshWidgets(oldState: SharedTimerState?, newState: SharedTimerState) -> Bool {
        guard let oldState = oldState else {
            // 第一次更新，需要刷新
            return true
        }

        // 关键状态变化检查
        let hasKeyChanges =
            oldState.currentPhaseIndex != newState.currentPhaseIndex ||          // 阶段切换
            oldState.timerRunning != newState.timerRunning ||                    // 运行状态变化
            oldState.currentPhaseName != newState.currentPhaseName ||            // 阶段名称变化
            oldState.completedCycles != newState.completedCycles ||              // 完成周期变化
            oldState.hasSkippedInCurrentCycle != newState.hasSkippedInCurrentCycle || // 跳过状态变化
            oldState.phaseCompletionStatus != newState.phaseCompletionStatus ||   // 阶段完成状态变化
            oldState.displayMode != newState.displayMode ||                       // 显示模式变化
            oldState.currentPhaseType != newState.currentPhaseType                // 阶段类型变化

        // 时间变化阈值检查 (避免每秒刷新)
        let significantTimeChange = abs(oldState.remainingTime - newState.remainingTime) >= 60 // 1分钟变化
        let flowElapsedChange = newState.displayMode == .flow && (abs(oldState.flowElapsedTime - newState.flowElapsedTime) >= 60)

        // 总时间变化 (阶段调整等)
        let totalTimeChange = oldState.totalTime != newState.totalTime

        let shouldRefresh = hasKeyChanges || significantTimeChange || flowElapsedChange || totalTimeChange

        if shouldRefresh {
            let reasons = [
                hasKeyChanges ? "关键状态变化" : nil,
                significantTimeChange ? "时间显著变化(\(abs(oldState.remainingTime - newState.remainingTime))s)" : nil,
                flowElapsedChange ? "心流时长变化(\(abs(oldState.flowElapsedTime - newState.flowElapsedTime))s)" : nil,
                totalTimeChange ? "总时间变化" : nil
            ].compactMap { $0 }.joined(separator: ", ")

            logger.debug("📱 Widget 刷新原因: \(reasons)")
        }

        return shouldRefresh
    }
}

// MARK: - Widget 刷新策略扩展
extension SharedTimerStatePublisher {

    /// 针对特定 Widget 的刷新策略
    /// 未来可扩展为按需刷新特定 Widget 而非全量刷新
    func refreshSpecificWidgets(for changeType: WidgetChangeType) {
        switch changeType {
        case .phaseTransition:
            // 阶段切换影响所有 Widget
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("🔄 阶段切换 - 全量刷新 Widget")

        case .timerStateChange:
            // 计时器状态变化影响主要 Widget
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("🔄 计时器状态变化 - 刷新计时器 Widget")

        case .cycleCompletion:
            // 周期完成影响统计 Widget
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("🔄 周期完成 - 刷新统计 Widget")

        case .timeUpdate:
            // 时间更新通常不需要刷新 (由 Widget 内部 timeline 处理)
            logger.debug("⏭️  时间更新 - 跳过刷新")
        }
    }
}

/// Widget 变化类型枚举
enum WidgetChangeType {
    case phaseTransition      // 阶段切换
    case timerStateChange     // 计时器状态变化
    case cycleCompletion      // 周期完成
    case timeUpdate           // 时间更新
}
