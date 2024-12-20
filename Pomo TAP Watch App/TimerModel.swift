import SwiftUI
import WatchKit
import Combine
import UserNotifications
import os
import CoreData
import WidgetKit

// 定义阶段状态的枚举，表示番茄钟的不同状态
enum PhaseStatus: String, Codable {
    case notStarted, current, normalCompleted, skipped
}

// 定义一个阶段结构体，包含持续时间、名称和状态
struct Phase: Codable {
    let duration: Int // 阶段的持续时间（以秒为单位）
    let name: String // 阶段的名称
    var status: PhaseStatus // 阶段的状态
}

// TimerModel 类，负责管理番茄钟的状态和逻辑
@MainActor
class TimerModel: NSObject, ObservableObject {
    @Published var phases: [Phase] // 当前阶段数组
    @Published var currentPhaseIndex: Int // 当前阶段索引
    @Published var remainingTime: Int // 剩余时间
    @Published var timerRunning: Bool // 计时器是否正在运行
    @Published var completedCycles: Int // 完成的周期数
    @Published var lastBackgroundDate: Date? // 上次进入后台的时间
    @Published var hasSkippedInCurrentCycle = false // 当前是否跳过
    @Published var isResetState = false // 是否处于重置状态
    @Published var isInDecisionMode = false // 是否处于决策模式
    @Published var isInCooldownMode = false // 是否处于冷却模式
    @Published var currentCycleCompleted = false // 当前周期是否完成
    @Published var tomatoRingPosition: Angle = .zero // 番茄环的位置
    @Published var isTransitioning = false // 是否正在过渡
    @Published var transitionProgress: CGFloat = 0 // 过渡进度
    @Published var decisionStartAngle: Angle = .zero // 决策开始角度
    @Published var decisionRingPosition: Angle = .zero // 决策环位置
    @Published var cooldownStartAngle: Angle = .zero // 冷却开始角度
    @Published var cooldownEndAngle: Angle = .zero // 冷却结束角度
    @Published var cooldownRingPosition: Angle = .zero // 冷却环位置
    @Published var isInResetMode: Bool = false // 是否处于重置模式
    @Published var decisionProgress: CGFloat = 0 // 决策进度
    @Published var cooldownProgress: CGFloat = 0 // 冷却进度
    @Published var decisionEndAngle: Angle = .zero // 决策结束角度
    @Published var phaseCompletionStatus: [PhaseStatus] = [] // 各阶段的完成状态
    @Published var totalTime: Int = 0 // 总时间
    @Published var notificationSent = false // 是否已发送通知
    @Published var currentPhaseName: String = "" // 当前阶��名称

    var cyclePhaseCount = 0 // 当前周期的阶段计数
    var lastPhase = 0 // 上一个阶段索引
    var lastUsageTime: TimeInterval = 0 // 上次使用时间
    var lastCycleCompletionTime: TimeInterval = 0 // 上次周期完成时间

