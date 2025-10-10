import SwiftUI
@preconcurrency import WatchKit
@preconcurrency import Dispatch
import os

// MARK: - 后台会话管理
@MainActor
class BackgroundSessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    // MARK: - Published Properties
    @Published private var sessionState: SessionState = .none
    @Published private(set) var sessionRetainCount: Int = 0  // 改为公开只读，便于调试
    @Published private var pendingRetainRequests: Int = 0  // 记录尚未完成的启动请求

    // MARK: - Public Computed Properties
    var isSessionActive: Bool {
        extendedSession?.state == .running && sessionRetainCount > 0
    }

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "BackgroundSessionManager")
    private var extendedSession: WKExtendedRuntimeSession?
    private var isStarting = false // 互斥锁：防止并发启动（直到系统回调才重置）

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

    // MARK: - Public Methods
    func startExtendedSession() async {
        // 如果会话已在运行，只增加引用计数即可
        if let currentSession = extendedSession, currentSession.state == .running {
            sessionRetainCount += 1
            logger.debug("会话已在运行，增加引用计数: \(self.sessionRetainCount)")
            return
        }

        // 记录一次新的启动请求
        pendingRetainRequests += 1
        logger.debug("收到扩展会话启动请求，挂起请求数: \(self.pendingRetainRequests)")

        // 防止并发启动
        guard !isStarting else {
            logger.debug("会话正在启动中，等待当前启动完成")
            return
        }

        // 检查是否已经有一个有效的会话在运行
        isStarting = true

        // 必须先完全清理现有会话（无论状态如何）
        if let existingSession = extendedSession {
            logger.info("清理现有会话（状态: \(existingSession.state.rawValue)）")
            if existingSession.state == .running || existingSession.state == .notStarted {
                existingSession.invalidate()
            }
            extendedSession = nil
            sessionState = .none

            // 等待系统完成清理（增加到 1.5 秒，确保系统完全释放资源）
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            logger.debug("会话清理等待完成")
        }

        // 如果所有挂起请求都已取消，则无需继续启动
        guard pendingRetainRequests > 0 else {
            logger.debug("挂起请求已清空，取消启动流程")
            isStarting = false
            return
        }

        // 再次检查是否已有会话（防止竞态条件）
        guard extendedSession == nil else {
            logger.warning("清理后仍存在会话，取消启动")
            pendingRetainRequests = max(pendingRetainRequests - 1, 0)
            isStarting = false
            return
        }

        // 创建新会话
        sessionState = .starting
        let session = WKExtendedRuntimeSession()
        session.delegate = self

        // 重要：立即保存强引用，防止会话被提前释放
        extendedSession = session

        // 启动会话（同步调用，但系统需要时间异步启动）
        session.start()
        logger.info("已请求启动扩展会话（挂起请求: \(self.pendingRetainRequests)）")

        // CRITICAL FIX: 等待系统实际启动会话，防止"only single session allowed"错误
        // 系统需要时间处理启动请求，如果立即返回可能导致下次调用时检测到"会话冲突"
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5秒缓冲
        logger.debug("会话启动请求已发送，等待系统确认")
    }

    func stopExtendedSession() {
        // 如果会话仍在启动过程中，优先减少挂起请求
        if sessionState == .starting || isStarting {
            if pendingRetainRequests > 0 {
                pendingRetainRequests -= 1
                logger.debug("会话启动过程中收到停止请求，挂起请求剩余: \(self.pendingRetainRequests)")
            }

            // 如果没有挂起请求且已经创建了会话，则主动取消
            if pendingRetainRequests == 0, let session = extendedSession {
                logger.info("无挂起请求，取消启动中的扩展会话")
                if session.state == .running || session.state == .notStarted {
                    session.invalidate()
                }
            }
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

        // 引用计数归零，停止并清理会话
        guard let session = extendedSession else {
            logger.debug("没有活跃会话需要停止")
            return
        }

        logger.info("停止扩展会话（状态: \(session.state.rawValue)）")

        // 同步清理，避免时序问题
        if session.state == .running || session.state == .notStarted {
            session.invalidate()
        }

        extendedSession = nil
        sessionState = .none
    }

    // MARK: - WKExtendedRuntimeSessionDelegate
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
            self.logger.info("✅ 会话成功启动（引用计数: \(self.sessionRetainCount)）")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else {
                self.logger.warning("收到过期会话的即将过期通知，忽略")
                return
            }

            self.logger.warning("⏰ 会话即将过期，将由系统自动失效")
            // 注意：不在这里重启会话，等待 didInvalidate 回调
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
            self.logger.info("❌ 会话已失效 - 原因: \(reasonText), 错误: \(errorDescription)")

            // 更新状态并清理引用
            if self.sessionState == .starting {
                // 启动失败，清空挂起请求
                self.pendingRetainRequests = 0
                self.isStarting = false
            } else {
                self.sessionRetainCount = 0
            }
            self.sessionState = .invalid
            self.extendedSession = nil

            // 重要：不自动重启会话
            // 原因：
            // 1. 避免无限重启循环
            // 2. 会话失效通常意味着应用不再需要后台执行
            // 3. 如果需要后台执行，应由计时器逻辑主动调用 startExtendedSession()
            self.logger.debug("会话已清理，引用计数: \(self.sessionRetainCount)，挂起请求: \(self.pendingRetainRequests)")
        }
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
