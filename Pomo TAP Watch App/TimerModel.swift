import SwiftUI
import WatchKit
import Combine
import UserNotifications
import os
import WidgetKit

// MARK: - 主计时器模型 - 协调各个专用管理器
@MainActor
class TimerModel: NSObject, ObservableObject {
    // MARK: - 管理器实例
    private let timerCore: TimerCore
    private let stateManager: TimerStateManager
    private let sessionManager: BackgroundSessionManager
    private let notificationManager: NotificationManager

    // MARK: - Published Properties (代理到各个管理器)
    @Published var phases: [Phase] = []
    @Published var currentPhaseIndex: Int = 0
    @Published var remainingTime: Int = 0
    @Published var timerRunning: Bool = false
    @Published var totalTime: Int = 0
    @Published var completedCycles: Int = 0
    @Published var hasSkippedInCurrentCycle = false
    @Published var currentPhaseName: String = ""
    @Published var phaseCompletionStatus: [PhaseStatus] = []

    // MARK: - 其他UI状态
    @Published var adjustedPhaseDuration: Int = 0  // 当前阶段调整后的时长（秒）
    @Published var currentCycleCompleted = false
    @Published var tomatoRingPosition: Angle = .zero
    @Published var isTransitioning = false
    @Published var transitionProgress: CGFloat = 0
    @Published var isInResetMode: Bool = false
    @Published var isInfiniteMode: Bool = false  // 心流模式开关
    @Published var infiniteElapsedTime: Int = 0  // 心流模式下的已过时间（秒）
    @Published var isInFlowCountUp: Bool = false  // 当前是否处于心流正计时状态

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "TimerModel")
    private var hapticFeedbackTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    override init() {
        // 初始化各个管理器
        self.timerCore = TimerCore()
        self.stateManager = TimerStateManager()
        self.sessionManager = BackgroundSessionManager()
        self.notificationManager = NotificationManager(timerModel: nil)

        super.init()

        // 设置代理
        self.notificationManager.timerModel = self

        // 绑定状态
        setupBindings()

        // 设置计时器回调
        setupTimerCallbacks()

        // 初始化默认状态
        initializeState()
    }

    // MARK: - Public Methods
    func toggleTimer() async {
        if timerRunning {
            playSound(.stop)
            timerCore.stopTimer()
            sessionManager.stopExtendedSession()
            cancelPendingNotifications()  // 暂停时取消通知
        } else {
            playSound(.start)
            await startTimer()
        }
        updateSharedState()  // 更新 Widget
    }

    func resetCycle() {
        // 停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()
        cancelPendingNotifications()  // 重置时取消通知

        // 重置状态管理器
        stateManager.resetCycle()
        timerCore.resetTimer()

        // 重置UI状态（包括时间和调整后的时长）
        let duration = phases[0].duration
        remainingTime = duration
        totalTime = duration
        adjustedPhaseDuration = duration  // 重置调整后的时长为第一阶段的默认值
        timerCore.remainingTime = duration
        timerCore.totalTime = duration

        resetUIState()

        playSound(.retry)
        logger.info("计时器已完全重置")
        updateSharedState()  // 更新 Widget
    }

    func stopFlowCountUp() async {
        // 心流正计时模式下停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()
        cancelPendingNotifications()  // 停止心流模式时取消通知

        // 退出心流正计时模式，获取已过时间
        let elapsedTime = timerCore.exitFlowCountUp()
        adjustedPhaseDuration = elapsedTime

        playSound(.stop)
        logger.info("心流正计时已停止，已过时间: \(elapsedTime / 60) 分钟")

        // 进入下一个阶段
        await moveToNextPhase(autoStart: false, skip: false)

        updateSharedState()  // 更新 Widget
    }

    func resetCurrentPhase() {
        // 停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()
        cancelPendingNotifications()  // 重置当前阶段时取消通知

        // 清除暂停状态，避免下次启动时使用旧的剩余时间
        timerCore.clearPausedState()

        // 重置当前阶段的时间，但保持阶段索引和完成状态
        let duration = phases[currentPhaseIndex].duration
        remainingTime = duration
        totalTime = duration
        adjustedPhaseDuration = duration  // 重置时恢复原始时长
        timerCore.remainingTime = duration
        timerCore.totalTime = duration

        // 重置UI状态
        updateTomatoRingPosition()

        playSound(.retry)
        logger.info("当前阶段已重置")
    }

    func skipCurrentPhase() async {
        // 停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()
        cancelPendingNotifications()  // 跳过当前阶段时取消通知

        // 跳过当前阶段并自动开始下一个阶段
        await moveToNextPhase(autoStart: true, skip: true)

        playSound(.notification)
        logger.info("用户跳过当前阶段并自动开始下一阶段")
    }

    func moveToNextPhase(autoStart: Bool, skip: Bool = false) async {
        // 重置通知状态
        notificationSent = false

        // 清除暂停状态，避免新阶段使用旧的剩余时间
        timerCore.clearPausedState()

        // 开始过渡动画
        startTransitionAnimation()

        // 更新状态管理器
        if skip {
            stateManager.skipPhase()
        } else {
            stateManager.moveToNextPhase()
        }

        // 更新UI状态
        updateUIState()

        // 重置番茄环的位置
        tomatoRingPosition = .zero

        // 保存状态
        stateManager.saveState()

        // 如果是自动开始，启动计时器
        if autoStart {
            await startTimer()
        }

        updateSharedState()  // 更新 Widget
    }

    func handleNotificationResponse() async {
        // 防止重复响应：如果已经在下一个阶段或计时器正在运行，直接返回
        // 这是幂等性保护，避免用户多次点击通知导致阶段错乱
        if timerRunning {
            logger.warning("通知响应被忽略：计时器已在运行")
            return
        }

        logger.info("处理通知响应：准备进入下一阶段")

        // 进入下一阶段并自动开始
        await moveToNextPhase(autoStart: true)
    }

    func requestNotificationPermission() {
        notificationManager.requestNotificationPermission()
    }

    // MARK: - Quick Start Methods (Deep Link Handlers)
    func startWorkPhaseDirectly() {
        // Navigate to Work phase (index 0) and start immediately
        logger.info("Quick start: Work phase")
        navigateToPhaseAndStart(phaseIndex: 0)
    }

    func startBreakPhaseDirectly() {
        // Navigate to Short Break phase (index 1) and start immediately
        logger.info("Quick start: Short Break phase")
        navigateToPhaseAndStart(phaseIndex: 1)
    }

    func startLongBreakPhaseDirectly() {
        // Navigate to Long Break phase (index 3) and start immediately
        logger.info("Quick start: Long Break phase")
        navigateToPhaseAndStart(phaseIndex: 3)
    }

    private func navigateToPhaseAndStart(phaseIndex: Int) {
        guard phaseIndex < phases.count else { return }

        // Stop current timer if running
        if timerRunning {
            timerCore.stopTimer()
            sessionManager.stopExtendedSession()
            cancelPendingNotifications()
        }

        // Navigate to target phase
        stateManager.currentPhaseIndex = phaseIndex
        currentPhaseName = phases[phaseIndex].name

        // Update UI state for new phase
        updateUIState()

        // Start timer immediately
        Task { @MainActor in
            playSound(.start)
            await startTimer()
        }
    }

    func appBecameActive() async {
        // 应用变为活跃状态时的处理
        // 注意：不在这里启动会话，因为：
        // 1. 如果计时器运行，startTimer() 已经启动了会话
        // 2. 重复调用会导致 "only single session allowed" 错误
        // 更新 Widget 状态
        updateSharedState()
        logger.debug("应用变为活跃，已更新 Widget 状态")
    }

    func appEnteredBackground() {
        // 应用进入后台时的处理
        // 注意：不在这里停止会话！
        // 后台会话的目的就是让计时器在后台继续运行
        // 会话应该由 toggleTimer() 或 resetXXX() 等显式操作停止
        // 更新 Widget 状态
        updateSharedState()
        logger.debug("应用进入后台，已更新 Widget 状态")
    }

    // MARK: - Widget Integration
    private func updateSharedState() {
        // 将 PhaseStatus 转换为 PhaseCompletionStatus (定义在 SharedTypes.swift)
        let completionStatus = stateManager.phaseCompletionStatus.map { status -> PhaseCompletionStatus in
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

        let state = SharedTimerState(
            currentPhaseIndex: currentPhaseIndex,
            remainingTime: remainingTime,
            timerRunning: timerRunning,
            currentPhaseName: currentPhaseName,
            lastUpdateTime: Date(),
            totalTime: totalTime,
            phases: phases.map { PhaseInfo(duration: $0.duration, name: $0.name, status: $0.status.rawValue) },
            completedCycles: stateManager.completedCycles,
            phaseCompletionStatus: completionStatus,
            hasSkippedInCurrentCycle: stateManager.hasSkippedInCurrentCycle
        )

        if let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
           let data = try? JSONEncoder().encode(state) {
            userDefaults.set(data, forKey: SharedTimerState.userDefaultsKey)
            userDefaults.synchronize()

            // 刷新 Widget
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("✅ 主App已更新Widget状态: phase=\(self.currentPhaseName), running=\(self.timerRunning), remaining=\(self.remainingTime)秒, total=\(self.totalTime)秒")
        } else {
            logger.error("❌ 主App无法更新Widget状态: UserDefaults或编码失败")
        }
    }

    // MARK: - Private Methods
    private func setupBindings() {
        // 绑定状态管理器的属性
        stateManager.$phases.assign(to: &$phases)
        stateManager.$currentPhaseIndex.assign(to: &$currentPhaseIndex)
        stateManager.$completedCycles.assign(to: &$completedCycles)
        stateManager.$hasSkippedInCurrentCycle.assign(to: &$hasSkippedInCurrentCycle)
        stateManager.$currentPhaseName.assign(to: &$currentPhaseName)
        stateManager.$phaseCompletionStatus.assign(to: &$phaseCompletionStatus)

        // 绑定计时器核心的属性
        timerCore.$remainingTime.assign(to: &$remainingTime)
        timerCore.$timerRunning.assign(to: &$timerRunning)
        timerCore.$totalTime.assign(to: &$totalTime)
        timerCore.$infiniteElapsedTime.assign(to: &$infiniteElapsedTime)
        timerCore.$isInFlowCountUp.assign(to: &$isInFlowCountUp)

        // 双向绑定无限模式
        $isInfiniteMode.sink { [weak self] newValue in
            self?.timerCore.isInfiniteMode = newValue
        }.store(in: &cancellables)

        // 监听心流模式开关变化，处理心流正计时状态下的关闭
        $isInfiniteMode.sink { [weak self] isEnabled in
            guard let self = self else { return }
            // 如果关闭心流模式，且当前处于心流正计时状态
            if !isEnabled && self.isInFlowCountUp && self.timerRunning {
                Task { @MainActor [weak self] in
                    await self?.stopFlowCountUp()
                }
            }
        }.store(in: &cancellables)
    }

    private func setupTimerCallbacks() {
        // 设置阶段完成时的回调
        timerCore.onPhaseCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.handlePhaseCompletion()
            }
        }

        // 设置定期更新回调（每分钟触发，用于 Widget 同步）
        timerCore.onPeriodicUpdate = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateSharedState()
                self.logger.debug("定期 Widget 更新已触发")
            }
        }
    }

    private func handlePhaseCompletion() {
        // 检查是否应该进入心流正计时模式
        // 条件：1) 心流模式已开启 2) 当前是工作阶段
        if isInfiniteMode && stateManager.isCurrentPhaseWorkPhase() {
            // 进入心流正计时模式
            timerCore.enterFlowCountUp()
            // 重新启动计时器（正计时）
            Task {
                await timerCore.startTimer()
            }
            logger.info("工作阶段完成，进入心流正计时模式")
            return
        }

        // 普通模式：依赖系统通知（已在 startTimer() 时预约）
        // 系统通知会自动触发，无需额外操作
        logger.info("阶段完成，依赖系统通知")
    }

    private func initializeState() {
        // 设置初始状态
        let initialDuration = phases.first?.duration ?? 1500
        remainingTime = initialDuration
        totalTime = initialDuration
        adjustedPhaseDuration = initialDuration  // 初始化调整后的时长
        timerCore.remainingTime = initialDuration
        timerCore.totalTime = initialDuration
        currentPhaseName = phases.first?.name ?? "Work"
        updateTomatoRingPosition()
    }

    private func startTimer() async {
        // 启动计时器核心 - 使用当前的 remainingTime 值
        await timerCore.startTimer()
        await sessionManager.startExtendedSession()

        // 只在非心流正计时状态下发送通知
        // 心流正计时不需要通知（已经处于正计时状态）
        if !isInFlowCountUp {
            // 安排通知 - 使用剩余时间（秒）
            notificationManager.sendNotification(
                for: .phaseCompleted,
                currentPhaseDuration: remainingTime,  // ✅ 修正：传递秒数，不除以60
                nextPhaseDuration: phases[(currentPhaseIndex + 1) % phases.count].duration / 60
            )
        }
    }

    private func startTransitionAnimation() {
        isTransitioning = true
        transitionProgress = 0

        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else { timer.invalidate(); return }
                self.transitionProgress += 0.1
                if self.transitionProgress >= 1 {
                    self.isTransitioning = false
                    timer.invalidate()
                }
            }
        }
    }

    private func updateUIState() {
        let duration = phases[currentPhaseIndex].duration
        remainingTime = duration
        totalTime = duration
        adjustedPhaseDuration = duration  // 阶段切换时重置为原始时长
        timerCore.remainingTime = duration
        timerCore.totalTime = duration
        currentPhaseName = phases[currentPhaseIndex].name
        updateTomatoRingPosition()
    }

    private func resetUIState() {
        currentCycleCompleted = false
        tomatoRingPosition = .zero
        isInResetMode = false
    }

    func updateTomatoRingPosition() {
        let progress = 1 - Double(remainingTime) / Double(totalTime)
        tomatoRingPosition = Angle(degrees: 360 * progress)
    }

    private func playSound(_ soundType: WKHapticType) {
        WKInterfaceDevice.current().play(soundType)
    }

    private func cancelPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        logger.info("已取消所有待发送和已送达的通知")
    }

    // MARK: - 兼容性属性和方法
    var currentPhase: Phase {
        return phases[currentPhaseIndex]
    }

    var notificationSent = false
}