    private let userDefaults: UserDefaults
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "TimerModel")
    private let persistentContainer: NSPersistentContainer
    private var timer: DispatchSourceTimer?
    private var startTime: Date?
    private var pausedRemainingTime: Int?
    private var decisionTimer: Timer?
    private var cooldownTimer: Timer?
    private var extendedSession: WKExtendedRuntimeSession? {
        willSet {
            if let oldSession = extendedSession, oldSession !== newValue {
                // 确保在状态改变前记录当前状态
                let currentState = oldSession.state
                
                if currentState == .running {
                    sessionState = .stopping
                    // 使用串行队列确保操作顺序
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        // 再次检查状态，确保会话仍然有效
                        if oldSession === self.extendedSession {
                            oldSession.invalidate()
                            self.logger.info("清理旧会话: \(oldSession)")
                        }
                    }
                }
            }
        }
    }
    var notificationDelegate: NotificationDelegate?
    private var endTime: Date?
    private let launchedBeforeKey = "launchedBefore"

    // 添加新的常量
    private let PAUSE_RESET_THRESHOLD: TimeInterval = 1800  // 30分钟
    private let CYCLE_RESET_THRESHOLD: TimeInterval = 28800 // 8小时
    private let LAST_PAUSE_TIME_KEY = "lastPauseTime"
    private let LAST_ACTIVE_TIME_KEY = "lastActiveTime"

    // 会话状态枚举
    private enum SessionState {
        case none        // 无会话
        case starting    // 会话启动中
        case running     // 会话运行中
        case stopping    // 会话停止中
        case invalid     // 会话无效
        
        var description: String {
            switch self {
            case .none: return "无会话"
            case .starting: return "启动中"
            case .running: return "运行中"
            case .stopping: return "停止"
            case .invalid: return "无效"
            }
        }
    }

    // 会话状态属性
    @Published private var sessionState: SessionState = .none {
        didSet {
            if oldValue != self.sessionState {
                self.logger.debug("会话状态变更: \(oldValue.description) -> \(self.sessionState.description)")
            }
        }
    }

    // 会话引用计数
    @Published private var sessionRetainCount: Int = 0 {
        didSet {
            if oldValue != self.sessionRetainCount {
                self.logger.debug("会话引用计数变更: \(oldValue) -> \(self.sessionRetainCount)")
            }
        }
    }

    // 添加这个属性来跟踪上一次的进度
    private var lastProgress: Double = 0.0

    // 初始化方法，设置初始阶段和状态
    override init() {
        let initialPhases = [
            Phase(duration: 25 * 60, name: "Work", status: .current),
            Phase(duration: 5 * 60, name: "Short Break", status: .notStarted),
            Phase(duration: 25 * 60, name: "Work", status: .notStarted),
            Phase(duration: 15 * 60, name: "Long Break", status: .notStarted)
        ]
        
        self.phases = initialPhases
        self.currentPhaseIndex = 0
        self.remainingTime = initialPhases[0].duration
        self.timerRunning = false
        self.completedCycles = 0
        self.totalTime = initialPhases[0].duration
        self.currentPhaseName = initialPhases[0].name

        self.userDefaults = UserDefaults.standard
        self.persistentContainer = NSPersistentContainer(name: "PomoTAPModel")

        super.init()
        self.notificationDelegate = NotificationDelegate(timerModel: self)

        self.persistentContainer.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                self.logger.error("Unresolved error \(error), \(error.userInfo)")
            }
        }
       
        if !userDefaults.bool(forKey: launchedBeforeKey) {
            resetCycle()
            userDefaults.set(true, forKey: launchedBeforeKey)
        } else {
            loadState()
        }
        self.resetPhaseCompletionStatus()

        // 确保共享 UserDefaults 可访问
        if let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) {
            logger.info("成功访问共享 UserDefaults: \(SharedTimerState.suiteName)")
        } else {
            logger.error("无法访问共享 UserDefaults: \(SharedTimerState.suiteName)")
        }
    }
    
    // 获取当前阶段
    var currentPhase: Phase {
        return phases[currentPhaseIndex]
    }

    // 保存状态
    func saveState() {
        let state = TimerState(
            currentPhaseIndex: currentPhaseIndex,
            remainingTime: remainingTime,
            timerRunning: timerRunning,
            totalTime: totalTime,
            phaseCompletionStatus: phaseCompletionStatus,
            currentPhaseName: currentPhaseName,
            completedCycles: completedCycles
        )
        
        // 使用 do-catch 处理编码错误
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(state)
            userDefaults.set(data, forKey: "timerState")
            userDefaults.synchronize()
            logger.info("状态保存成功")
        } catch {
            logger.error("状态保存失败: \(error.localizedDescription)")
        }
        
        // 记录暂停和活动时间
        if !timerRunning {
            userDefaults.set(Date().timeIntervalSince1970, forKey: LAST_PAUSE_TIME_KEY)
        }
        userDefaults.set(Date().timeIntervalSince1970, forKey: LAST_ACTIVE_TIME_KEY)
        
        // 添加共享状态更新
        updateSharedState()
    }

    // 重置阶段完成状态
    func resetPhaseCompletionStatus() {
        phaseCompletionStatus = Array(repeating: .notStarted, count: phases.count)
        phaseCompletionStatus[currentPhaseIndex] = .current
    }

    // 更新重置模式
    func updateResetMode() {
        isInResetMode = isInDecisionMode || isInCooldownMode
    }

    // 开始决策模式
    func startDecisionMode() {
        guard !isInCooldownMode else { return }
        
        isInDecisionMode = true
        isInCooldownMode = false
        decisionProgress = 0
        isResetState = true
        
        decisionStartAngle = tomatoRingPosition
        decisionEndAngle = Angle(degrees: 360)
        decisionRingPosition = decisionStartAngle
        
        let duration = 3.0
        
        decisionTimer?.invalidate()
        decisionTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else { timer.invalidate(); return }
                self.updateDecisionProgress(duration: duration)
                if self.decisionProgress >= 1 {
                    if self.isInDecisionMode {
                        await self.completeSkip() // 移除 await
                    }
                    timer.invalidate()
                }
            }
        }
        
        updateResetMode()
    }

    // 更新决策进度
    private func updateDecisionProgress(duration: Double) {
        decisionProgress += 0.01 / duration
        decisionRingPosition = decisionStartAngle + Angle(degrees: (decisionEndAngle.degrees - decisionStartAngle.degrees) * decisionProgress)
        
        if decisionProgress >= 0.66 && decisionProgress < 0.67 {
            WKInterfaceDevice.current().play(.notification)
        } else if decisionProgress >= 0.33 && decisionProgress < 0.34 {
            WKInterfaceDevice.current().play(.notification)
        }
    }

    // 取消决策模式
    func cancelDecisionMode() {
        isInDecisionMode = false
        decisionTimer?.invalidate()
        startCooldownMode()
        updateResetMode()
    }
    
    // 开始冷却模式
    private func startCooldownMode() {
        isInCooldownMode = true
        isInDecisionMode = false
        isResetState = true
        cooldownProgress = 0
        
        cooldownStartAngle = tomatoRingPosition
        cooldownEndAngle = decisionRingPosition
        cooldownRingPosition = cooldownEndAngle
        
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else { timer.invalidate(); return }
                self.updateCooldownProgress()
                if self.cooldownProgress >= 1 {
                    self.finishCooldown()
                    timer.invalidate()
                }
            }
        }
        
        updateResetMode()
    }

    // 更新冷却进度
    private func updateCooldownProgress() {
        cooldownProgress += 0.01 / 3.0
        cooldownRingPosition = cooldownEndAngle - Angle(degrees: (cooldownEndAngle.degrees - cooldownStartAngle.degrees) * cooldownProgress)
    }

    // 完成冷却
    private func finishCooldown() {
        isInCooldownMode = false
        isResetState = false
        cooldownProgress = 0
        updateResetMode()
    }

    // 完成跳过
    func completeSkip() async { // 添加 async
        isInDecisionMode = false
        isInCooldownMode = false
        isResetState = false
        decisionProgress = 0
        await moveToNextPhase(autoStart: true, skip: true) // 添加 await
        updateResetMode()
    }

    // 跳阶段
    func skipPhase() {
        hasSkippedInCurrentCycle = true
        stopTimer()
        isResetState = false
        WKInterfaceDevice.current().play(.notification)
        updateResetMode()
    }

    // 开始下一个阶段
