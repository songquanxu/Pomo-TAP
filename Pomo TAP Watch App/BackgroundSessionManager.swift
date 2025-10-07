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

    // MARK: - Public Computed Properties
    var isSessionActive: Bool {
        extendedSession?.state == .running && sessionRetainCount > 0
    }

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "BackgroundSessionManager")
    private var extendedSession: WKExtendedRuntimeSession?
    private var isStarting = false // 互斥锁：防止并发启动

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
        // 防止并发启动
        guard !isStarting else {
            logger.warning("会话正在启动中，忽略重复请求")
            return
        }

        // 检查是否已经有一个有效的会话在运行
        if let currentSession = extendedSession, currentSession.state == .running {
            sessionRetainCount += 1
            logger.debug("会话已在运行，增加引用计数: \(self.sessionRetainCount)")
            return
        }

        // 设置互斥锁
        isStarting = true
        defer { isStarting = false }

        // 增加引用计数
        sessionRetainCount += 1

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

        // 再次检查是否已有会话（防止竞态条件）
        guard extendedSession == nil else {
            logger.warning("清理后仍存在会话，取消启动")
            sessionRetainCount -= 1
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
        logger.info("已请求启动扩展会话（引用计数: \(self.sessionRetainCount)）")

        // CRITICAL FIX: 等待系统实际启动会话，防止"only single session allowed"错误
        // 系统需要时间处理启动请求，如果立即返回可能导致下次调用时检测到"会话冲突"
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5秒缓冲
        logger.debug("会话启动请求已发送，等待系统确认")
    }

    func stopExtendedSession() {
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

            self.sessionState = .running
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
            self.sessionState = .invalid
            self.extendedSession = nil

            // 重要：不自动重启会话
            // 原因：
            // 1. 避免无限重启循环
            // 2. 会话失效通常意味着应用不再需要后台执行
            // 3. 如果需要后台执行，应由计时器逻辑主动调用 startExtendedSession()
            self.logger.debug("会话已清理，引用计数: \(self.sessionRetainCount)")
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
