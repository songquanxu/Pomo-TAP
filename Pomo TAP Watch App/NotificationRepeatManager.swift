import SwiftUI
import UserNotifications
import os

// MARK: - 重复通知管理器
@MainActor
class NotificationRepeatManager: ObservableObject {
    // MARK: - Private Properties
    private let logger = Logger(subsystem: "com.songquan.pomoTAP", category: "NotificationRepeatManager")

    // MARK: - Constants
    private let repeatCount = 3  // 重复 3 次通知

    // MARK: - Public Methods

    /// 调度重复通知 - 智能重复提醒机制
    /// - Parameters:
    ///   - initialDelay: 第一次通知的延迟时间（秒）
    ///   - title: 通知标题
    ///   - body: 通知内容
    ///   - scheduledPhaseIndex: 此通知对应的倒计时阶段索引（与主通知一致，供响应时精确判断推进）
    func scheduleRepeatNotifications(
        initialDelay: TimeInterval,
        title: String,
        body: String,
        scheduledPhaseIndex: Int
    ) async {
        do {
            // 检查通知权限
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else {
                logger.warning("通知权限未获得，无法调度重复通知")
                return
            }

            // 智能清理：只取消重复通知，保留主通知
            await cancelAllRepeatNotifications()

            // 调度重复通知序列（渐进式提醒策略）
            for index in 0..<repeatCount {
                // 智能延迟策略：
                // 重复 1: 主通知后 1 分钟 (用户可能未注意到)
                // 重复 2: 主通知后 3 分钟 (适度提醒)
                // 重复 3: 主通知后 6 分钟 (最后提醒)
                let delayMultipliers: [TimeInterval] = [1, 3, 6]
                let delay = initialDelay + (delayMultipliers[index] * 60)

                // 创建高优先级通知内容
                let content = createRepeatNotificationContent(
                    title: title,
                    body: body,
                    repeatIndex: index,
                    scheduledPhaseIndex: scheduledPhaseIndex
                )

                // 创建精确触发器
                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: delay,
                    repeats: false
                )

                // 创建唯一标识符（防止与主通知冲突）
                let identifier = "PomoTAP_Repeat_\(Date().timeIntervalSince1970)_\(index)"
                let request = UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: trigger
                )

                // 异步添加通知（提高性能）
                try await UNUserNotificationCenter.current().add(request)
                logger.info("✅ 智能重复通知 #\(index + 1): \(Int(delay))秒后触发（延迟\(Int(delayMultipliers[index]))分钟）")
            }

            logger.info("✅ 成功调度 \(self.repeatCount) 次智能重复通知（渐进式提醒）")

        } catch {
            logger.error("调度重复通知失败: \(error.localizedDescription)")
        }
    }

    /// 创建重复通知内容 - 优化用户体验
    private func createRepeatNotificationContent(
        title: String,
        body: String,
        repeatIndex: Int,
        scheduledPhaseIndex: Int
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()

        // 渐进式标题策略
        switch repeatIndex {
        case 0:
            content.title = "⏰ " + title  // 第一次重复：时钟提醒
        case 1:
            content.title = "🔔 " + title  // 第二次重复：铃铛提醒
        case 2:
            content.title = "⚠️ " + title  // 第三次重复：警告提醒
        default:
            content.title = title
        }

        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive  // 高优先级
        content.relevanceScore = 0.9  // 高相关性（比主通知更高）
        content.threadIdentifier = "PomoTAP_Notifications"
        content.categoryIdentifier = "PHASE_COMPLETED"
        // 与主通知一致的阶段印章：点击重复通知的动作时也能精确路由
        content.userInfo = ["scheduledPhaseIndex": scheduledPhaseIndex]

        return content
    }

    /// 取消所有待发送的重复通知 - 智能标识符管理
    func cancelAllRepeatNotifications() async {
        // 获取所有待发送的通知
        let pendingRequests = await UNUserNotificationCenter.current().pendingNotificationRequests()

        // 智能筛选：只取消重复通知，保留主通知
        let repeatIdentifiers = pendingRequests
            .filter { $0.identifier.hasPrefix("PomoTAP_Repeat_") }
            .map { $0.identifier }

        // 批量取消重复通知（高效操作）
        if !repeatIdentifiers.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: repeatIdentifiers
            )
            logger.info("🗑️ 智能清理：已取消 \(repeatIdentifiers.count) 个重复通知（保留主通知）")
        } else {
            logger.debug("无重复通知需要取消")
        }
    }

}