//    func startNextPhase() async { // 添加 async
////        isAppActive = true
//        await moveToNextPhase(autoStart: true, skip: false)
//    }

    // 移动到下一个阶段
    func moveToNextPhase(autoStart: Bool, skip: Bool = false) async {
        // 重置通知状态
        notificationSent = false
        
        // 开始过渡动画
        startTransitionAnimation()
        
        // 检查是否跳过
        let isSkipped = skip
        // 检查是否正常完成
        let isNormalCompletion = remainingTime <= 0 && !isSkipped
        
        // 更新当前阶段的完成状态
        phaseCompletionStatus[currentPhaseIndex] = isNormalCompletion ? .normalCompleted : .skipped
        // 保存阶段完成状态
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
        
        // 更新剩余时���和总时间
        remainingTime = phases[currentPhaseIndex].duration
        totalTime = phases[currentPhaseIndex].duration
        // 增加周期计数
        cyclePhaseCount += 1
        
        // 更新上一个阶段和使用时间
        lastPhase = currentPhaseIndex
        lastUsageTime = Date().timeIntervalSince1970
        
        // 停止计时器
        stopTimer()
        timerRunning = false
        
        // 重置番茄环的位置
        tomatoRingPosition = .zero
        
        // 更新当前阶段的名称
        currentPhaseName = phases[currentPhaseIndex].name
        // 保存状态
        saveState()
        // 更新重置模式
        updateResetMode()
        
        // 果是正常完成并且应用处于活动状态，发送触觉反馈
        // if isNormalCompletion && isAppActive() {
        //     sendHapticFeedback()
        // }

        // 如果是自动开始，启动计时器
        if autoStart {
            await startTimer()
        } else {
            // 否则设置为重置状态
            isResetState = true
            updateResetMode()
        }

        // 发送阶段改变的通知
        NotificationCenter.default.post(name: .phaseChanged, object: self, userInfo: ["newPhase": currentPhaseIndex])
    }

    // 完成周期
    private func completeCycle() {
        if !hasSkippedInCurrentCycle {
            completedCycles += 1
            lastCycleCompletionTime = Date().timeIntervalSince1970
        }
        cyclePhaseCount = 0
        hasSkippedInCurrentCycle = false
        checkAndUpdateCompletedCycles()
        resetPhaseCompletionStatus()
        currentCycleCompleted = true
    }

    // 切换计时器状态
    func toggleTimer() async {
        if timerRunning {
            // 先停止计时器
            playSound(.stop)
            stopTimer()
            
            // 等待一小段时间止会话
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
            stopExtendedSession()
        } else {
            playSound(.start)
            await startTimer()
        }
    }

    // 启动计时器
    private func startTimer() async {
        guard !timerRunning else { return }
        
        startTime = Date()
        endTime = startTime?.addingTimeInterval(Double(remainingTime))
        
        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: .main)
        timer?.schedule(deadline: .now(), repeating: .seconds(1))
        timer?.setEventHandler { [weak self] in
            self?.updateTimer()
        }
        timer?.resume()
        
        await startExtendedSession()
        timerRunning = true
        notificationSent = false
        
        // 在启动计时器时安排通知
        notificationDelegate?.sendNotification(
            for: .phaseCompleted,
            currentPhaseDuration: remainingTime / 60,
            nextPhaseDuration: phases[(currentPhaseIndex + 1) % phases.count].duration / 60
        )
        
        logger.info("计时器已启动。当前阶段: \(self.currentPhaseName)，剩余时间: \(self.remainingTime) 秒。")
    }

    // 停止计时器
    private func stopTimer() {
        // 检查计时器是否正在运行，如果不是，则直接返回
        guard timerRunning else { return }
        
        timer?.cancel()
        // 将计时器设置为nil，以便释放资源
        timer = nil
        // 将当前剩余时间保存为暂停的剩余时间
        pausedRemainingTime = remainingTime
        // 停止扩展的会话
        stopExtendedSession()
        // 将计时器运行状态设置为false
        timerRunning = false
        
        // 移除所有待处理的通知请求
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
        // 记录日志，显示计时器已停止的信息
        logger.info("计时器已停止。剩余时间: \(self.remainingTime) 秒。")
    }

    // 更新计时器
    func updateTimer() {
        guard timerRunning, let endTime = endTime else { return }
        let now = Date()
        let newRemainingTime = max(Int(endTime.timeIntervalSince(now)), 0)
        
        if newRemainingTime != self.remainingTime {
            self.remainingTime = newRemainingTime
            updateTomatoRingPosition()
            
            // 如果时间到达零，立即处理
            if newRemainingTime == 0 {
                Task { @MainActor in
                    stopTimer()
                    await handlePhaseCompletion()
                }
                return
            }

            // 每次更新都刷新共享状态
            updateSharedState()
            
            // 安排下一次后台刷新
            let appState = WKExtension.shared().applicationState
            if appState == .active {
                scheduleNextBackgroundRefresh()
            }
        }
        
        // 每分钟同步一次系统时间
        if Int(now.timeIntervalSince1970) % 60 == 0 {
            syncWithSystemTime()
        }
    }

    private func syncWithSystemTime() {
        guard let endTime = endTime else {
            logger.error("endTime 未设置，无法同步时间。")
            return
        }
        let now = Date()
        let adjustedRemainingTime = max(Int(endTime.timeIntervalSince(now)), 0)
        let timeDifference = abs(adjustedRemainingTime - self.remainingTime)
        
        if timeDifference > 1 {
            self.remainingTime = adjustedRemainingTime
            logger.info("时间同步成功。调整后的剩余时间: \(self.remainingTime) 秒。")
        } else {
            logger.debug("时间步检查通过。当前剩余时间: \(self.remainingTime) 秒，无需调整。")
        }
    }

    // 处理阶段完成##
    private func handlePhaseCompletion() async {
        Task { @MainActor in
            
            
            // 移动到下一阶段
            await moveToNextPhase(autoStart: false, skip: false)
            
            // 只在前台播放音效
            let appState = await checkApplicationState()
            if appState == .active {
                playSound(.success)
                sendHapticFeedback()
            }

            notificationSent = false
            saveState()
        }
    }

    // 更新番茄环位置
    func updateTomatoRingPosition() {
        let progress = 1 - Double(remainingTime) / Double(totalTime)
        tomatoRingPosition = Angle(degrees: 360 * progress)
    }

    // 播放声音
    private func playSound(_ soundType: WKHapticType) {
        WKInterfaceDevice.current().play(soundType)
    }

    // 重置周期
    func resetCycle() {
        // 先停止所有计时器
        cooldownTimer?.invalidate()
        decisionTimer?.invalidate()
        stopTimer()
        
        // 确保扩展会话正确停止
        Task { @MainActor in
            // 先停止扩展会话
            stopExtendedSession()
            
            // 等待会话完全停止
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
            
            // 重所有状态
            self.currentPhaseIndex = 0
            self.remainingTime = self.phases[0].duration
            self.totalTime = self.phases[0].duration
            self.cyclePhaseCount = 0
            self.hasSkippedInCurrentCycle = false
            self.timerRunning = false  // 确保计时器状态正确
            self.isResetState = false
            self.isInDecisionMode = false
            self.isInCooldownMode = false
            self.resetPhaseCompletionStatus()
            self.currentCycleCompleted = false
            self.tomatoRingPosition = .zero
            self.currentPhaseName = self.phases[0].name
            self.updateTomatoRingPosition()
            
            // 放重置音效
            WKInterfaceDevice.current().play(.retry)
            
            // 保存状态
            self.saveState()
            self.updateResetMode()
            self.pausedRemainingTime = nil
            
            self.logger.info("计时器已完全重置")
        }
    }
   
    // 检查并更新完成的周期
    func checkAndUpdateCompletedCycles() {
        let currentTime = Date().timeIntervalSince1970
        if currentTime - lastCycleCompletionTime >= 86400 {
            completedCycles = 0
            lastCycleCompletionTime = currentTime
            saveState()
        }
    }

    // 启动过渡动画
    func startTransitionAnimation() {
        isTransitioning = true
        transitionProgress = 0
        
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else { timer.invalidate(); return }
                self.transitionProgress += 0.05
                if self.transitionProgress >= 1 {
                    self.isTransitioning = false
                    timer.invalidate()
                }
            }
        }
    }

    // 播放触觉反馈
    private func sendHapticFeedback() {
        WKInterfaceDevice.current().play(.success)
    }

    // 启动扩展会话
    func startExtendedSession() async {
        guard timerRunning else {
            logger.debug("计时器未运行，不启动扩展会话")
            return
        }
        
        // 检查用状态
        guard WKExtension.shared().applicationState == .active else {
            logger.warning("应用不在活跃状态，无法启动会话")
            return
        }
        
        // 增加引用计数
        sessionRetainCount += 1
        
        if let currentSession = extendedSession {
            switch currentSession.state {
            case .running:
                logger.debug("会话已��运行中")
                return
            case .invalid:
                cleanupSession()
            case .notStarted:
                cleanupSession()
            default:
                cleanupSession()
            }
        }
        
        sessionState = .starting
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        
        // 使用 async 确保状态更新在主队列执行
        await MainActor.run {
            extendedSession = session
            session.start()
        }
        
        logger.info("正在启动新的扩展会话: \(session)")
    }

    // 停止扩展话
    func stopExtendedSession() {
        guard let session = extendedSession else { return }
        
        // 增加引用计数检查
        if sessionRetainCount > 0 {
            sessionRetainCount -= 1
            if sessionRetainCount > 0 {
                logger.debug("会话仍被其他地方使用，延迟停止")
                return
            }
        }
        
        // 使用临时变量保存当前会话
        let currentSession = session
        
        switch currentSession.state {
        case .running:
            sessionState = .stopping
            
            // 使用串行队列确保操作顺序
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                // 再次检查状态和会话标识
                if currentSession === self.extendedSession && currentSession.state == .running {
                    // 先清除引用，再停止会话
                    self.extendedSession = nil
                    self.sessionState = .none
                    
                    // 最后执行无效
                    currentSession.invalidate()
                    self.logger.info("正常停止运行中的会话: \(currentSession)")
                } else {
                    self.logger.debug("会话状态已改变，跳过停止操作")
                    // 确保状态一致性
                    self.extendedSession = nil
                    self.sessionState = .none
                }
            }
            
        case .invalid:
            logger.debug("会话已失效，直接清理")
            extendedSession = nil
            sessionState = .none
            
        case .notStarted:
            logger.debug("会话未启动，直接清理")
            extendedSession = nil
            sessionState = .none
            
        default:
            logger.warning("未知的会话状态: \(currentSession.state.rawValue)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.extendedSession = nil
                self.sessionState = .none
                currentSession.invalidate()
            }
        }
    }

    // 应用变为活动状态
    func appBecameActive() async {
        // 检查并重置进度
        await checkAndResetProgress()
        
        // 同步时间
        synchronizeTimerState()
        
        // 检查并更新UI状态
        updatePhaseCompletionStatus()
        
        // 确保计时器状态正确
        if timerRunning {
            await startTimer()
        }
        
        // 通知UI更新
        NotificationCenter.default.post(
            name: .timerStateUpdated,
            object: self
        )
    }

    // 应用变为非活动状态
    func appBecameInactive() {
        saveState()
        logger.info("应用变为非活状态，已保存当前状态。")
    }

    // 应用进入后台
    func appEnteredBackground() {
        Task {
            guard timerRunning else {
                logger.debug("计时器未运行，无需处理后台任务")
                return
            }
            
            // 先保存状态
            saveState()
            
            // 确保在正确的时机启动会话
            let appState = await checkApplicationState()
            if appState == .active {
                await startExtendedSession()
            }
            
            // 安排后台刷新
            scheduleBackgroundRefresh()
            
            logger.info("应用已进入后台模式，已成必要设置")
        }
    }

    // 安排后台刷新
    func scheduleBackgroundRefresh() {
        let refreshDate = Date().addingTimeInterval(60)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: refreshDate, userInfo: nil) { [weak self] error in
            if let error = error {
                self?.logger.error("安排后台刷新失败: \(error.localizedDescription)")
            } else {
                self?.logger.info("后台刷新已成功安排，刷新时间: \(refreshDate)。")
            }
        }
    }

    // 在后台更新计时器
    func updateInBackground() async {
        if timerRunning {
            let appState = await checkApplicationState()
            guard appState != .active else { return }
            
            // 同步时间会自动处理阶段完成
            syncWithSystemTime()
            
            // 只处理通知和后台刷新
            if remainingTime <= 0 && !notificationSent {
                notificationDelegate?.sendNotification(
                    for: .phaseCompleted,
                    currentPhaseDuration: phases[currentPhaseIndex].duration / 60,
                    nextPhaseDuration: phases[(currentPhaseIndex + 1) % phases.count].duration / 60
                )
                notificationSent = true
            } else {
                scheduleNextBackgroundRefresh()
            }
            
            updateSharedState()
        }
        
        saveState()
    }

    // 设置通知代理
    func setNotificationDelegate(_ delegate: NotificationDelegate) {
        self.notificationDelegate = delegate
    }

    // 移动到指定阶段
    func moveToPhase(phaseIndex: Int) {
        currentPhaseIndex = phaseIndex
        remainingTime = phases[currentPhaseIndex].duration
        totalTime = phases[currentPhaseIndex].duration
        currentPhaseName = phases[currentPhaseIndex].name
        updateTomatoRingPosition()
        saveState()
    }
   
    // 加载状态
    private func loadState() {
        if let data = userDefaults.data(forKey: "timerState"),
           let state = try? JSONDecoder().decode(TimerState.self, from: data) {
            Task { @MainActor in
                // 先加载基本状态
                currentPhaseIndex = state.currentPhaseIndex
                remainingTime = state.remainingTime
                timerRunning = state.timerRunning
                completedCycles = state.completedCycles
                totalTime = state.totalTime
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
                
                // 如果计器在运行，恢复计时器状态
                if timerRunning {
                    await startTimer()
                }
                
                updateTomatoRingPosition()
            }
        } else {
            // 如果没有保存的状态，置到初始状态
            resetCycle()
        }
    }

    // 加载阶段完成状态
    private func loadPhaseCompletionStatus() {
        if let data = userDefaults.data(forKey: "phaseCompletionStatus"),
           let statuses = try? JSONDecoder().decode([PhaseStatus].self, from: data) {
            phaseCompletionStatus = statuses
        } else {
            resetPhaseCompletionStatus()
        }
    }

    // 保存阶段完成状态
    private func savePhaseCompletionStatus() {
        if let data = try? JSONEncoder().encode(phaseCompletionStatus) {
            userDefaults.set(data, forKey: "phaseCompletionStatus")
        }
    }

    private func checkAndHandleTimeSyncIssues() {
        if let endTime = endTime {
            let now = Date()
            if now > endTime && remainingTime > 0 {
                logger.warning("检测到时间不同步问题。当前时间: \(now), 预期结束时间: \(endTime), 剩余时间: \(self.remainingTime)")
                // handlePhaseCompletion()
            }
        }
    }

    // 更新阶段完成状态并同步到UI显示
    func updatePhaseCompletionStatus() {
        // 初始化状态数组
        if self.phaseCompletionStatus.count != self.phases.count {
            self.phaseCompletionStatus = Array(repeating: .notStarted, count: self.phases.count)
        }
        
        // 更新各阶段状态
        for index in 0..<self.phases.count {
            if index < self.currentPhaseIndex {
                // 保持已跳过的状态,他标记为已完成
                if self.phaseCompletionStatus[index] != .skipped {
                    self.phaseCompletionStatus[index] = .normalCompleted
                }
            } else if index == self.currentPhaseIndex {
                // 当前阶段标记进行中
                self.phaseCompletionStatus[index] = .current
            } else {
                // 后续阶标记为未开始
                self.phaseCompletionStatus[index] = .notStarted
            }
        }
        
        // 持久化保存状态
        self.savePhaseCompletionStatus()
        
        // 发送通知以新UI
        NotificationCenter.default.post(
            name: .phaseChanged, 
            object: self, 
            userInfo: ["phaseStatus": self.phaseCompletionStatus]
        )
        
        self.logger.debug("阶段状态已更新并同步到UI: \(self.phaseCompletionStatus)")
    }

    // 修改 synchronizeTimerState 方法
    private func synchronizeTimerState() {
        if timerRunning {
            guard let endTime = endTime else {
                stopTimer()
                return
            }
            
            let now = Date()
            if now >= endTime {
                Task { @MainActor in
                    remainingTime = 0
                    await handlePhaseCompletion()
                }
            } else {
                remainingTime = Int(endTime.timeIntervalSince(now))
                updateTomatoRingPosition()
            }
        }
        
        checkAndUpdateCompletedCycles()
    }

    // 添加错误恢复机制
    private func recoverFromError() {
        // 停止所有计时器
        stopTimer()
        cooldownTimer?.invalidate()
        decisionTimer?.invalidate()
        
        // 重置会话
        stopExtendedSession()
        
        // 恢复到上一个有效状态
        loadState()
        
        // 通知UI更新
        NotificationCenter.default.post(
            name: .timerStateUpdated,
            object: self
        )
    }

    // 添加进度检查方法
    private func checkAndResetProgress() async {
        if let endTime = endTime {
            let now = Date()
            if now >= endTime && timerRunning {
                // 使用 synchronizeTimerState 来处理，避免重复调用
                synchronizeTimerState()
            }
        }
    }

    // 添加静默重置方法
    private func resetCycleQuietly() {
        currentPhaseIndex = 0
        remainingTime = phases[0].duration
        totalTime = phases[0].duration
        cyclePhaseCount = 0
        hasSkippedInCurrentCycle = false
        timerRunning = false
        isResetState = false
        isInDecisionMode = false
        isInCooldownMode = false
        resetPhaseCompletionStatus()
        currentCycleCompleted = false
        tomatoRingPosition = .zero
        currentPhaseName = phases[0].name
        updateTomatoRingPosition()
        saveState()
    }

    // 添加清理会话的辅助方法
    private func cleanupSession() {
        if let session = extendedSession {
            session.invalidate()
            extendedSession = nil
        }
    }

    // 添加公开方法用于处理通知响应
    func handleNotificationResponse() async {
        await startTimer()
    }

    // 修改 updateSharedState 方法
    private func updateSharedState() {
        let phaseInfos = phases.map { phase in
            PhaseInfo(
                duration: phase.duration,
                name: phase.name,
                status: phase.status.rawValue
            )
        }
        
        let sharedState = SharedTimerState(
            currentPhaseIndex: currentPhaseIndex,
            remainingTime: remainingTime,
            timerRunning: timerRunning,
            currentPhaseName: currentPhaseName,
            lastUpdateTime: Date(),
            totalTime: totalTime,
            phases: phaseInfos
        )
        
        if let data = try? JSONEncoder().encode(sharedState) {
            if let userDefaults = UserDefaults(suiteName: SharedTimerState.suiteName) {
                userDefaults.set(data, forKey: SharedTimerState.userDefaultsKey)
                userDefaults.synchronize()
                
                // 添加调试日志
                logger.debug("""
                    共享状态已更新:
                    - phase: \(self.currentPhaseName)
                    - running: \(self.timerRunning)
                    - remaining: \(self.remainingTime)
                    - group: \(SharedTimerState.suiteName)
                    - key: \(SharedTimerState.userDefaultsKey)
                    """)
                
                // 通知 Widget 更新
                WidgetCenter.shared.reloadAllTimelines()
            } else {
                logger.error("无法访问共享 UserDefaults: \(SharedTimerState.suiteName)")
            }
        } else {
            logger.error("编码共享状态失败")
        }
    }

    // 修改 scheduleNextBackgroundRefresh 方法
    private func scheduleNextBackgroundRefresh() {
        // 计算下一个整分钟的时间
        let calendar = Calendar.current
        let now = Date()
        guard let nextMinute = calendar.date(
            bySetting: .second,
            value: 0,
            of: calendar.date(byAdding: .minute, value: 1, to: now) ?? now
        ) else { return }
        
        // 安排后台刷新
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: nextMinute,
            userInfo: nil
        ) { [weak self] error in
            if let error = error {
                self?.logger.error("安排后台刷新失败: \(error.localizedDescription)")
            } else {
                self?.logger.info("后台刷新已安排，下次刷新时间: \(nextMinute)")
            }
        }
    }

    // 添加应用状态检查方法
    private func checkApplicationState() async -> WKApplicationState {
        return WKExtension.shared().applicationState
    }

    // 在类属性部分添加应用状态检查方法
    // private func isAppActive() async -> Bool {
    //     return await WKExtension.shared().applicationState == .active
    // }
}

