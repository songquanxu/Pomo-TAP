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
    
    // MARK: - Private Properties for Combine
    private var cancellables = Set<AnyCancellable>()

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

    func pauseTimer() {
        stopTimer()
    }

    func resumeTimer() async {
        if let pausedTime = pausedRemainingTime {
            remainingTime = pausedTime
            pausedRemainingTime = nil
            await startTimer()
        }
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
        guard timerRunning, !isInFlowCountUp, let endTime = endTime else { return }

        let now = Date()
        let newRemainingTime = max(Int(ceil(endTime.timeIntervalSince(now))), 0)

        if newRemainingTime != remainingTime {
            logger.info("🔄 AOD 恢复同步: \(self.remainingTime) → \(newRemainingTime) 秒")
            remainingTime = newRemainingTime
        }
    }

    // MARK: - Private Methods
    private func updateTimer() {
        guard timerRunning else { return }

        let now = Date()

        // CRITICAL FIX: Always update internal state first, before any AOD throttling
        // AOD throttling should ONLY affect UI update frequency, NOT timer logic
        // This fixes the bug where early return prevented state updates and phase completion

        if isInFlowCountUp {
            // 心流正计时：基于系统时间计算已过时间
            guard let startTime = startTime else { return }
            let elapsed = Int(now.timeIntervalSince(startTime))

            // 始终更新内部状态（即使在 AOD 模式下也必须更新）
            if elapsed != infiniteElapsedTime {
                infiniteElapsedTime = elapsed
                logger.debug("心流正计时已过时间: \(elapsed) 秒")
            }

            // AOD 节流：仅影响 UI 更新频率，不影响状态计算
            // 在 AOD 下，只在整分钟时继续执行（触发 UI 更新），其他时候提前返回
            if updateFrequency == .aod {
                if infiniteElapsedTime % 60 != 0 { return }
            }

        } else {
            // 普通倒计时：基于系统时间计算剩余时间
            guard let endTime = endTime else { return }
            let newRemainingTime = max(Int(ceil(endTime.timeIntervalSince(now))), 0)

            // 始终更新内部状态（即使在 AOD 模式下也必须更新）
            if newRemainingTime != self.remainingTime {
                let previousTime = self.remainingTime
                self.remainingTime = newRemainingTime

                if enableFinalCountdownHaptics,
                   (1...5).contains(newRemainingTime),
                   lastCountdownHapticSecond != newRemainingTime {
                    lastCountdownHapticSecond = newRemainingTime
                    WKInterfaceDevice.current().play(.click)
                    logger.debug("最后 5 秒震动提醒: \(newRemainingTime)")
                }

                // 如果时间到达零，停止计时器并触发异步回调
                if newRemainingTime == 0 {
                    stopTimer()
                    lastCountdownHapticSecond = nil
                    logger.info("计时器自然结束")

                    // 使用 Task 确保异步回调在主线程安全执行
                    if let onPhaseCompleted = onPhaseCompleted {
                        Task { @MainActor in
                            await onPhaseCompleted()
                        }
                    }
                    return  // 阶段完成，直接返回
                } else if abs(previousTime - newRemainingTime) > 1 {
                    // 如果时间跳跃较大，记录日志（可能发生了系统休眠等情况）
                    logger.debug("时间更新: \(previousTime) -> \(newRemainingTime)")
                }
            }

            // AOD 节流：仅影响 UI 更新频率，不影响状态计算
            // 在 AOD 下：
            // - 剩余时间 > 60 秒：只在整分钟时继续执行（节电 96%）
            // - 剩余时间 ≤ 60 秒：每秒都继续执行（确保最后 1 分钟准确显示）
            if updateFrequency == .aod {
                if remainingTime > 60 && remainingTime % 60 != 0 { return }
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
