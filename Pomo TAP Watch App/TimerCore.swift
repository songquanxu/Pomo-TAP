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
    }

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
        timer?.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer?.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.updateTimer()
            }
        }
        timer?.resume()

        timerRunning = true
        logger.info("计时器已启动。剩余时间: \(self.remainingTime) 秒。")
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

    // MARK: - Private Methods
    private func updateTimer() {
        guard timerRunning else { return }

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
