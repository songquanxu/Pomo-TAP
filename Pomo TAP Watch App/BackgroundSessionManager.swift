import SwiftUI
@preconcurrency import WatchKit
import os

// MARK: - 后台会话管理
@MainActor
class BackgroundSessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    // MARK: - Published Properties
    @Published private var sessionState: SessionState = .none
    @Published private var sessionRetainCount: Int = 0

    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "BackgroundSessionManager")
    private var extendedSession: WKExtendedRuntimeSession?

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
        guard WKExtension.shared().applicationState == .active else {
            logger.warning("应用不在活跃状态，无法启动会话")
            return
        }

        // 检查是否已经有一个有效的会话在运行
        if let currentSession = extendedSession, currentSession.state == .running {
            sessionRetainCount += 1
            logger.debug("会话已在运行，增加引用计数: \(self.sessionRetainCount)")
            return
        }

        // 增加引用计数
        sessionRetainCount += 1

        // 清理任何无效的会话
        if let currentSession = extendedSession, currentSession.state == .invalid {
            cleanupSession()
        }

        sessionState = .starting
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        extendedSession = session

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 设置超时机制
                let timeoutWorkItem = DispatchWorkItem {
                    guard let self = self else { return }
                    if self.sessionState == .starting {
                        self.logger.error("会话启动超时")
                        self.sessionState = .invalid
                        continuation.resume(throwing: NSError(domain: "BackgroundSessionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Session start timeout"]))
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWorkItem)

                // 启动会话
                session.start()

                // 监听状态变化 - 降低频率以节省电池
                let _ = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                    if session.state == .running {
                        timer.invalidate()
                        timeoutWorkItem.cancel()
                        continuation.resume()
                    } else if session.state == .invalid {
                        timer.invalidate()
                        timeoutWorkItem.cancel()
                        continuation.resume(throwing: NSError(domain: "BackgroundSessionManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Session became invalid"]))
                    }
                }
            }

            sessionState = .running
            logger.info("扩展会话启动成功")

        } catch {
            sessionState = .invalid
            extendedSession = nil
            logger.error("启动扩展会话失败: \(error.localizedDescription)")
        }
    }

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

        let currentSession = session

        switch currentSession.state {
        case .running:
            sessionState = .stopping

            DispatchQueue.main.async {
                guard let self = self else { return }

                if currentSession === self.extendedSession && currentSession.state == .running {
                    self.extendedSession = nil
                    self.sessionState = .none
                    currentSession.invalidate()
                    self.logger.info("正常停止运行中的会话: \(currentSession)")
                } else {
                    self.logger.debug("会话状态已改变，跳过停止操作")
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
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.extendedSession = nil
                self.sessionState = .none
                currentSession.invalidate()
            }
        }
    }

    // MARK: - WKExtendedRuntimeSessionDelegate
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else {
                self.logger.warning("收到过期会话的启动通知")
                return
            }

            self.sessionState = .running
            self.logger.info("会话成功启动: \(extendedRuntimeSession)")
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else { return }

            self.logger.warning("会话即将过期: \(extendedRuntimeSession)")

            // 在当前会话过期前启动新会话 - 增加延迟避免频繁重启
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒延迟
            await self.startExtendedSession()
        }
    }

    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in
            guard self.extendedSession === extendedRuntimeSession else { return }

            let errorDescription = error?.localizedDescription ?? "无错误信息"
            self.logger.info("会话已失效: \(reason.rawValue), 错误: \(errorDescription)")

            // 更新状态
            self.sessionState = .invalid

            // 处理特定原因
            switch reason {
            case .resignedFrontmost:
                if self.sessionRetainCount > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒延迟
                    await self.startExtendedSession()
                }

            case .suppressedBySystem, .error, .expired:
                if self.sessionRetainCount > 0 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒延迟
                    await self.startExtendedSession()
                }

            case .none, .sessionInProgress:
                break

            @unknown default:
                self.logger.error("未知的会话终止原因: \(reason.rawValue)")
            }

            // 清理状态
            self.extendedSession = nil
        }
    }

    // MARK: - Private Methods
    private func cleanupSession() {
        if let session = extendedSession {
            session.invalidate()
            extendedSession = nil
        }
    }
}
