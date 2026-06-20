import SwiftUI
import WatchKit
import Combine
import AVFoundation
import os

// MARK: - 核心计时逻辑
@MainActor
class TimerCore: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var remainingTime: Int = 0
    @Published var timerRunning: Bool = false
    @Published var totalTime: Int = 0
    @Published var enableFinalCountdownHaptics: Bool = true
    @Published var isInfiniteMode: Bool = false  // 心流模式开关
    @Published var infiniteElapsedTime: Int = 0  // 心流模式下的已过时间
    @Published var isInFlowCountUp: Bool = false  // 当前是否处于心流正计时状态
    @Published var updateFrequency: UpdateFrequency = .normal  // 更新频率（普通 vs AOD）

    // MARK: - Update Frequency Enum
    enum UpdateFrequency: CustomStringConvertible {
        case normal    // 1-second updates (active state)
        case aod       // 1Hz updates (Always-On Display state)

        var interval: DispatchTimeInterval {
            switch self {
            case .normal, .aod:
                return .seconds(1)  // Both use 1-second interval for watchOS 26
            }
        }

        var leeway: DispatchTimeInterval {
            switch self {
            case .normal, .aod:
                return .seconds(1)  // 1-second leeway for both modes (battery optimization)
            }
        }

        var description: String {
            switch self {
            case .normal:
                return "正常模式"
            case .aod:
                return "AOD模式"
            }
        }
    }

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "TimerCore")
    private var timer: DispatchSourceTimer?
    private var startTime: Date?
    private var endTime: Date?
    private var pausedRemainingTime: Int?
    private var lastCountdownHapticSecond: Int?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Exposed Timing Metadata
    var countdownEndDate: Date? {
        endTime
    }

    var flowStartDate: Date? {
        guard isInFlowCountUp else { return nil }
        return startTime
    }

    // MARK: - Phase Completion Callback (Async)
    var onPhaseCompleted: (@MainActor () async -> Void)?

    // MARK: - Periodic Update Callback (for Widget sync)
    var onPeriodicUpdate: (@MainActor () async -> Void)?
    private var lastPeriodicUpdateTime: Date?

    // MARK: - Initialization
    override init() {
        super.init()
        
        // 监听更新频率变化，在 AOD 状态切换时重新调度计时器
        $updateFrequency
            .dropFirst()  // 跳过初始值
            .sink { [weak self] newFrequency in
                Task { @MainActor [weak self] in
                    guard let self = self, self.timerRunning else { return }
                    
                    // 计时器正在运行时，重新调度以应用新的频率设置
                    self.logger.info("AOD状态变化，重新调度计时器: \(newFrequency)")
                    self.rescheduleTimer()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods
    func startTimer() async {
        guard !timerRunning else { return }

        if remainingTime > 5 || remainingTime <= 0 {
            lastCountdownHapticSecond = nil
        }

        // 如果有暂停的剩余时间，使用它；否则使用当前的remainingTime
        if let pausedTime = pausedRemainingTime {
            remainingTime = pausedTime
            pausedRemainingTime = nil
        }

        startTime = Date()
        endTime = startTime?.addingTimeInterval(Double(remainingTime))

        timer?.cancel()
        timer = DispatchSource.makeTimerSource(queue: .main)
        // Use frequency-aware scheduling for AOD optimization
        timer?.schedule(
            deadline: .now(),
            repeating: updateFrequency.interval,
            leeway: updateFrequency.leeway
        )
        timer?.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.updateTimer()
            }
        }
        timer?.resume()

        timerRunning = true
        logger.info("计时器已启动。剩余时间: \(self.remainingTime) 秒，更新频率: \(self.updateFrequency)")
    }

    func stopTimer() {
        guard timerRunning else { return }

        timer?.cancel()
        timer = nil
        pausedRemainingTime = remainingTime
        timerRunning = false

        logger.info("计时器已停止。剩余时间: \(self.remainingTime) 秒。")
    }

    func resetTimer() {
        stopTimer()
        remainingTime = totalTime
        startTime = nil
        endTime = nil
        pausedRemainingTime = nil
        lastCountdownHapticSecond = nil
    }

    func clearPausedState() {
        pausedRemainingTime = nil
    }
    
    // 重新调度计时器（在更新频率变化时使用）
    private func rescheduleTimer() {
        guard let timer = timer, timerRunning else { return }
        
        // 重新调度现有的计时器，应用新的间隔和 leeway
        timer.schedule(
            deadline: .now(),
            repeating: updateFrequency.interval,
            leeway: updateFrequency.leeway
        )
        
        logger.debug("计时器已重新调度: \(self.updateFrequency.description)")
    }

    func enterFlowCountUp() {
        // 进入心流正计时模式
        isInFlowCountUp = true
        infiniteElapsedTime = 0
        lastCountdownHapticSecond = nil
        startTime = Date()
        endTime = nil
        logger.info("进入心流正计时模式")
    }

    func exitFlowCountUp() -> Int {
        // 退出心流正计时模式，返回已过时间
        isInFlowCountUp = false
        let elapsed = infiniteElapsedTime
        infiniteElapsedTime = 0
        lastCountdownHapticSecond = nil
        logger.info("退出心流正计时模式，已过时间: \(elapsed) 秒")
        return elapsed
    }

    func syncTimerStateFromSystemTime() {
        // 从系统时间同步计时器状态 (用于 AOD 恢复时修正显示偏差)
        // AOD 期间 UI 值按整分钟节流更新，离开 AOD 时必须立即用墙钟时间校正。
        guard timerRunning else { return }

        let now = Date()

        if isInFlowCountUp {
            guard let startTime = startTime else { return }
            let newElapsed = max(Int(now.timeIntervalSince(startTime)), 0)
            if newElapsed != infiniteElapsedTime {
                logger.info("🔄 AOD 恢复同步(心流): \(self.infiniteElapsedTime) → \(newElapsed) 秒")
                infiniteElapsedTime = newElapsed
            }
        } else {
            guard let endTime = endTime else { return }
            let newRemainingTime = max(Int(ceil(endTime.timeIntervalSince(now))), 0)
            if newRemainingTime != remainingTime {
                logger.info("🔄 AOD 恢复同步: \(self.remainingTime) → \(newRemainingTime) 秒")
                remainingTime = newRemainingTime
            }
        }
    }

    // MARK: - Private Methods
    private func updateTimer() {
        guard timerRunning else { return }

        let now = Date()

        // 核心原则：完成检测与最后 5 秒震动【始终每秒】运行，绝不被 AOD 节流跳过；
        // AOD 节流只跳过 @Published 值的赋值（即只降低 UI 刷新频率），避免误以为“节流”却仍每秒重绘。

        if isInFlowCountUp {
            // 心流正计时：基于系统时间计算已过时间
            guard let startTime = startTime else { return }
            let elapsed = max(Int(now.timeIntervalSince(startTime)), 0)

            // AOD 下 >0 秒时仅在整分钟边界更新 UI（显示为 mm:--，本就每分钟才变化一次）
            let aodThrottled = (updateFrequency == .aod && elapsed % 60 != 0)
            if !aodThrottled && elapsed != infiniteElapsedTime {
                infiniteElapsedTime = elapsed
                logger.debug("心流正计时已过时间: \(elapsed) 秒")
            }

        } else {
            // 普通倒计时：基于系统时间计算剩余时间
            guard let endTime = endTime else { return }
            let newRemainingTime = max(Int(ceil(endTime.timeIntervalSince(now))), 0)

            // 1) 完成检测：每秒进行，不受节流影响
            if newRemainingTime == 0 {
                if self.remainingTime != 0 { self.remainingTime = 0 }
                stopTimer()
                lastCountdownHapticSecond = nil
                logger.info("计时器自然结束")
                if let onPhaseCompleted = onPhaseCompleted {
                    Task { @MainActor in
                        await onPhaseCompleted()
                    }
                }
                return  // 阶段完成，直接返回
            }

            // 2) 最后 5 秒震动：每秒检查（≤5s 永远不会被 AOD 节流，故始终触发）
            if enableFinalCountdownHaptics,
               (1...5).contains(newRemainingTime),
               lastCountdownHapticSecond != newRemainingTime {
                lastCountdownHapticSecond = newRemainingTime
                WKInterfaceDevice.current().play(.click)
                logger.debug("最后 5 秒震动提醒: \(newRemainingTime)")
            }

            // 3) AOD 节流：剩余 > 60 秒时仅在整分钟边界更新 UI（节电约 96% 的 @Published 刷新）；
            //    ≤ 60 秒时每秒更新（保证最后一分钟逐秒准确）。离开 AOD 由 syncTimerStateFromSystemTime 校正。
            let aodThrottled = (updateFrequency == .aod && newRemainingTime > 60 && newRemainingTime % 60 != 0)
            if !aodThrottled && newRemainingTime != self.remainingTime {
                self.remainingTime = newRemainingTime
            }
        }

        // 检查是否需要触发定期更新（每分钟一次，用于 Widget 同步）
        if let lastUpdate = lastPeriodicUpdateTime {
            if now.timeIntervalSince(lastUpdate) >= 60 {
                lastPeriodicUpdateTime = now

                // 使用 Task 确保异步回调在主线程安全执行
                if let onPeriodicUpdate = onPeriodicUpdate {
                    Task { @MainActor in
                        await onPeriodicUpdate()
                    }
                }
            }
        } else {
            lastPeriodicUpdateTime = now
        }
    }
}
