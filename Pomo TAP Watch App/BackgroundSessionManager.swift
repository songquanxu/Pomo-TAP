import SwiftUI
@preconcurrency import WatchKit
@preconcurrency import Dispatch
import os

// MARK: - 后台会话管理 - 智能生命周期管理
@MainActor
class BackgroundSessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    // MARK: - Published Properties
    @Published private var sessionState: SessionState = .none
    @Published private(set) var sessionRetainCount: Int = 0
    @Published private var pendingRetainRequests: Int = 0
    @Published private(set) var sessionMetrics: SessionMetrics = SessionMetrics()  // 新增：会话指标

    // MARK: - Public Computed Properties
    var canStartNewSession: Bool {
        sessionState == .none && !isStarting && extendedSession == nil
    }

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "BackgroundSessionManager")
    private var extendedSession: WKExtendedRuntimeSession?
    private var isStarting = false
    private var sessionStartTime: Date?
    private var lastFailureTime: Date?
    private let maxRetryInterval: TimeInterval = 30.0  // 最大重试间隔30秒

    // MARK: - Session Metrics (新增智能监控)
    struct SessionMetrics {
        var totalSessionsStarted: Int = 0
        var totalSessionsFailed: Int = 0
        var totalSessionDuration: TimeInterval = 0
        var averageSessionDuration: TimeInterval = 0
        var successRate: Double = 0
        var lastSessionDuration: TimeInterval = 0

        mutating func recordStart() {
            totalSessionsStarted += 1
        }

        mutating func recordSuccess(duration: TimeInterval) {
            totalSessionDuration += duration
            lastSessionDuration = duration
            averageSessionDuration = totalSessionDuration / Double(totalSessionsStarted)
            successRate = Double(totalSessionsStarted - totalSessionsFailed) / Double(totalSessionsStarted)
        }

        mutating func recordFailure() {
            totalSessionsFailed += 1
            successRate = Double(totalSessionsStarted - totalSessionsFailed) / Double(totalSessionsStarted)
        }
    }

    // MARK: - Session State Enum
    private enum SessionState {
        case none
        case starting
        case running
        case stopping
        case invalid

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

    // MARK: - 智能会话启动 - 增强版
    func startExtendedSession() async {
        // 智能预检：防止不必要的启动
        guard shouldAttemptSessionStart() else {
            logger.debug("智能预检：跳过会话启动（条件不满足）")
            return
        }

        // 如果会话已在运行，只增加引用计数
        if let currentSession = extendedSession, currentSession.state == .running {
            sessionRetainCount += 1
            logger.debug("会话已在运行，增加引用计数: \(self.sessionRetainCount)")
            return
        }

        // 记录启动请求
        pendingRetainRequests += 1
        sessionMetrics.recordStart()
        logger.debug("收到扩展会话启动请求，挂起请求数: \(self.pendingRetainRequests)")

        // 防止并发启动
        guard !isStarting else {
            logger.debug("会话正在启动中，等待当前启动完成")
            return
        }

        isStarting = true
        sessionStartTime = Date()

        // 智能清理现有会话
        await cleanupExistingSession()

        // 验证启动条件
        guard pendingRetainRequests > 0 && extendedSession == nil else {
            logger.debug("启动条件已改变，取消启动流程")
            isStarting = false
            return
        }

        // 创建并启动新会话
        await createAndStartNewSession()
    }

    // MARK: - 智能会话停止 - 增强版
    func stopExtendedSession() {
        // 处理启动中的会话停止请求
        if sessionState == .starting || isStarting {
            handleStopDuringStartup()
            return
        }

        guard sessionRetainCount > 0 else {
            logger.debug("引用计数已为0，无需停止会话")
            return
        }

        // 减少引用计数
        sessionRetainCount -= 1

        // 如果还有其他引用，不停止会话
        if sessionRetainCount > 0 {
            logger.debug("会话仍被使用，引用计数: \(self.sessionRetainCount)")
            return
        }

        // 引用计数归零，执行智能停止
        performIntelligentSessionStop()
    }

    // MARK: - 智能辅助方法
    private func shouldAttemptSessionStart() -> Bool {
        // 检查最近失败时间，实现智能退避
        if let lastFailure = lastFailureTime {
            let timeSinceFailure = Date().timeIntervalSince(lastFailure)
            if timeSinceFailure < maxRetryInterval {
                logger.debug("智能退避：距离上次失败 \(Int(timeSinceFailure))秒，等待 \(Int(self.maxRetryInterval))秒后重试")
                return false
            }
        }

        // 检查会话状态是否允许启动
        return canStartNewSession
    }

    private func cleanupExistingSession() async {
        guard let existingSession = extendedSession else { return }

        logger.info("智能清理现有会话（状态: \(existingSession.state.rawValue)）")

        if existingSession.state == .running || existingSession.state == .notStarted {
            // 记录会话持续时间
            if let startTime = sessionStartTime {
                let duration = Date().timeIntervalSince(startTime)
                sessionMetrics.recordSuccess(duration: duration)
                logger.debug("会话持续时间: \(Int(duration))秒")
            }
            existingSession.invalidate()
        }

        extendedSession = nil
        sessionState = .none

        // 智能等待时间：根据历史成功率调整
        let waitTime = sessionMetrics.successRate > 0.8 ? 0.5 : 1.5
        try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        logger.debug("智能清理等待完成（\(waitTime)秒）")
    }

    private func createAndStartNewSession() async {
        sessionState = .starting
        let session = WKExtendedRuntimeSession()
        session.delegate = self

        // 保存强引用防止过早释放
        extendedSession = session

        // 启动会话
        session.start()
        logger.info("已请求启动扩展会话（挂起请求: \(self.pendingRetainRequests)）")

        // 智能缓冲时间：根据成功率调整
        let bufferTime = sessionMetrics.successRate > 0.8 ? 0.3 : 0.8
        try? await Task.sleep(nanoseconds: UInt64(bufferTime * 1_000_000_000))
        logger.debug("会话启动请求已发送，智能缓冲: \(bufferTime)秒")
    }

    private func handleStopDuringStartup() {
        if pendingRetainRequests > 0 {
            pendingRetainRequests -= 1
            logger.debug("会话启动过程中收到停止请求，挂起请求剩余: \(self.pendingRetainRequests)")
        }

        // 如果没有挂起请求且已创建会话，主动取消
        if pendingRetainRequests == 0, let session = extendedSession {
            logger.info("智能取消：无挂起请求，取消启动中的扩展会话")
            if session.state == .running || session.state == .notStarted {
                session.invalidate()
            }
        }
    }

    private func performIntelligentSessionStop() {
        guard let session = extendedSession else {
            logger.debug("没有活跃会话需要停止")
            return
        }

        logger.info("智能停止扩展会话（状态: \(session.state.rawValue)）")

        // 记录会话成功持续时间
        if let startTime = sessionStartTime {
            let duration = Date().timeIntervalSince(startTime)
            sessionMetrics.recordSuccess(duration: duration)
            logger.info("会话成功运行 \(Int(duration))秒")
        }

        // 同步清理，避免时序问题
        if session.state == .running || session.state == .notStarted {
            session.invalidate()
        }

        extendedSession = nil
        sessionState = .none
        sessionStartTime = nil
    }

    // MARK: - WKExtendedRuntimeSessionDelegate - 智能回调处理
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else {
                self.logger.warning("收到过期会话的启动通知，忽略")
                return
            }

            // 完成启动流程
            self.sessionState = .running
            let requestCount = self.pendingRetainRequests

            if requestCount == 0 {
                self.logger.warning("启动回调时挂起请求为空，使用回退引用计数")
                self.sessionRetainCount = max(self.sessionRetainCount, 1)
            } else {
                self.sessionRetainCount += requestCount
            }

            self.pendingRetainRequests = 0
            self.isStarting = false

            // 清除失败时间（成功启动）
            self.lastFailureTime = nil

            self.logger.info("✅ 会话智能启动成功（引用计数: \(self.sessionRetainCount)，成功率: \(String(format: "%.1f", self.sessionMetrics.successRate * 100))%）")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else {
                self.logger.warning("收到过期会话的即将过期通知，忽略")
                return
            }

            self.logger.warning("⏰ 会话即将过期，系统将自动失效（已运行: \(self.getSessionDurationText())）")
            // 不在这里重启会话，等待 didInvalidate 回调
        }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else {
                self.logger.warning("收到过期会话的失效通知，忽略")
                return
            }

            let errorDescription = error?.localizedDescription ?? "无"
            let reasonText = self.getInvalidationReasonText(reason)

            // 记录失败指标
            if reason == .error || error != nil {
                self.sessionMetrics.recordFailure()
                self.lastFailureTime = Date()
            } else if let startTime = self.sessionStartTime {
                // 正常结束，记录成功
                let duration = Date().timeIntervalSince(startTime)
                self.sessionMetrics.recordSuccess(duration: duration)
            }

            self.logger.info("❌ 会话已失效 - 原因: \(reasonText), 错误: \(errorDescription), 成功率: \(String(format: "%.1f", self.sessionMetrics.successRate * 100))%")

            // 智能状态清理
            if self.sessionState == .starting {
                // 启动失败，清空挂起请求
                self.pendingRetainRequests = 0
                self.isStarting = false
            } else {
                self.sessionRetainCount = 0
            }

            self.sessionState = .invalid
            self.extendedSession = nil
            self.sessionStartTime = nil

            // 智能重启决策：不自动重启，由计时器逻辑决定
            self.logger.debug("会话已清理，引用计数: \(self.sessionRetainCount)，挂起请求: \(self.pendingRetainRequests)")
        }
    }

    // MARK: - 智能辅助方法
    private func getSessionDurationText() -> String {
        guard let startTime = sessionStartTime else { return "未知" }
        let duration = Date().timeIntervalSince(startTime)
        return "\(Int(duration))秒"
    }

    // MARK: - Helper Methods
    private func getInvalidationReasonText(_ reason: WKExtendedRuntimeSessionInvalidationReason) -> String {
        switch reason {
        case .none:
            return "正常结束"
        case .sessionInProgress:
            return "已有会话运行"
        case .expired:
            return "过期"
        case .resignedFrontmost:
            return "应用失去前台"
        case .suppressedBySystem:
            return "系统限制"
        case .error:
            return "错误"
        @unknown default:
            return "未知(\(reason.rawValue))"
        }
    }
}
