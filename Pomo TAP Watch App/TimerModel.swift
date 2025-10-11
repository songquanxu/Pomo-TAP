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
    let timerCore: TimerCore  // Made public for AOD frequency control
    let stateManager: TimerStateManager  // Made public for state publisher access
    let sessionManager: BackgroundSessionManager  // Made public for debugging
    private let notificationManager: NotificationManager
    let sharedStatePublisher: SharedTimerStatePublisher  // 集中状态管理器（公开访问）
    private let diagnosticsManager: DiagnosticsManager  // 诊断管理器（新增）

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
    @Published var isTransitioning = false
    @Published var transitionProgress: CGFloat = 0
    @Published var isInResetMode: Bool = false
    @Published var isInfiniteMode: Bool = false  // 心流模式开关
    @Published var infiniteElapsedTime: Int = 0  // 心流模式下的已过时间（秒）
    @Published var isInFlowCountUp: Bool = false  // 当前是否处于心流正计时状态
    @Published var enableRepeatNotifications: Bool = true  // 重复提醒开关（默认开启）

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "TimerModel")
    private var cancellables = Set<AnyCancellable>()
    private var transitionTimer: Timer?

    // MARK: - Constants
    private let repeatNotificationsKey = "enableRepeatNotifications"  // UserDefaults 键

    // MARK: - Phase Transition Source
    private enum PhaseTransitionSource: String, CaseIterable {
        case timerCompletion = "计时器自然结束"
        case userSkip = "用户手动跳过"
        case notificationResponse = "通知响应"
        case deepLink = "深链启动"
        case flowModeStop = "心流模式停止"
        case reset = "重置操作"
    }

    // MARK: - Initialization
    override init() {
        // 初始化各个管理器
        self.timerCore = TimerCore()
        self.stateManager = TimerStateManager()
        self.sessionManager = BackgroundSessionManager()
        self.notificationManager = NotificationManager(timerModel: nil)
        self.sharedStatePublisher = SharedTimerStatePublisher()  // 初始化状态发布器
        self.diagnosticsManager = DiagnosticsManager()  // 初始化诊断管理器

        super.init()

        // 从 UserDefaults 加载重复提醒设置
        if let savedValue = UserDefaults.standard.object(forKey: repeatNotificationsKey) as? Bool {
            self.enableRepeatNotifications = savedValue
        }

        // 设置代理
        self.notificationManager.timerModel = self

        // 设置诊断管理器依赖
        self.diagnosticsManager.setTimerModel(self)

        // 绑定状态
        setupBindings()

        // 设置计时器回调
        setupTimerCallbacks()

        // 初始化默认状态
        initializeState()
    }

    @MainActor deinit {
        transitionTimer?.invalidate()
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
        Task {
            await sharedStatePublisher.updateSharedState(from: self)
        }
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
        Task {
            await sharedStatePublisher.updateSharedState(from: self)
        }
    }

    func stopFlowCountUp() async {
        // 停止计时器并退出心流正计时模式
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()
        cancelPendingNotifications()

        // 退出心流正计时模式，获取已过时间
        let elapsedTime = timerCore.exitFlowCountUp()
        adjustedPhaseDuration = elapsedTime

        // 保存到当前阶段的 adjustedDuration 字段
        stateManager.phases[currentPhaseIndex].adjustedDuration = elapsedTime

        playSound(.stop)
        logger.info("心流正计时已停止，已过时间: \(elapsedTime / 60) 分钟")

        // 使用统一的阶段准备函数进入下一个阶段并自动启动
        await prepareNextPhase(source: .flowModeStop, shouldSkip: false)
        await startTimer()

        logger.info("心流模式停止后已自动进入下一阶段")
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

        playSound(.retry)
        logger.info("当前阶段已重置")
    }

    func skipCurrentPhase() async {
        // 使用统一的阶段准备函数处理跳过逻辑
        await prepareNextPhase(source: .userSkip, shouldSkip: true)

        // 自动开始下一个阶段
        await startTimer()

        playSound(.notification)
        logger.info("用户跳过当前阶段并自动开始下一阶段")
    }

    // 注意：moveToNextPhase 方法已被 prepareNextPhase 替代，保留用于向后兼容
    func moveToNextPhase(autoStart: Bool, skip: Bool = false) async {
        // 使用新的统一阶段准备函数
        await prepareNextPhase(source: skip ? .userSkip : .timerCompletion, shouldSkip: skip)

        // 如果需要自动开始，启动计时器
        if autoStart {
            await startTimer()
        }
    }

    func handleNotificationResponse() async {
        // 取消所有待发送的重复通知（用户已响应）
        await notificationManager.cancelRepeatNotifications()
        logger.info("用户响应通知，已取消重复提醒")

        // 防止重复响应：如果计时器正在运行，直接返回
        if timerRunning {
            logger.warning("通知响应被忽略：计时器已在运行")
            return
        }

        // 智能判断是否需要阶段切换
        // 如果 remainingTime == totalTime 且计时器未运行，说明阶段已自动切换，只需启动计时器
        if remainingTime == totalTime && remainingTime > 0 {
            logger.info("处理通知响应：阶段已切换，启动计时器")
            playSound(.start)
            await startTimer()
        } else {
            // 需要先切换阶段再启动
            logger.info("处理通知响应：进入下一阶段并启动计时器")
            await prepareNextPhase(source: .notificationResponse, shouldSkip: false)
            await startTimer()
        }
    }

    func requestNotificationPermission() {
        notificationManager.requestNotificationPermission()
    }

    // MARK: - Quick Start Methods (Deep Link Handlers)
    func startWorkPhaseDirectly() {
        // Navigate to Work phase (index 0) and start immediately
        logger.info("Quick start: Work phase")
        Task {
            await navigateToPhaseAndStart(phaseIndex: 0)
        }
    }

    func startBreakPhaseDirectly() {
        // Navigate to Short Break phase (index 1) and start immediately
        logger.info("Quick start: Short Break phase")
        Task {
            await navigateToPhaseAndStart(phaseIndex: 1)
        }
    }

    func startLongBreakPhaseDirectly() {
        // Navigate to Long Break phase (index 3) and start immediately
        logger.info("Quick start: Long Break phase")
        Task {
            await navigateToPhaseAndStart(phaseIndex: 3)
        }
    }

    private func navigateToPhaseAndStart(phaseIndex: Int) async {
        guard phaseIndex < phases.count else { return }

        // 停止当前计时器（如果运行中）
        if timerRunning {
            timerCore.stopTimer()
            sessionManager.stopExtendedSession()
            cancelPendingNotifications()
        }

        // 直接设置到目标阶段（深链场景下的特殊处理）
        stateManager.currentPhaseIndex = phaseIndex
        stateManager.resetPhaseCompletionStatus()  // 重置所有阶段状态
        stateManager.phaseCompletionStatus[phaseIndex] = .current  // 标记目标阶段为当前
        currentPhaseName = phases[phaseIndex].name
        stateManager.saveState()

        // 更新 UI 状态
        updateUIState()
        Task {
            await sharedStatePublisher.updateSharedState(from: self)
        }

        // 立即启动计时器
        playSound(.start)
        await startTimer()

        logger.info("深链导航完成：已跳转到阶段 \(phaseIndex) 并启动计时器")
    }

    func appBecameActive() async {
        // 应用变为活跃状态时的处理
        // 注意：不在这里启动会话，因为：
        // 1. 如果计时器运行，startTimer() 已经启动了会话
        // 2. 重复调用会导致 "only single session allowed" 错误
        // 更新 Widget 状态
        await sharedStatePublisher.updateSharedState(from: self)
        logger.debug("应用变为活跃，已更新 Widget 状态")
    }

    func appEnteredBackground() {
        // 应用进入后台时的处理
        // 关键修复：如果计时器未运行，立即停止后台会话
        // 这样可以让 Apple Watch 正常进入 AOD 省电模式
        if !timerRunning {
            sessionManager.stopExtendedSession()
            logger.info("应用进入后台且计时器未运行，已停止后台会话以恢复 AOD")
        } else {
            logger.debug("应用进入后台，计时器运行中，保持后台会话")
        }

        // 更新 Widget 状态
        Task {
            await sharedStatePublisher.updateSharedState(from: self)
        }
    }

    // MARK: - Phase Transition Core Logic

    /// 统一的阶段准备函数 - 处理所有阶段切换的核心逻辑
    /// 确保状态清理、更新、持久化的原子性和一致性
    @MainActor
    private func prepareNextPhase(
        source: PhaseTransitionSource,
        shouldSkip: Bool = false
    ) async {
        logger.info("🔄 开始阶段准备: \(source.rawValue), 跳过=\(shouldSkip)")

        // 1. 原子性状态清理 - 避免残留状态导致的问题
        timerCore.clearPausedState()

        if shouldClearNotifications(for: source) {
            cancelPendingNotifications()
        }
        sessionManager.stopExtendedSession()

        // 1.5 开始过渡动画
        startTransitionAnimation()

        // 2. 状态管理器更新
        if shouldSkip {
            stateManager.skipPhase()
            logger.info("📍 阶段已标记为跳过")
        } else {
            stateManager.moveToNextPhase()
            logger.info("📍 已进入下一阶段")
        }

        // 3. UI 状态同步
        updateUIState()

        // 4. 持久化与共享状态更新
        stateManager.saveState()
        await sharedStatePublisher.updateSharedState(from: self)

        logger.info("✅ 阶段准备完成: 当前阶段=\(self.currentPhaseName), 索引=\(self.currentPhaseIndex)")
    }

    /// 根据阶段切换来源判断是否需要取消现有通知
    private func shouldClearNotifications(for source: PhaseTransitionSource) -> Bool {
        switch source {
        case .timerCompletion:
            // 自然完成时保留通知，方便用户从通知启动下一阶段
            return false
        case .notificationResponse:
            // 响应通知时，重复提醒已在 handleNotificationResponse 中清理
            return false
        case .userSkip, .deepLink, .flowModeStop, .reset:
            return true
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

        // 监听重复提醒开关变化，保存到 UserDefaults 并取消已调度的通知
        $enableRepeatNotifications.sink { [weak self] newValue in
            guard let self = self else { return }
            UserDefaults.standard.set(newValue, forKey: self.repeatNotificationsKey)
            self.logger.info("重复提醒设置已保存: \(newValue)")

            // 关闭开关时取消所有待发送的重复通知
            if !newValue {
                Task {
                    await self.notificationManager.cancelRepeatNotifications()
                    self.logger.info("已取消所有待发送的重复通知")
                }
            }
        }.store(in: &cancellables)
    }

    private func setupTimerCallbacks() {
        // 设置阶段完成时的异步回调
        timerCore.onPhaseCompleted = { [weak self] in
            guard let self = self else { return }
            await self.handlePhaseCompletion()
        }

        // 设置定期更新异步回调（每分钟触发，用于 Widget 同步）
        timerCore.onPeriodicUpdate = { [weak self] in
            guard let self = self else { return }
            await self.handlePeriodicUpdate()
        }
    }

    /// 处理定期更新 - 用于 Widget 同步
    @MainActor
    private func handlePeriodicUpdate() async {
        await sharedStatePublisher.updateSharedState(from: self)
        logger.debug("定期 Widget 更新已触发")
    }

    /// 处理阶段完成 - 使用统一的阶段准备逻辑
    @MainActor
    private func handlePhaseCompletion() async {
        // 检查是否应该进入心流正计时模式
        // 条件：1) 心流模式已开启 2) 当前是工作阶段
        if isInfiniteMode && stateManager.isCurrentPhaseWorkPhase() {
            // 进入心流正计时模式
            timerCore.enterFlowCountUp()
            // 重新启动计时器（正计时）
            await timerCore.startTimer()
            logger.info("工作阶段完成，进入心流正计时模式")
            return
        }

        // 普通模式：使用统一的阶段准备函数
        await prepareNextPhase(source: .timerCompletion, shouldSkip: false)
        playSound(.notification)
        logger.info("阶段完成处理完毕")
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

        await sharedStatePublisher.updateSharedState(from: self)
    }

    private func startTransitionAnimation() {
        isTransitioning = true
        transitionProgress = 0

        transitionTimer?.invalidate()
        transitionTimer = Timer.scheduledTimer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(handleTransitionTick(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleTransitionTick(_ timer: Timer) {
        transitionProgress += 0.1
        if transitionProgress >= 1 {
            isTransitioning = false
            timer.invalidate()
            transitionTimer = nil
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
    }

    private func resetUIState() {
        currentCycleCompleted = false
        isInResetMode = false
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

    // MARK: - 诊断接口方法（新增）
    /// 获取完整系统诊断报告
    func getSystemDiagnosticReport() -> String {
        return diagnosticsManager.getFullDiagnosticReport()
    }

    /// 获取简化健康状态摘要
    func getSystemHealthSummary() -> String {
        return diagnosticsManager.getHealthSummary()
    }

    /// 手动触发系统健康检查
    func triggerSystemHealthCheck() {
        diagnosticsManager.triggerHealthCheck()
    }

    /// 清除诊断历史
    func clearDiagnosticHistory() {
        diagnosticsManager.clearDiagnosticHistory()
    }

    /// 获取当前系统健康状态
    var systemHealthStatus: SystemHealthStatus {
        return diagnosticsManager.overallHealthStatus
    }

    /// 设置深度链接管理器引用（供App调用）
    func setDeepLinkManager(_ deepLinkManager: DeepLinkManager) {
        diagnosticsManager.setDeepLinkManager(deepLinkManager)
    }
}
