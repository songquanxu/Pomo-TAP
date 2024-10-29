import SwiftUI
import WatchKit
import Combine
import UserNotifications
import os
import CoreData

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
    @Published var isAppActive = true // 应用是否处于活动状态
    @Published var lastBackgroundDate: Date? // 上次进入后台的时间
    @Published var hasSkippedInCurrentCycle = false // 当前期是否跳过
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
    @Published var currentPhaseName: String = "" // 当前阶段名称

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
            case .stopping: return "停止中"
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
        self.loadPhaseCompletionStatus()
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
    func startNextPhase() async { // 添加 async
        isAppActive = true
        await moveToNextPhase(autoStart: true, skip: false)
    }

    // 移动到下一个阶段
    func moveToNextPhase(autoStart: Bool, skip: Bool = false) async {
        startTransitionAnimation()
        
        let isSkipped = skip
        let isNormalCompletion = remainingTime <= 0 && !isSkipped
        
        phaseCompletionStatus[currentPhaseIndex] = isNormalCompletion ? .normalCompleted : .skipped
        savePhaseCompletionStatus()

        currentPhaseIndex = (currentPhaseIndex + 1) % phases.count
        
        if currentPhaseIndex == 0 {
            completeCycle()
        } else {
            phaseCompletionStatus[currentPhaseIndex] = .current
        }
        
        remainingTime = phases[currentPhaseIndex].duration
        totalTime = phases[currentPhaseIndex].duration
        cyclePhaseCount += 1
        
        lastPhase = currentPhaseIndex
        lastUsageTime = Date().timeIntervalSince1970
        
        stopTimer()
        timerRunning = false
        
        tomatoRingPosition = .zero
        
        currentPhaseName = phases[currentPhaseIndex].name
        saveState()
        updateResetMode()
        
        if isNormalCompletion {
            sendHapticFeedback()
        }

        if autoStart {
            await startTimer()
        } else {
            isResetState = true
            updateResetMode()
        }

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
            
            // 等待一小段时间再停止会话
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒
            stopExtendedSession()
        } else {
            playSound(.start)
            await startTimer()
        }
    }

    // 启动计时器
    private func startTimer() async {
        guard !timerRunning else { return } // 防止重复启动
        
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
        
        // 只有在非恢复状态下才播放声音
/*         if startTime == endTime {
            playSound(.start)
        } */
        
        logger.info("计时器已启动。当前阶段: \(self.currentPhaseName)，剩余时间: \(self.remainingTime) 秒。")
    }

    // 停止计时器
    private func stopTimer() {
        guard timerRunning else { return } // 防止重复停止
        
        timer?.cancel()
        timer = nil
        pausedRemainingTime = remainingTime
        stopExtendedSession()
        timerRunning = false

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
        }
        
        // 每分钟同步一次系统时间
        if Int(now.timeIntervalSince1970) % 60 == 0 {
            syncWithSystemTime()
        }
        
        if self.remainingTime == 0 {
            stopTimer()
            handlePhaseCompletion()
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
            logger.debug("时间同步检查通过。当前剩余时间: \(self.remainingTime) 秒，无需调整。")
        }
    }

    // 处理阶段完成##
    private func handlePhaseCompletion() {
        stopTimer()
        
        playSound(.success)
        sendHapticFeedback()
        
        Task { @MainActor in
            notificationDelegate?.sendNotification(
                for: .phaseCompleted,
                currentPhaseDuration: phases[currentPhaseIndex].duration / 60,
                nextPhaseDuration: phases[(currentPhaseIndex + 1) % phases.count].duration / 60
            )
        }
        
        Task {
            await moveToNextPhase(autoStart: false, skip: false)
        }
        saveState()
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
            
            // 重置所有状态
            self.currentPhaseIndex = 0
            self.remainingTime = self.phases[0].duration
            self.totalTime = self.phases[0].duration
            self.cyclePhaseCount = 0
            self.hasSkippedInCurrentCycle = false
            self.timerRunning = false
            self.isResetState = false
            self.isInDecisionMode = false
            self.isInCooldownMode = false
            self.resetPhaseCompletionStatus()
            self.currentCycleCompleted = false
            self.tomatoRingPosition = .zero
            self.currentPhaseName = self.phases[0].name
            self.updateTomatoRingPosition()
            
            // 播放重置音效
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
        
        // 增加引用计数
        sessionRetainCount += 1
        
        if let currentSession = extendedSession {
            switch currentSession.state {
            case .running:
                logger.debug("会话已在运行中")
                return
            case .invalid:
                await cleanupSession()
            case .notStarted:
                await cleanupSession()
            default:
                await cleanupSession()
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

    // 停止扩展会话
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
                    
                    // 最后执行无效化
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
        isAppActive = true
        
        // 检查并重置进度（在同步时间之前）
        checkAndResetProgress()
        
        // 原有的同步逻辑
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
        logger.info("应用变为非活动状态，已保存当前状态。")
    }

    // 应用进入后台
    func appEnteredBackground() {
        guard timerRunning else {
            logger.debug("计时器未运行，无需处理后台任务")
            return
        }
        
        // 保存当前状态
        saveState()
        
        // 安排后台刷新
        scheduleBackgroundRefresh()
        
        // 确保扩展会话在后台运行
        Task {
            await startExtendedSession()
        }
        
        logger.info("应用已进入后台模式，已完成必要设置")
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
            syncWithSystemTime()
            if remainingTime <= 0 {
                handlePhaseCompletion()
            } else {
                scheduleBackgroundRefresh()
            }
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
        currentPhaseIndex = userDefaults.integer(forKey: "currentPhase")
        remainingTime = userDefaults.integer(forKey: "remainingTime")
        timerRunning = userDefaults.bool(forKey: "timerRunning")
        completedCycles = userDefaults.integer(forKey: "completedCycles")
        hasSkippedInCurrentCycle = userDefaults.bool(forKey: "hasSkippedInCurrentCycle")
        currentCycleCompleted = userDefaults.bool(forKey: "currentCycleCompleted")
        lastUsageTime = userDefaults.double(forKey: "lastUsageTime")
        lastCycleCompletionTime = userDefaults.double(forKey: "lastCycleCompletionTime")
        totalTime = userDefaults.integer(forKey: "totalTime")
        currentPhaseName = userDefaults.string(forKey: "currentPhaseName") ?? ""
        loadPhaseCompletionStatus()
        updateTomatoRingPosition()
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
                handlePhaseCompletion()
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
                // 保持已跳过的状态,其他标记为已完成
                if self.phaseCompletionStatus[index] != .skipped {
                    self.phaseCompletionStatus[index] = .normalCompleted
                }
            } else if index == self.currentPhaseIndex {
                // 当前阶段标记为进行中
                self.phaseCompletionStatus[index] = .current
            } else {
                // 后续阶段标记为未开始
                self.phaseCompletionStatus[index] = .notStarted
            }
        }
        
        // 持久化保存状态
        self.savePhaseCompletionStatus()
        
        // 发送通知以更新UI
        NotificationCenter.default.post(
            name: .phaseChanged, 
            object: self, 
            userInfo: ["phaseStatus": self.phaseCompletionStatus]
        )
        
        self.logger.debug("阶段状态已更新并同步到UI: \(self.phaseCompletionStatus)")
    }

    // 添加状态同步方法
    private func synchronizeTimerState() {
        // 确保计时器状态与实际时间同步
        if timerRunning {
            guard let endTime = endTime else {
                stopTimer()
                return
            }
            
            let now = Date()
            if now >= endTime {
                handlePhaseCompletion()
            } else {
                remainingTime = Int(endTime.timeIntervalSince(now))
                updateTomatoRingPosition()
            }
        }
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

    // 添加检查和重置方法
    private func checkAndResetProgress() {
        let currentTime = Date().timeIntervalSince1970
        
        // 检查暂停时间
        if !timerRunning {
            if let lastPauseTime = userDefaults.double(forKey: LAST_PAUSE_TIME_KEY) as TimeInterval?,
               lastPauseTime > 0 {
                let pauseDuration = currentTime - lastPauseTime
                
                if pauseDuration >= PAUSE_RESET_THRESHOLD {
                    // 重置当前阶段
                    remainingTime = phases[currentPhaseIndex].duration
                    totalTime = phases[currentPhaseIndex].duration
                    updateTomatoRingPosition()
                    logger.info("由于暂停时间过长（\(Int(pauseDuration/60))分钟），已重置当前阶段")
                }
            }
        }
        
        // 检查周期停止时间
        if let lastActiveTime = userDefaults.double(forKey: LAST_ACTIVE_TIME_KEY) as TimeInterval?,
           lastActiveTime > 0 {
            let inactiveDuration = currentTime - lastActiveTime
            
            if inactiveDuration >= CYCLE_RESET_THRESHOLD {
                // 重置整个周期
                resetCycleQuietly()
                logger.info("由于停止时间过长（\(Int(inactiveDuration/3600))小时），已重置当前周期")
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
    private func cleanupSession() async {
        if let session = extendedSession {
            await MainActor.run {
                session.invalidate()
                extendedSession = nil
            }
        }
    }
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

// 将 WKExtendedRuntimeSessionDelegate 方法移到扩展中
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
            self.scheduleBackgroundRefresh()
            
            // 同步系统时间
            self.syncWithSystemTime()
        }
    }
    
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard extendedSession === extendedRuntimeSession else { return }
            
            logger.warning("会话即将过期: \(extendedRuntimeSession)")
            
            // 保存状态
            self.saveState()
            
            if self.timerRunning {
                // 在当前会话过期前启动新会话
                try? await Task.sleep(nanoseconds: 200_000_000)
                await self.startExtendedSession()
            }
        }
    }
    
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            guard extendedSession === extendedRuntimeSession else { return }
            
            let errorDescription = error?.localizedDescription ?? "无错误信息"
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