// 在 TimerModel 类中添加
extension Notification.Name {
    static let timerCompleted = Notification.Name("timerCompleted")
    static let phaseChanged = Notification.Name("phaseChanged")
    static let timerStateUpdated = Notification.Name("timerStateUpdated")
}

// 保持 TimerState 结构体的定义，用于 Widget 和 UserDefaults
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

// 添加 NotificationEvent 枚举
enum NotificationEvent {
    case phaseCompleted
    // 可以根据需要添加其他事件
}

// 修改 TimerModelContainer
@MainActor
struct TimerModelContainer {
    static let shared = TimerModelContainer()
    let timerModel: TimerModel
    let notificationDelegate: NotificationDelegate

    private init() {
        let model = TimerModel()
        self.timerModel = model
        self.notificationDelegate = NotificationDelegate(timerModel: model)
        model.setNotificationDelegate(self.notificationDelegate)
    }
}

// 将 WKExtendedRuntimeSessionDelegate 方法移到扩中
extension TimerModel: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard extendedSession === extendedRuntimeSession else {
                logger.warning("收到过期会话的启动通知")
                return
            }
            
            sessionState = .running
            logger.info("会话成功启动: \(extendedRuntimeSession)")
            
            // 确保会话启动后立即安排后台刷新
            scheduleBackgroundRefresh()
            
            // 步系统时间
            syncWithSystemTime()
        }
    }
    
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard extendedSession === extendedRuntimeSession else { return }
            
            logger.warning("会话即将过期: \(extendedRuntimeSession)")
            
            // 保存态
            saveState()
            
            if timerRunning {
                // 在当前会话过期前启动新会话
                try? await Task.sleep(nanoseconds: 200_000_000)
                await startExtendedSession()
            }
        }
    }
    
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            guard extendedSession === extendedRuntimeSession else { return }
            
            let errorDescription = error?.localizedDescription ?? "无误信"
            logger.info("会话已失效: \(reason.rawValue), 错误: \(errorDescription)")
            
            // 更新状态
            sessionState = .invalid
            
            // 处理特定原因
            switch reason {
            case .resignedFrontmost:
                if self.timerRunning {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await self.startExtendedSession()
                }
                
            case .suppressedBySystem, .error, .expired:
                if self.timerRunning {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.startExtendedSession()
                }
                
            case .none, .sessionInProgress:
                break
                
            @unknown default:
                logger.error("未知的会话终止原因: \(reason.rawValue)")
            }
            
            // 清理状态
            self.extendedSession = nil
        }
    }
}

// 添加安全访问数组的扩展
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
