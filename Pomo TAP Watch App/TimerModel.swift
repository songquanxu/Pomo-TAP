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
    @Published var isInfiniteMode: Bool = false  // 无限计时模式
    @Published var infiniteElapsedTime: Int = 0  // 无限模式下的已过时间（秒）

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

        // 重置状态
        stateManager.resetCycle()
        timerCore.resetTimer()
        resetUIState()

        playSound(.retry)
        logger.info("计时器已完全重置")
        updateSharedState()  // 更新 Widget
    }

    func stopInfiniteTimer() {
        // 无限模式下停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()

        // 更新当前阶段的实际时长为已过时间
        let elapsedMinutes = infiniteElapsedTime / 60
        adjustedPhaseDuration = infiniteElapsedTime

        playSound(.stop)
        logger.info("无限计时已停止，已过时间: \(elapsedMinutes) 分钟")
        updateSharedState()  // 更新 Widget
    }

    func resetCurrentPhase() {
        // 停止计时器
        timerCore.stopTimer()
        sessionManager.stopExtendedSession()

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

    func skipPhase() {
        hasSkippedInCurrentCycle = true
        timerCore.stopTimer()
        stateManager.skipPhase()
        playSound(.notification)
        updateSharedState()  // 更新 Widget
    }

    func moveToNextPhase(autoStart: Bool, skip: Bool = false) async {
        // 重置通知状态
        notificationSent = false

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
        await startTimer()
    }

    func requestNotificationPermission() {
        notificationManager.requestNotificationPermission()
    }

    func adjustTime(by delta: Int) {
        guard !timerRunning else { return }

        // 计算已经过去的时间（保持不变）
        let elapsedTime = totalTime - remainingTime

        // 调整总时长（不能小于已经过去的时间）
        let newTotalTime = max(elapsedTime, totalTime + delta)

        // 更新总时长
        totalTime = newTotalTime
        timerCore.totalTime = newTotalTime

        // 更新剩余时间（已走过的时间不变，剩余时间相应增减）
        remainingTime = newTotalTime - elapsedTime
        timerCore.remainingTime = remainingTime

        // 调整后的时长用于显示
        adjustedPhaseDuration = newTotalTime

        updateTomatoRingPosition()
        logger.info("调整阶段时长: \(delta)秒, 新总时长: \(newTotalTime)秒, 已过时间: \(elapsedTime)秒, 剩余时间: \(self.remainingTime)秒")
    }

    func appBecameActive() async {
        // 应用变为活跃状态时的处理
        await sessionManager.startExtendedSession()
    }

    func appEnteredBackground() {
        // 应用进入后台时的处理
        sessionManager.stopExtendedSession()
    }

    // MARK: - Widget Integration
    private func updateSharedState() {
        let state = SharedTimerState(
            currentPhaseIndex: currentPhaseIndex,
            remainingTime: remainingTime,
            timerRunning: timerRunning,
            currentPhaseName: currentPhaseName,
            lastUpdateTime: Date(),
            totalTime: totalTime,
            phases: phases.map { PhaseInfo(duration: $0.duration, name: $0.name, status: $0.status.rawValue) }
        )

        if let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName),
           let data = try? JSONEncoder().encode(state) {
            userDefaults.set(data, forKey: SharedTimerState.userDefaultsKey)
            userDefaults.synchronize()

            // 刷新 Widget
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("已更新 Widget 状态")
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

        // 双向绑定无限模式
        $isInfiniteMode.sink { [weak self] newValue in
            self?.timerCore.isInfiniteMode = newValue
            if newValue {
                // 开启无限模式时重置已过时间
                self?.infiniteElapsedTime = 0
                self?.timerCore.infiniteElapsedTime = 0
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
    }

    private func handlePhaseCompletion() {
        // 检查应用是否在前台
        let appState = WKExtension.shared().applicationState

        if appState == .active {
            // 应用在前台，播放自定义提醒
            Task {
                await playInAppAlert()
            }
        }

        // 无论前台还是后台，都记录日志
        logger.info("阶段完成，应用状态: \(appState.rawValue)")
    }

    private func playInAppAlert() async {
        // watchOS 只支持触觉反馈，不支持自定义系统音效
        // 使用增强的触觉反馈模式来创建独特的提醒

        // 第一组：快速双击
        WKInterfaceDevice.current().play(.notification)
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
        WKInterfaceDevice.current().play(.notification)

        // 短暂停顿
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒

        // 第二组：单击（强调）
        WKInterfaceDevice.current().play(.success)

        logger.info("应用内提醒已播放（仅触觉反馈）")
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
        // 不要重置 timerCore.totalTime 和 timerCore.remainingTime，
        // 因为它们可能已经被 Digital Crown 调整过
        await timerCore.startTimer()
        await sessionManager.startExtendedSession()

        // 安排通知
        notificationManager.sendNotification(
            for: .phaseCompleted,
            currentPhaseDuration: remainingTime / 60,
            nextPhaseDuration: phases[(currentPhaseIndex + 1) % phases.count].duration / 60
        )
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

    // MARK: - 兼容性属性和方法
    var currentPhase: Phase {
        return phases[currentPhaseIndex]
    }

    var notificationSent = false
}
