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

    // MARK: - Phase Completion Callback
    var onPhaseCompleted: (() -> Void)?

    // MARK: - Periodic Update Callback (for Widget sync)
    var onPeriodicUpdate: (() -> Void)?
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
        startTime = Date()
        endTime = nil
        logger.info("进入心流正计时模式")
    }

    func exitFlowCountUp() -> Int {
        // 退出心流正计时模式，返回已过时间
        isInFlowCountUp = false
        let elapsed = infiniteElapsedTime
        infiniteElapsedTime = 0
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

        // AOD 模式下的更新频率优化（节电策略）
        if updateFrequency == .aod {
            if isInFlowCountUp {
                // 心流模式正计时：AOD 下只需每分钟更新一次（显示 mm:--）
                if infiniteElapsedTime % 60 != 0 { return }
            } else {
                // 普通倒计时：
                // - 剩余时间 > 60 秒：只在整分钟更新（节电 96%）
                // - 剩余时间 ≤ 60 秒：每秒都更新（确保最后 1 分钟准确显示）
                if remainingTime > 60 && remainingTime % 60 != 0 { return }
            }
        }

        // 检查是否需要触发定期更新（每分钟一次）
        let now = Date()
        if let lastUpdate = lastPeriodicUpdateTime {
            if now.timeIntervalSince(lastUpdate) >= 60 {
                lastPeriodicUpdateTime = now
                onPeriodicUpdate?()
            }
        } else {
            lastPeriodicUpdateTime = now
        }

        if isInFlowCountUp {
            // 心流正计时：正计时
            guard let startTime = startTime else { return }
            let elapsed = Int(now.timeIntervalSince(startTime))

            if elapsed != infiniteElapsedTime {
                infiniteElapsedTime = elapsed
                logger.debug("心流正计时已过时间: \(elapsed) 秒")
            }
        } else {
            // 普通模式：倒计时
            guard let endTime = endTime else { return }
            let newRemainingTime = max(Int(ceil(endTime.timeIntervalSince(now))), 0)

            // 只有当时间发生变化时才更新
            if newRemainingTime != self.remainingTime {
                let previousTime = self.remainingTime
                self.remainingTime = newRemainingTime

                // 如果时间到达零，停止计时器
                if newRemainingTime == 0 {
                    stopTimer()
                    logger.info("计时器自然结束")
                    // 触发阶段完成回调
                    onPhaseCompleted?()
                } else if abs(previousTime - newRemainingTime) > 1 {
                    // 如果时间跳跃较大，记录日志（可能发生了系统休眠等情况）
                    logger.debug("时间更新: \(previousTime) -> \(newRemainingTime)")
                }
            }
        }
    }
}
